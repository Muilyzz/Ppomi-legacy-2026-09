import AppKit
import ApplicationServices

/// The agent's existing native window accompanies Ppomi; this adapter does not read chats or configure MCP.
@MainActor
enum AgentApp: String, CaseIterable, Identifiable {
    case chatGPT, codex

    nonisolated var id: String { rawValue }
    var displayName: String { AgentWindow.installations(for: self).first?.displayName ?? (self == .chatGPT ? "ChatGPT" : "Codex") }
    nonisolated var symbolName: String { self == .chatGPT ? "bubble.left.and.bubble.right" : "terminal" }
    nonisolated var bundleID: String { self == .chatGPT ? "com.openai.chat" : "com.openai.codex" }
    nonisolated var defaultSize: CGSize { CGSize(width: 760, height: 760) }
    nonisolated var minimumSize: CGSize { AgentWindowPolicy.minimumSize }
    static var defaultApp: AgentApp { allCases.first(where: \.isInstalled) ?? .chatGPT }
    var isInstalled: Bool { !AgentWindow.installations(for: self).isEmpty }
    var installed: Bool { isInstalled }
    var isRunning: Bool { !AgentWindow.processes(for: self).isEmpty }
    var isFrontmost: Bool { AgentWindow.processes(for: self).contains(where: \.isActive) }
    var processIdentifier: pid_t? { AgentWindow.processIdentifier(for: self) }

    func liveWindow() -> (id: CGWindowID, rect: CGRect)? { AgentWindow.liveWindow(for: self) }
    func axFrame() -> CGRect? { AgentWindow.axFrame(for: self) }
    func windowState() -> (id: CGWindowID, frame: CGRect, isMinimized: Bool)? { AgentWindow.windowState(for: self) }
    @discardableResult func setMinimized(_ minimized: Bool) -> Bool { AgentWindow.setMinimized(minimized, for: self) }
    func place(_ origin: CGPoint) { AgentWindow.place(origin, for: self) }
    @discardableResult func resize(_ size: CGSize) -> Bool { AgentWindow.resize(size, for: self) }
    @discardableResult func revealWindow(allowing pids: Set<pid_t> = []) -> Bool {
        AgentWindow.revealWindow(for: self, allowing: pids)
    }
    func isInFront(_ id: CGWindowID, allowing pids: Set<pid_t> = []) -> Bool {
        AgentWindow.isInFront(id, for: self, allowing: pids)
    }
    func launch() { AgentWindow.launch(self) }
}

/// Pure policy, separate from AX permissions and app activation so selection/order can be tested without a desktop.
enum AgentWindowPolicy {
    static let minimumSize = CGSize(width: 480, height: 360)

    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let rect: CGRect
        let axRect: CGRect
        let isStandard: Bool
        let isModal: Bool
        let isMain: Bool
        let isOnScreen: Bool
        let layer: Int
    }

    static func usableFrame(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) &&
            rect.size.width >= minimumSize.width && rect.size.height >= minimumSize.height
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        usableFrame(a) && usableFrame(b) &&
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
            abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    static func select(_ candidates: [Candidate], preferredID: CGWindowID?) -> Candidate? {
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            counts[$0.id] == 1 && $0.layer == 0 && $0.isStandard && !$0.isModal && framesMatch($0.rect, $0.axRect)
        }.sorted { a, b in
            if (a.id == preferredID) != (b.id == preferredID) { return a.id == preferredID }
            if a.isMain != b.isMain { return a.isMain }
            if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
            let areaA = a.rect.width * a.rect.height, areaB = b.rect.width * b.rect.height
            if areaA != areaB { return areaA > areaB }
            return a.id < b.id
        }.first
    }

    /// Bundle and executable identities both come from installed app metadata. Names and titles are never identities.
    static func matchesProcess(bundleID: String?, executablePath: String?, expectedBundleID: String,
                               installedExecutables: Set<String>) -> Bool {
        bundleID == expectedBundleID && executablePath.map(installedExecutables.contains) == true
    }

    static func isInFront(id: CGWindowID, pid: pid_t, allowedPIDs: Set<pid_t>, windows: [MirroringOrder.Window]) -> Bool {
        for window in windows {
            if window.id == id, window.owner == pid, window.layer == 0 { return true }
            if window.layer == 0, window.owner != pid, !allowedPIDs.contains(window.owner) { return false }
        }
        return false
    }
}

