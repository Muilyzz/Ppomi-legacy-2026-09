import AppKit
import ApplicationServices

/// Executable identity precedes title matching. An unrelated window called Android is never a control target.
enum AndroidWindowPolicy {
    enum Kind { case mirror, emulator }
    static let mirrorTitle = "Ppomi Android"
    static let minimumSize = CGSize(width: 160, height: 180)

    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let kind: Kind
        let title: String
        let rect: CGRect
        let axRect: CGRect
        let isStandard: Bool
        let isMain: Bool
        let isOnScreen: Bool
        let layer: Int
    }

    static func kind(executablePath: String?, mirrorPaths: Set<String>, emulatorPaths: Set<String>) -> Kind? {
        guard let executablePath else { return nil }
        if mirrorPaths.contains(executablePath) { return .mirror }
        if emulatorPaths.contains(executablePath) { return .emulator }
        return nil
    }

    static func acceptsTitle(_ title: String, kind: Kind) -> Bool {
        switch kind {
        case .mirror: return title == mirrorTitle
        case .emulator: return title.hasPrefix("Android Emulator - ")
        }
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite) &&
            a.width >= minimumSize.width && a.height >= minimumSize.height &&
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
            abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    static func select(_ candidates: [Candidate], preferredID: CGWindowID?, mirrorPresent: Bool = false) -> Candidate? {
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            counts[$0.id] == 1 && $0.layer == 0 && $0.isStandard &&
                (!mirrorPresent || $0.kind == .mirror) && acceptsTitle($0.title, kind: $0.kind) &&
                framesMatch($0.rect, $0.axRect)
        }.sorted { a, b in
            if a.kind != b.kind { return a.kind == .mirror }
            if (a.id == preferredID) != (b.id == preferredID) { return a.id == preferredID }
            if a.isMain != b.isMain { return a.isMain }
            let areaA = a.rect.width * a.rect.height, areaB = b.rect.width * b.rect.height
            if areaA != areaB { return areaA > areaB }
            return a.id < b.id
        }.first
    }

    static func compactSize(current: CGSize, available: CGSize) -> CGSize? {
        WorkSurfaceCompactLayout.size(current: current, available: available, minimum: minimumSize)
    }
}

/// Accompany an actual scrcpy or Android Emulator window. Guest operations remain in AndroidRuntime.
@MainActor
enum AndroidWindow {
    static let defaultSize = CGSize(width: 360, height: 760)
    private struct Process {
        let app: NSRunningApplication
        let kind: AndroidWindowPolicy.Kind
    }
    private struct Window {
        let candidate: AndroidWindowPolicy.Candidate
        let element: AXUIElement
        let app: NSRunningApplication
    }
    private static var preferredID: CGWindowID?
    private static var pathCache: (checkedAt: TimeInterval, mirrors: Set<String>, emulators: Set<String>)?

    private static func executablePaths() -> (mirrors: Set<String>, emulators: Set<String>) {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = pathCache, now - cache.checkedAt < 5 { return (cache.mirrors, cache.emulators) }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func installed(_ paths: [String]) -> Set<String> {
            Set(paths.compactMap { path in
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
            })
        }
        let mirrors = installed([environment["PPOMI_SCRCPY"], "/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"].compactMap { $0 })
        let roots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk", "\(home)/Android/Sdk"].compactMap { $0 }
        // The SDK launcher spawns this exact qemu executable on Apple Silicon; do not match process names.
        let emulators = installed(roots.flatMap { root in
            ["emulator/emulator", "emulator/qemu/darwin-aarch64/qemu-system-aarch64",
             "emulator/qemu/darwin-x86_64/qemu-system-x86_64"].map { root + "/" + $0 }
        })
        pathCache = (now, mirrors, emulators)
        return (mirrors, emulators)
    }

