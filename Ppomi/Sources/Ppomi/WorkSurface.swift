import AppKit
import ApplicationServices

/// A window the workbench can accompany. This does not assert guest login or agent-control readiness.
@MainActor
enum WorkSurface: String, CaseIterable, Identifiable {
    case iphone, android, windows

    nonisolated var id: String { rawValue }
    var displayName: String {
        switch self { case .iphone: return "iPhone"; case .android: return "Android"; case .windows: return "Windows" }
    }
    var defaultSize: CGSize {
        switch self {
        case .iphone: return Mirroring.defaultSize
        case .android: return AndroidWindow.defaultSize
        case .windows: return CGSize(width: 900, height: 620)
        }
    }
    var disconnectedHint: String {
        switch self {
        case .iphone: return "iPhone 미러링을 연결해 주세요"
        case .android: return "Android · 연결 끊김"
        case .windows: return "Parallels에서 Windows 창을 열어 주세요"
        }
    }
    var isRunning: Bool {
        switch self {
        case .iphone: return Mirroring.app() != nil
        case .android: return AndroidWindow.isRunning
        case .windows: return ParallelsWindow.isRunning
        }
    }
    /// Android preparation also reconnects its companion service when the mirror is already open.
    var needsLaunch: Bool { self == .android || !isRunning }
    var isFrontmost: Bool {
        switch self {
        case .iphone: return Mirroring.app()?.isActive == true
        case .android: return AndroidWindow.isFrontmost
        case .windows: return ParallelsWindow.isFrontmost
        }
    }
    var processIdentifier: pid_t? {
        switch self {
        case .iphone: return Mirroring.app()?.processIdentifier
        case .android: return AndroidWindow.processIdentifier
        case .windows: return ParallelsWindow.processIdentifier
        }
    }
    func liveWindow() -> (id: CGWindowID, rect: CGRect)? {
        switch self {
        case .iphone: return Mirroring.liveWindow()
        case .android: return AndroidWindow.liveWindow()
        case .windows: return ParallelsWindow.liveWindow()
        }
    }
    func axFrame() -> CGRect? {
        switch self {
        case .iphone: return Mirroring.axFrame()
        case .android: return AndroidWindow.axFrame()
        case .windows: return ParallelsWindow.axFrame()
        }
    }
    func place(_ origin: CGPoint) {
        switch self {
        case .iphone: Mirroring.place(origin)
        case .android: AndroidWindow.place(origin)
        case .windows: ParallelsWindow.place(origin)
        }
    }
    /// Resizable external windows change size only through explicit layout actions.
    @discardableResult func resize(_ size: CGSize) -> Bool {
        switch self {
        case .iphone: return false
        case .android: return AndroidWindow.resize(size)
        case .windows: return ParallelsWindow.resize(size)
        }
    }
    /// One native sizing request; callers measure the actual frame after it settles.
    @discardableResult func requestCompactSize(available: CGSize) -> Bool {
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else { return false }
        switch self {
        case .iphone: return Mirroring.requestSmallSize()
        case .android: return AndroidWindow.requestCompactSize(available: available)
        // Windows keeps its own size: shrinking the guest makes its browser text tiny for OCR and the person alike.
        // The workbench grows around the measured frame instead (Kiosk.fitMain raises its minimum width).
        case .windows: return false
        }
    }
    @discardableResult func revealWindow() -> Bool {
        switch self {
        case .iphone: return Mirroring.revealWindow()
        case .android: return AndroidWindow.revealWindow()
        case .windows: return ParallelsWindow.revealWindow()
        }
    }
    func isInFrontOfOtherApplications(_ id: CGWindowID) -> Bool {
        switch self {
        case .iphone: return Mirroring.isInFrontOfOtherApplications(id)
        case .android: return AndroidWindow.isInFront(id)
        case .windows: return ParallelsWindow.isInFront(id)
        }
    }
    func launch() async throws {
        switch self {
        case .android: try await AndroidRuntime.launchMirror()
        case .windows: ParallelsWindow.launch()
        case .iphone:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Mirroring.bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }
}

/// Shrink a native desktop window into its reserved area while retaining aspect ratio and a small border.
enum WorkSurfaceCompactLayout {
    static func size(current: CGSize, available: CGSize, margin: CGFloat = 8,
                     minimum: CGSize = CGSize(width: 240, height: 180)) -> CGSize? {
        guard [current.width, current.height, available.width, available.height, margin, minimum.width, minimum.height].allSatisfy(\.isFinite),
              minimum.width > 0, minimum.height > 0,
              current.width >= minimum.width, current.height >= minimum.height, margin >= 0,
              available.width > margin * 2, available.height > margin * 2 else { return nil }
        let width = available.width - margin * 2
        let height = available.height - margin * 2
        let scale = min(1, width / current.width, height / current.height)
        let target = CGSize(width: current.width * scale, height: current.height * scale)
        guard target.width >= minimum.width, target.height >= minimum.height else { return nil }
        return target
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

    static func select(_ candidates: [Candidate], preferredID: CGWindowID?, vmWindowPresent: Bool = false,
                       compactID: CGWindowID? = nil) -> Candidate? {
        let matchesPerID = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            (!vmWindowPresent || $0.kind == .virtualMachine) &&
                matchesPerID[$0.id] == 1 && $0.layer == 0 && framesMatch($0.rect, $0.axRect) &&
                ($0.isStandard || $0.kind == .host)
        }.sorted { a, b in
            if a.kind != b.kind { return a.kind == .virtualMachine }
            if a.isStandard != b.isStandard { return a.isStandard }
            // An explicitly compacted desktop can become smaller than an already open configuration dialog.
            if (a.id == compactID) != (b.id == compactID) { return a.id == compactID }
            // The App Store edition draws the VM display and its dialogs (구성, 제어 센터) from one host process as peer
            // standard windows: the desktop is the largest of them, whichever was clicked last. Memory only breaks ties.
            let areaA = a.rect.width * a.rect.height, areaB = b.rect.width * b.rect.height
            if areaA != areaB { return areaA > areaB }
            if (a.id == preferredID) != (b.id == preferredID) { return a.id == preferredID }
            if a.isMain != b.isMain { return a.isMain }
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
    private static var compactTarget: Window?
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
        var compactTargetPresent = false
        var largestStandard: [ParallelsWindowPolicy.Kind: CGFloat] = [:]   // per kind, over every standard AX window, matched to CG or not
        for process in processes() {
            let application = AXUIElementCreateApplication(process.app.processIdentifier)
            let axWindows = (attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for ax in axWindows {
                guard attr(ax, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
                if let target = compactTarget, target.candidate.pid == process.app.processIdentifier,
                   CFEqual(target.element, ax) { compactTargetPresent = true }
                guard let axRect = frame(ax) else { continue }
                let subrole = attr(ax, kAXSubroleAttribute) as? String
                let standard = subrole == nil || subrole == kAXStandardWindowSubrole
                // A host sign-in dialog is an honest fallback; sheets, menus and VM dialogs are not a desktop surface.
                guard standard || (process.kind == .host && subrole == kAXDialogSubrole) else { continue }
                if process.kind == .virtualMachine, ParallelsWindowPolicy.framesMatch(axRect, axRect) {
                    vmWindowPresent = true
                }
                if standard, ParallelsWindowPolicy.framesMatch(axRect, axRect) {
                    largestStandard[process.kind] = max(largestStandard[process.kind] ?? 0, axRect.width * axRect.height)
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
        if !compactTargetPresent { compactTarget = nil }
        let compactID = compactTarget.flatMap { target in
            windows.first { $0.candidate.pid == target.candidate.pid && CFEqual($0.element, target.element) }?.candidate.id
        }
        // Keep the same AX desktop during native resizing while WindowServer catches up.
        if compactTargetPresent, compactID == nil,
           !(compactTarget?.candidate.kind == .host && vmWindowPresent) { return nil }
        // During a VM move/resize, wait for WindowServer to catch up instead of moving the host as a fallback.
        guard let selected = ParallelsWindowPolicy.select(windows.map(\.candidate), preferredID: preferredID,
                                                         vmWindowPresent: vmWindowPresent, compactID: compactID),
              let window = windows.first(where: { $0.candidate.id == selected.id }) else { return nil }
        // The desktop window mid-resize has no CG match yet; a smaller dialog must not stand in for it (or become remembered).
        guard selected.id == compactID || selected.rect.width * selected.rect.height >= (largestStandard[selected.kind] ?? 0) - 1 else { return nil }
        if compactTarget != nil { compactTarget = selected.id == compactID ? window : nil }
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
        guard let window = selectedWindow() else { return false }
        return resize(size, window: window)
    }

    static func requestCompactSize(available: CGSize) -> Bool {
        guard let window = selectedWindow(),
              let target = WorkSurfaceCompactLayout.size(current: window.candidate.axRect.size, available: available) else { return false }
        let current = window.candidate.axRect.size
        let alreadyFits = abs(target.width - current.width) < 1 && abs(target.height - current.height) < 1
        guard alreadyFits || resize(target, window: window) else { return false }
        compactTarget = window
        return true
    }

    private static func resize(_ size: CGSize, window: Window) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width >= 240, size.height >= 180 else { return false }
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