@MainActor
private enum AgentWindow {
    struct Installation {
        let url: URL
        let executablePath: String
        let displayName: String
    }
    private struct Window {
        let candidate: AgentWindowPolicy.Candidate
        let element: AXUIElement
        let app: NSRunningApplication
    }
    private static var installationCache: [AgentApp: (checkedAt: TimeInterval, values: [Installation])] = [:]
    private static var preferred: [AgentApp: Window] = [:]

    static func installations(for agent: AgentApp) -> [Installation] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = installationCache[agent], now - cache.checkedAt < 5 { return cache.values }
        // The local Codex build can be named ChatGPT.app. Inspect both paths and trust CFBundleIdentifier.
        let roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var urls = roots.flatMap { root in ["ChatGPT.app", "Codex.app"].map { root.appendingPathComponent($0) } }
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleID) { urls.insert(registered, at: 0) }
        var seen = Set<String>()
        let values = urls.compactMap { url -> Installation? in
            let url = url.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted, let bundle = Bundle(url: url), bundle.bundleIdentifier == agent.bundleID,
                  let executable = bundle.executableURL?.resolvingSymlinksInPath(),
                  FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            return Installation(url: url, executablePath: executable.path, displayName: name)
        }
        installationCache[agent] = (now, values)
        return values
    }

    static func processes(for agent: AgentApp) -> [NSRunningApplication] {
        let executables = Set(installations(for: agent).map(\.executablePath))
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && AgentWindowPolicy.matchesProcess(bundleID: $0.bundleIdentifier,
                executablePath: $0.executableURL?.resolvingSymlinksInPath().path,
                expectedBundleID: agent.bundleID, installedExecutables: executables)
        }.sorted { $0.processIdentifier < $1.processIdentifier }
    }

    static func processIdentifier(for agent: AgentApp) -> pid_t? {
        selectedWindow(for: agent)?.candidate.pid ?? processes(for: agent).first?.processIdentifier
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? { Mirroring.attr(element, name) }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attr(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attr(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func usableAXWindow(_ element: AXUIElement) -> Bool {
        attr(element, kAXRoleAttribute) as? String == kAXWindowRole &&
            attr(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
            attr(element, kAXModalAttribute) as? Bool != true &&
            frame(element).map(AgentWindowPolicy.usableFrame) == true
    }

    private static func cgWindows(_ options: CGWindowListOption = .optionAll) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = value["X"], let y = value["Y"], let width = value["Width"], let height = value["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func selectedWindow(for agent: AgentApp) -> Window? {
        guard AXIsProcessTrusted() else { return nil }
        let cg = cgWindows(), running = processes(for: agent)
        var windows: [Window] = []
        var preferredStillExists = false
        for app in running {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            let axWindows = (attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for ax in axWindows {
                guard usableAXWindow(ax), let axRect = frame(ax) else { continue }
                if let old = preferred[agent], old.candidate.pid == app.processIdentifier, CFEqual(old.element, ax) {
                    preferredStillExists = true
                }
                let matches = cg.filter {
                    ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier &&
                        ($0[kCGWindowLayer as String] as? Int) == 0 &&
                        bounds($0).map { AgentWindowPolicy.framesMatch($0, axRect) } == true
                }
                guard matches.count == 1, let match = matches.first,
                      let id = match[kCGWindowNumber as String] as? UInt32, let rect = bounds(match) else { continue }
                windows.append(Window(candidate: .init(id: id, pid: app.processIdentifier, rect: rect, axRect: axRect,
                    isStandard: true, isModal: false, isMain: attr(ax, kAXMainAttribute) as? Bool == true,
                    isOnScreen: match[kCGWindowIsOnscreen as String] as? Bool == true, layer: 0), element: ax, app: app))
            }
        }
        // During a move/resize, a transient AX/CG mismatch must not redirect the layout to another chat window.
        if preferredStillExists, let old = preferred[agent], !windows.contains(where: { $0.candidate.id == old.candidate.id }) {
            return nil
        }
        guard let candidate = AgentWindowPolicy.select(windows.map(\.candidate), preferredID: preferred[agent]?.candidate.id),
              let result = windows.first(where: { $0.candidate.id == candidate.id }) else {
            if !preferredStillExists { preferred[agent] = nil }
            return nil
        }
        preferred[agent] = result
        return result
    }

    /// A resize may precede a place in one explicit action. Keep using the already-verified AX window while CG catches up.
    private static func mutationWindow(for agent: AgentApp) -> Window? {
        if let current = selectedWindow(for: agent) { return current }
        guard AXIsProcessTrusted(), let old = preferred[agent],
              processes(for: agent).contains(where: { $0.processIdentifier == old.candidate.pid }),
              usableAXWindow(old.element) else { return nil }
        return old
    }

    static func liveWindow(for agent: AgentApp) -> (id: CGWindowID, rect: CGRect)? {
        guard let window = selectedWindow(for: agent), window.candidate.isOnScreen else { return nil }
        return (window.candidate.id, window.candidate.rect)
    }

    static func axFrame(for agent: AgentApp) -> CGRect? {
        guard let window = mutationWindow(for: agent) else { return nil }
        return frame(window.element)
    }

    static func windowState(for agent: AgentApp) -> (id: CGWindowID, frame: CGRect, isMinimized: Bool)? {
        guard let window = mutationWindow(for: agent), let rect = frame(window.element) else { return nil }
        return (window.candidate.id, rect, attr(window.element, kAXMinimizedAttribute) as? Bool == true)
    }

    /// A records/chat tab switch affects this one native window, never every window owned by the agent app.
    static func setMinimized(_ minimized: Bool, for agent: AgentApp) -> Bool {
        guard let window = mutationWindow(for: agent) else { return false }
        return AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    static func place(_ origin: CGPoint, for agent: AgentApp) {
        guard origin.x.isFinite, origin.y.isFinite, let window = mutationWindow(for: agent) else { return }
        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
    }

    static func resize(_ size: CGSize, for agent: AgentApp) -> Bool {
        guard AgentWindowPolicy.usableFrame(CGRect(origin: .zero, size: size)),
              let window = mutationWindow(for: agent) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value) == .success
    }

    static func revealWindow(for agent: AgentApp, allowing pids: Set<pid_t>) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let window = mutationWindow(for: agent)
        guard let running = window?.app ?? processes(for: agent).first else { return false }
        // WindowServer may omit an initially minimized window. Only explicit reveal may unminimize an AX-only fallback;
        // placement and reported success still require a subsequent unambiguous AX/CG match.
        let element = window?.element ?? revealFallback(in: running)
        if running.isHidden { running.unhide() }
        if let element {
            if attr(element, kAXMinimizedAttribute) as? Bool == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if let live = liveWindow(for: agent), isInFront(live.id, for: agent, allowing: pids) { return true }
        running.activate(options: [])
        if let element { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
        guard let live = liveWindow(for: agent) else { return false }
        return isInFront(live.id, for: agent, allowing: pids)
    }

    private static func revealFallback(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.filter(usableAXWindow).sorted { a, b in
            let mainA = attr(a, kAXMainAttribute) as? Bool == true, mainB = attr(b, kAXMainAttribute) as? Bool == true
            if mainA != mainB { return mainA }
            let frameA = frame(a) ?? .zero, frameB = frame(b) ?? .zero
            return frameA.width * frameA.height > frameB.width * frameB.height
        }.first
    }

    static func isInFront(_ id: CGWindowID, for agent: AgentApp, allowing pids: Set<pid_t>) -> Bool {
        guard let selected = selectedWindow(for: agent), selected.candidate.id == id else { return false }
        let windows = cgWindows(.optionOnScreenOnly).compactMap { window -> MirroringOrder.Window? in
            guard let number = window[kCGWindowNumber as String] as? UInt32,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int else { return nil }
            return .init(id: number, owner: owner, layer: layer)
        }
        return AgentWindowPolicy.isInFront(id: id, pid: selected.candidate.pid,
            allowedPIDs: pids.union([ProcessInfo.processInfo.processIdentifier]), windows: windows)
    }

    static func launch(_ agent: AgentApp) {
        guard let installation = installations(for: agent).first else { return }
        NSWorkspace.shared.openApplication(at: installation.url, configuration: .init(), completionHandler: nil)
    }
}