    private static func cgWindows(_ options: CGWindowListOption = .optionAll) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func processes() -> [Process] {
        let paths = executablePaths()
        // SDL/Qt command line applications are not always included in Workspace's application list.
        var apps = NSWorkspace.shared.runningApplications
        let known = Set(apps.map(\.processIdentifier))
        let windowPIDs = Set(cgWindows().compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        apps += windowPIDs.subtracting(known).compactMap { NSRunningApplication(processIdentifier: $0) }
        return apps.compactMap { app in
            guard !app.isTerminated,
                  let kind = AndroidWindowPolicy.kind(executablePath: app.executableURL?.resolvingSymlinksInPath().path,
                                                       mirrorPaths: paths.mirrors, emulatorPaths: paths.emulators) else { return nil }
            return Process(app: app, kind: kind)
        }
    }

    static var isRunning: Bool { !processes().isEmpty }
    static var isFrontmost: Bool { processes().contains { $0.app.isActive } }
    static var processIdentifier: pid_t? { selectedWindow()?.candidate.pid }
    static var hasMirror: Bool {
        let mirrors = Set(processes().filter { $0.kind == .mirror }.map { $0.app.processIdentifier })
        return cgWindows().contains {
            guard let pid = $0[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return mirrors.contains(pid) && $0[kCGWindowName as String] as? String == AndroidWindowPolicy.mirrorTitle
        }
    }

    private static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = value["X"], let y = value["Y"], let width = value["Width"], let height = value["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = Mirroring.attr(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = Mirroring.attr(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func selectedWindow() -> Window? {
        guard AXIsProcessTrusted() else { return nil }
        let cg = cgWindows()
        var windows: [Window] = []
        var mirrorPresent = false
        for process in processes() {
            let application = AXUIElementCreateApplication(process.app.processIdentifier)
            for ax in (Mirroring.attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                guard Mirroring.attr(ax, kAXRoleAttribute) as? String == kAXWindowRole,
                      let title = Mirroring.attr(ax, kAXTitleAttribute) as? String,
                      AndroidWindowPolicy.acceptsTitle(title, kind: process.kind) else { continue }
                let subrole = Mirroring.attr(ax, kAXSubroleAttribute) as? String
                guard subrole == nil || subrole == kAXStandardWindowSubrole, let axRect = frame(ax) else { continue }
                if process.kind == .mirror { mirrorPresent = true }
                let matches = cg.filter {
                    ($0[kCGWindowOwnerPID as String] as? pid_t) == process.app.processIdentifier &&
                        ($0[kCGWindowLayer as String] as? Int) == 0 &&
                        bounds($0).map { AndroidWindowPolicy.framesMatch($0, axRect) } == true
                }
                guard matches.count == 1, let cgWindow = matches.first,
                      let id = cgWindow[kCGWindowNumber as String] as? UInt32, let rect = bounds(cgWindow) else { continue }
                let candidate = AndroidWindowPolicy.Candidate(id: id, pid: process.app.processIdentifier, kind: process.kind,
                    title: title, rect: rect, axRect: axRect, isStandard: true,
                    isMain: Mirroring.attr(ax, kAXMainAttribute) as? Bool == true,
                    isOnScreen: cgWindow[kCGWindowIsOnscreen as String] as? Bool == true, layer: 0)
                windows.append(Window(candidate: candidate, element: ax, app: process.app))
            }
        }
        guard let selected = AndroidWindowPolicy.select(windows.map(\.candidate), preferredID: preferredID, mirrorPresent: mirrorPresent),
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
        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
    }

    static func resize(_ size: CGSize) -> Bool {
        guard let window = selectedWindow() else { return false }
        return resize(size, window: window)
    }
    private static func resize(_ size: CGSize, window: Window) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= AndroidWindowPolicy.minimumSize.width, size.height >= AndroidWindowPolicy.minimumSize.height else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value) == .success
    }
    static func requestCompactSize(available: CGSize) -> Bool {
        guard let window = selectedWindow(),
              let target = AndroidWindowPolicy.compactSize(current: window.candidate.axRect.size, available: available) else { return false }
        let current = window.candidate.axRect.size
        return (abs(target.width - current.width) < 1 && abs(target.height - current.height) < 1) || resize(target, window: window)
    }

    /// Activation is reserved for user selection/reopen; polling never raises an external app.
    static func revealWindow() -> Bool {
        guard let window = selectedWindow() else { return false }
        if window.app.isHidden { window.app.unhide() }
        if Mirroring.attr(window.element, kAXMinimizedAttribute) as? Bool == true {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let live = liveWindow(), isInFront(live.id) { return true }
        window.app.activate(options: [])
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
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
}
