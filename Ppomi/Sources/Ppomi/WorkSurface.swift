import AppKit
import ApplicationServices

/// A window the workbench can accompany. This does not assert guest login or agent-control readiness.
@MainActor
enum WorkSurface: String, CaseIterable, Identifiable {
    case iphone, windows

    nonisolated var id: String { rawValue }
    var displayName: String { self == .iphone ? "iPhone" : "Windows" }
    var symbolName: String { self == .iphone ? "iphone" : "desktopcomputer" }
    var defaultSize: CGSize { self == .iphone ? Mirroring.defaultSize : CGSize(width: 900, height: 620) }
    var isRunning: Bool { self == .iphone ? Mirroring.app() != nil : ParallelsWindow.isRunning }
    var isFrontmost: Bool { self == .iphone ? Mirroring.app()?.isActive == true : ParallelsWindow.isFrontmost }
    var processIdentifier: pid_t? { self == .iphone ? Mirroring.app()?.processIdentifier : ParallelsWindow.processIdentifier }

    func liveWindow() -> (id: CGWindowID, rect: CGRect)? {
        self == .iphone ? Mirroring.liveWindow() : ParallelsWindow.liveWindow()
    }
    func axFrame() -> CGRect? { self == .iphone ? Mirroring.axFrame() : ParallelsWindow.axFrame() }
    func place(_ origin: CGPoint) {
        if self == .iphone { Mirroring.place(origin) } else { ParallelsWindow.place(origin) }
    }
    /// Only the resizable desktop target is resized, and only by an explicit layout action.
    @discardableResult func resize(_ size: CGSize) -> Bool {
        self == .windows && ParallelsWindow.resize(size)
    }
    @discardableResult func revealWindow() -> Bool {
        self == .iphone ? Mirroring.revealWindow() : ParallelsWindow.revealWindow()
    }
    func isInFrontOfOtherApplications(_ id: CGWindowID) -> Bool {
        self == .iphone ? Mirroring.isInFrontOfOtherApplications(id) : ParallelsWindow.isInFront(id)
    }
    func launch() {
        if self == .windows { ParallelsWindow.launch(); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Mirroring.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

/// Pure selection policy: process identity is checked separately; a CG ID is usable only with a matching AX frame.
enum ParallelsWindowPolicy {
    enum Kind { case host, virtualMachine }
    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let kind: Kind
        let rect: CGRect
        let axRect: CGRect
        let isStandard: Bool
        let isMain: Bool
        let isOnScreen: Bool
        let layer: Int
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        let values = [a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height]
        return values.allSatisfy(\.isFinite) && a.width >= 240 && a.height >= 180 &&
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
            abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    static func select(_ candidates: [Candidate], preferredID: CGWindowID?, vmWindowPresent: Bool = false) -> Candidate? {
        let matchesPerID = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            (!vmWindowPresent || $0.kind == .virtualMachine) &&
                matchesPerID[$0.id] == 1 && $0.layer == 0 && framesMatch($0.rect, $0.axRect) &&
                ($0.isStandard || $0.kind == .host)
        }.sorted { a, b in
            if a.kind != b.kind { return a.kind == .virtualMachine }
            if a.isStandard != b.isStandard { return a.isStandard }
            if (a.id == preferredID) != (b.id == preferredID) { return a.id == preferredID }
            if a.isMain != b.isMain { return a.isMain }
            let areaA = a.rect.width * a.rect.height, areaB = b.rect.width * b.rect.height
            if areaA != areaB { return areaA > areaB }
            return a.id < b.id
        }.first
    }

    /// Executable paths come from the installed host and its nested Parallels VM bundle, never a window title.
    static func kind(executablePath: String?, hostPaths: Set<String>, vmPaths: Set<String>) -> Kind? {
        guard let executablePath else { return nil }
        if vmPaths.contains(executablePath) { return .virtualMachine }
        if hostPaths.contains(executablePath) { return .host }
        return nil
    }
}

@MainActor
private enum ParallelsWindow {
    private struct Installation {
        let url: URL
        let hostExecutable: String
        let vmExecutable: String?
    }
    private struct Process {
        let app: NSRunningApplication
        let kind: ParallelsWindowPolicy.Kind
    }
    private struct Window {
        let candidate: ParallelsWindowPolicy.Candidate
        let element: AXUIElement
        let app: NSRunningApplication
    }
    private static var preferredID: CGWindowID?
    private static var installationCache: (checkedAt: TimeInterval, values: [Installation])?

    private static func installations() -> [Installation] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = installationCache, now - cached.checkedAt < 5 { return cached.values }
        var urls = [URL(fileURLWithPath: "/Applications/Parallels Desktop.app"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Parallels Desktop.app")]
        for id in ["com.parallels.desktop.appstore", "com.parallels.desktop.console"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { urls.append(url) }
        }
        var seen = Set<String>()
        let installed: [Installation] = urls.compactMap { url in
            let url = url.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted, let bundle = Bundle(url: url),
                  let executable = bundle.executableURL?.resolvingSymlinksInPath(),
                  executable.lastPathComponent == "prl_client_app" else { return nil }
            let vm = Bundle(url: url.appendingPathComponent("Contents/MacOS/Parallels VM.app"))?.executableURL?.resolvingSymlinksInPath()
            return Installation(url: url, hostExecutable: executable.path,
                                vmExecutable: vm?.lastPathComponent == "prl_vm_app" ? vm?.path : nil)
        }
        installationCache = (now, installed)
        return installed
    }

    private static func processes() -> [Process] {
        let installed = installations()
        let hosts = Set(installed.map(\.hostExecutable)), vms = Set(installed.compactMap(\.vmExecutable))
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated,
                  let kind = ParallelsWindowPolicy.kind(executablePath: app.executableURL?.resolvingSymlinksInPath().path,
                                                       hostPaths: hosts, vmPaths: vms) else { return nil }
            return Process(app: app, kind: kind)
        }
    }

    static var isRunning: Bool { !processes().isEmpty }
    static var isFrontmost: Bool { processes().contains { $0.app.isActive } }
    static var processIdentifier: pid_t? {
        selectedWindow()?.candidate.pid ?? processes().sorted {
            $0.kind == .virtualMachine && $1.kind != .virtualMachine
        }.first?.app.processIdentifier
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        Mirroring.attr(element, name)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attr(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attr(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func cgWindows(_ options: CGWindowListOption = .optionAll) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = value["X"], let y = value["Y"], let width = value["Width"], let height = value["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func selectedWindow() -> Window? {
        guard AXIsProcessTrusted() else { return nil }
        let cg = cgWindows()
        var windows: [Window] = []
        var vmWindowPresent = false
        for process in processes() {
            let application = AXUIElementCreateApplication(process.app.processIdentifier)
            let axWindows = (attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for ax in axWindows {
                guard attr(ax, kAXRoleAttribute) as? String == kAXWindowRole, let axRect = frame(ax) else { continue }
                let subrole = attr(ax, kAXSubroleAttribute) as? String
                let standard = subrole == nil || subrole == kAXStandardWindowSubrole
                // A host sign-in dialog is an honest fallback; sheets, menus and VM dialogs are not a desktop surface.
                guard standard || (process.kind == .host && subrole == kAXDialogSubrole) else { continue }
                if process.kind == .virtualMachine, ParallelsWindowPolicy.framesMatch(axRect, axRect) {
                    vmWindowPresent = true
                }
                let matches = cg.filter {
                    ($0[kCGWindowOwnerPID as String] as? pid_t) == process.app.processIdentifier &&
                    ($0[kCGWindowLayer as String] as? Int) == 0 &&
                    bounds($0).map { ParallelsWindowPolicy.framesMatch($0, axRect) } == true
                }
                // An ambiguous same-frame pair cannot safely identify the window that AX would move.
                guard matches.count == 1, let cgWindow = matches.first,
                      let id = cgWindow[kCGWindowNumber as String] as? UInt32, let rect = bounds(cgWindow) else { continue }
                windows.append(Window(candidate: .init(id: id, pid: process.app.processIdentifier, kind: process.kind,
                    rect: rect, axRect: axRect, isStandard: standard, isMain: attr(ax, kAXMainAttribute) as? Bool == true,
                    isOnScreen: cgWindow[kCGWindowIsOnscreen as String] as? Bool == true, layer: 0), element: ax, app: process.app))
            }
        }
        // During a VM move/resize, wait for WindowServer to catch up instead of moving the host as a fallback.
        guard let selected = ParallelsWindowPolicy.select(windows.map(\.candidate), preferredID: preferredID,
                                                         vmWindowPresent: vmWindowPresent),
              let window = windows.first(where: { $0.candidate.id == selected.id }) else { return nil }
        preferredID = selected.id
        return window
    }

    static func liveWindow() -> (id: CGWindowID, rect: CGRect)? {
        guard let window = selectedWindow(), window.candidate.isOnScreen else { return nil }
        return (window.candidate.id, window.candidate.rect)
    }
    static func axFrame() -> CGRect? { selectedWindow()?.candidate.axRect }

    static func place(_ origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite, let window = selectedWindow() else { return }
        var origin = origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
    }

    static func resize(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width >= 240, size.height >= 180,
              let window = selectedWindow() else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            return AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value) == .success
        }
        return false
    }

    /// Only explicit user reveal enters this path. Discovery, frame reads and ordering checks never activate an app.
    static func revealWindow() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let window = selectedWindow()
        let running = window?.app ?? processes().sorted { $0.kind == .virtualMachine && $1.kind != .virtualMachine }.first?.app
        guard let running else { return false }
        if running.isHidden { running.unhide() }
        if let window {
            if attr(window.element, kAXMinimizedAttribute) as? Bool == true {
                AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
        if let live = liveWindow(), isInFront(live.id) { return true }
        running.activate(options: [])
        if let window { AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) }
        guard let live = liveWindow() else { return false }
        return isInFront(live.id)
    }

    static func isInFront(_ id: CGWindowID) -> Bool {
        guard let selected = selectedWindow(), selected.candidate.id == id else { return false }
        let windows = cgWindows(.optionOnScreenOnly).compactMap { window -> MirroringOrder.Window? in
            guard let number = window[kCGWindowNumber as String] as? UInt32,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int else { return nil }
            return .init(id: number, owner: owner, layer: layer)
        }
        return MirroringOrder.isInFront(phoneID: id, phonePID: selected.candidate.pid,
                                         ppomiPID: ProcessInfo.processInfo.processIdentifier, windows: windows)
    }

    static func launch() {
        guard let installation = installations().first else { return }
        NSWorkspace.shared.openApplication(at: installation.url, configuration: .init(), completionHandler: nil)
    }
}
