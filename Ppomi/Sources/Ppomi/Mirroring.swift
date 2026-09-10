// iPhone Mirroring ("iPhone 미러링", com.apple.ScreenContinuity) seen through CGWindowList and accessibility: find the window,
// move it, read the overlay state, press the reconnect button. Ported from phone.swift (the tested CLI); the CLI's fail() became
// a log line, so every call survives a missing window or a missing Accessibility grant.
import AppKit
import ApplicationServices

enum Mirroring {
    static let bundleID = "com.apple.ScreenContinuity"
    static let defaultSize = CGSize(width: 348, height: 766)      // the window's usual size, for when there is no window to measure

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// The Accessibility grant, logged instead of the CLI's fail().
    @discardableResult
    static func trusted(_ what: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        print("Mirroring.\(what): Accessibility 권한 필요 (시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용)")
        return false
    }

    // MARK: windows

    /// On-screen layer-0 windows of the mirroring app, largest first. CG coords (origin top-left of the main display).
    /// CGWindowList sometimes reports a bogus 37x119 frame for the live window (mid-animation), so callers that only need
    /// the ID must not filter on size.
    private static func cgWindows() -> [(id: CGWindowID, rect: CGRect)] {
        guard let pid = app()?.processIdentifier else { return [] }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w -> (id: CGWindowID, rect: CGRect)? in
            guard (w["kCGWindowOwnerPID"] as? pid_t) == pid, (w["kCGWindowLayer"] as? Int) == 0,
                  let b = w["kCGWindowBounds"] as? [String: CGFloat], let id = w["kCGWindowNumber"] as? Int,
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return nil }
            return (CGWindowID(id), CGRect(x: x, y: y, width: width, height: height))
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
    }
    static func windows() -> [CGRect] { cgWindows().map(\.rect) }
    static func windowID() -> CGWindowID? { cgWindows().first?.id }       // for screencapture -l
    /// The live window (taller than a Stage Manager thumbnail) with its id, for docking and z-ordering against it.
    static func liveWindow() -> (id: CGWindowID, rect: CGRect)? { cgWindows().first { $0.rect.height > 200 } }

    /// One AX attribute, nil when missing.
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// The largest AX window (taller than 200: not a thumbnail) with its frame — the same "largest" rule as windows(),
    /// so capture/tap/place all agree on one window.
    static func axWindowAndFrame() -> (AXUIElement, CGRect)? {
        guard let pid = app()?.processIdentifier,
              let wins = attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGRect)?
        for w in wins {
            var p = CGPoint.zero, s = CGSize.zero
            guard let pos = attr(w, kAXPositionAttribute), let size = attr(w, kAXSizeAttribute),
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
                  s.height > 200 else { continue }
            if s.width * s.height > (best?.1.width ?? 0) * (best?.1.height ?? 0) { best = (w, CGRect(origin: p, size: s)) }
        }
        return best
    }
    static func axWindow() -> AXUIElement? { axWindowAndFrame()?.0 }
    static func axFrame() -> CGRect? { axWindowAndFrame()?.1 }

    /// Explicit reveal also needs to find a minimized or parked window that CG does not currently list as live.
    private static func primaryAXWindow(in application: AXUIElement) -> AXUIElement? {
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let value = attr(application, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        let windows = (attr(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        func area(_ window: AXUIElement) -> CGFloat {
            guard let value = attr(window, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return 0 }
            var size = CGSize.zero
            guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return 0 }
            return max(0, size.width) * max(0, size.height)
        }
        return windows.max { area($0) < area($1) }
    }

    /// Read-only verification for explicit reveal and its subsequent transition. Does not activate either app.
    static func isInFrontOfOtherApplications(_ phoneID: CGWindowID) -> Bool {
        guard let pid = app()?.processIdentifier else { return false }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows = list.compactMap { window -> MirroringOrder.Window? in
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int else { return nil }
            return .init(id: id, owner: owner, layer: layer)
        }
        return MirroringOrder.isInFront(phoneID: phoneID, phonePID: pid,
                                         ppomiPID: ProcessInfo.processInfo.processIdentifier, windows: windows)
    }

    // MARK: placement

    /// iPhone Mirroring owns its size presets. Use its Small menu item once for an explicit layout request.
    /// A disconnected phone may disable this command; never replace it with an unsupported AX size write.
    @discardableResult
    static func requestSmallSize() -> Bool {
        guard trusted("requestSmallSize"), let running = app(),
              let value = attr(AXUIElementCreateApplication(running.processIdentifier), kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let menuBar = value as! AXUIElement
        let menus = (attr(menuBar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        guard let viewMenu = menus.first(where: { menu in
            guard let title = attr(menu, kAXTitleAttribute) as? String else { return false }
            return ["보기", "View"].contains(title)
        }) else { return false }

        func smallItem(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if attr(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
               let title = attr(element, kAXTitleAttribute) as? String,
               ["작게", "Smaller"].contains(title) { return element }
            guard depth < 3 else { return nil }
            for child in (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if let item = smallItem(in: child, depth: depth + 1) { return item }
            }
            return nil
        }
        guard let item = smallItem(in: viewMenu), attr(item, kAXEnabledAttribute) as? Bool == true else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The screen a CG rect lies on (AppKit screens have a bottom-left origin; CG has top-left of the main display).
    static func screen(containing rect: CGRect) -> NSScreen? {
        let main = NSScreen.screens.first?.frame ?? .zero
        return NSScreen.screens.first(where: { sc in
            CGRect(x: sc.frame.minX, y: main.maxY - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height).intersects(rect)
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The one reference position for the mirroring window, shared by collection (am.py `phone place center`) and the kiosk:
    /// the centre of the screen the window is on. CG coords, which is what the AX position takes.
    static func homePoint() -> CGPoint {
        let rect = windows().first ?? CGRect(origin: .zero, size: defaultSize)
        let main = NSScreen.screens.first?.frame ?? .zero
        guard let s = screen(containing: rect) else { return rect.origin }
        return CGPoint(x: s.frame.minX + (s.frame.width - rect.width) / 2,
                       y: (main.maxY - s.frame.maxY) + (s.frame.height - rect.height) / 2)
    }

    /// Move the mirroring window (AX position, CG coords). Sleeps 0.3 s so the CG window list reflects the move.
    static func place(_ p: CGPoint) {
        guard trusted("place") else { return }
        guard let w = axWindow() else { print("Mirroring.place: no AX window"); return }
        var pt = p
        if let v = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        usleep(300_000)
    }

    /// Bring the mirroring app to the front (AX frontmost; NSRunningApplication.activate is unreliable for it).
    /// `wait` blocks up to 2 s until it really is frontmost — needed before posting input, not for the kiosk's pin.
    static func activate(wait: Bool = false) {
        guard trusted("activate"), let app = app() else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard wait else { return }
        for _ in 0..<20 {
            if (attr(ax, kAXFrontmostAttribute) as? Bool) == true { usleep(150_000); return }
            usleep(100_000)
        }
        print("Mirroring.activate: could not bring iPhone Mirroring to front")
    }

    /// Pull the mirroring window out of a Stage Manager thumbnail and wait until AX sees a real frame (height > 200).
    @discardableResult
    static func stage(timeout: TimeInterval = 2) -> Bool {
        guard app() != nil else { return false }
        activate(wait: true)
        let steps = max(1, Int(timeout / 0.1))
        for i in 0...steps {
            if let f = axFrame(), f.height > 200 { return true }
            if i < steps { usleep(100_000) }
        }
        return false
    }

    /// Only for an explicit Dock/menu reveal. A live CG window may still be behind another application.
    /// Try raising that window without changing application focus; activate once only if it remains buried or parked.
    @discardableResult
    static func revealWindow() -> Bool {
        guard trusted("revealWindow"), let running = app() else { return false }
        if running.isHidden { running.unhide() }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        if let window = primaryAXWindow(in: application) {
            if (attr(window, kAXMinimizedAttribute) as? Bool) == true {
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
                   settable.boolValue {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if let phone = liveWindow(), isInFrontOfOtherApplications(phone.id) { return true }
        _ = stage()
        guard let phone = liveWindow() else { return false }
        return isInFrontOfOtherApplications(phone.id)
    }

    // MARK: state, read from the window's accessibility tree

    /// Every value/title/description under `e` (depth ≤ 6). The overlay texts ("연결이 중단됨", "iPhone 사용 중") live here.
    private static func texts(_ e: AXUIElement, depth: Int = 0, into out: inout [String]) {
        guard attr(e, "AXHidden") as? Bool != true else { return }
        for a in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let t = attr(e, a) as? String, !t.isEmpty { out.append(t) }
        }
        guard depth < 6 else { return }
        for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { texts(k, depth: depth + 1, into: &out) }
    }

    struct ButtonEvidence: Equatable {
        let labels: [String]
        let enabled: Bool
    }

    struct ConnectionSnapshot {
        let state: MirrorState
        let connected: Bool
        let inUse: Bool
        let needsUnlock: Bool
        let connecting: Bool
        let canReconnect: Bool
    }

    /// These names identify the native app's overlay controls, never OCR text inside the phone image.
    static let reconnectLabels: Set<String> = ["다시 시도", "재개", "연결", "다시 연결", "재연결", "Try Again", "Resume", "Connect", "Reconnect"]
    private static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func mentionsInUse(_ compact: String) -> Bool {
        compact.contains("iphone사용중") || compact.contains("iphone을사용중") || compact.contains("iphoneinuse") ||
            compact.contains("iphoneisinuse") || compact.contains("iphone을잠그십시오") || compact.contains("lockyouriphone")
    }

    static func isReconnectButton(_ button: ButtonEvidence) -> Bool {
        button.enabled && button.labels.contains { reconnectLabels.contains(normalized($0)) }
    }

    /// A connected stream has its native Home and App Switcher controls. An empty AX tree or a
    /// connecting overlay is insufficient evidence to send input, even if no error text is present.
    static func connectionSnapshot(texts: [String], buttons: [ButtonEvidence], hasWindow: Bool = true) -> ConnectionSnapshot {
        guard hasWindow else { return .init(state: .none, connected: false, inUse: false, needsUnlock: false, connecting: false, canReconnect: false) }
        let all = texts.joined(separator: " ").lowercased().filter { !$0.isWhitespace }
        let inUse = mentionsInUse(all)
        let needsUnlock = all.contains("iphone잠금해제") || all.contains("unlockyouriphone")
        let connecting = all.contains("연결중") || all.contains("connecting")
        let nativeLabels = Set(buttons.filter(\.enabled).flatMap(\.labels).map(normalized))
        let hasHome = !nativeLabels.isDisjoint(with: ["홈", "Home"])
        let hasSwitcher = !nativeLabels.isDisjoint(with: ["앱 전환기", "App Switcher"])
        let hasRecoveryControl = buttons.contains { $0.labels.contains { reconnectLabels.contains(normalized($0)) } }
        let textState = classify(texts)
        let ready = !inUse && !needsUnlock && !connecting && !hasRecoveryControl && textState == .connected && hasHome && hasSwitcher
        let state: MirrorState = ready ? .connected : textState == .connected ? .disconnected : textState
        return .init(state: state, connected: ready, inUse: inUse, needsUnlock: needsUnlock, connecting: connecting,
                     canReconnect: !ready && !needsUnlock && buttons.filter(isReconnectButton).count == 1)
    }

    /// Read native button identity, enablement and labels from this app's window only.
    private static func buttons(in root: AXUIElement) -> [(AXUIElement, ButtonEvidence)] {
        var result: [(AXUIElement, ButtonEvidence)] = [], seen: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard attr(element, "AXHidden") as? Bool != true else { return }
            guard !seen.contains(where: { CFEqual($0, element) }) else { return }
            seen.append(element)
            if attr(element, kAXRoleAttribute) as? String == kAXButtonRole {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attr(element, $0) as? String }
                result.append((element, .init(labels: labels, enabled: attr(element, kAXEnabledAttribute) as? Bool == true)))
            }
            guard depth < 8 else { return }
            for child in (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return result
    }

    static func connectionSnapshot() -> ConnectionSnapshot {
        guard let window = axWindow() else { return connectionSnapshot(texts: [], buttons: [], hasWindow: false) }
        var labels: [String] = []
        texts(window, into: &labels)
        return connectionSnapshot(texts: labels, buttons: buttons(in: window).map { $0.1 })
    }

    static func state() -> MirrorState { connectionSnapshot().state }

    /// The overlay texts → state. Pure, so it can be checked without a window.
    static func classify(_ ts: [String]) -> MirrorState {
        let all = ts.joined(separator: " ")
        let compact = all.lowercased().filter { !$0.isWhitespace }
        if ts.isEmpty || all.contains("iPhone 잠금 해제") || all.contains("연결 중") || all.localizedCaseInsensitiveContains("connecting") { return .disconnected }
        if mentionsInUse(compact) { return .inUse }
        if all.contains("중단됨") || all.contains("다시 시도") { return .disconnected }
        if all.contains("일시 정지") || ts.contains("재개") { return .paused }
        return .connected
    }

    /// Press one exact, enabled native recovery button. Duplicate candidates and stale/disabled controls stop the attempt.
    @discardableResult
    static func reconnect() -> Bool {
        guard trusted("reconnect"), let w = axWindow() else { return false }
        var labels: [String] = []
        texts(w, into: &labels)
        let observed = buttons(in: w)
        guard connectionSnapshot(texts: labels, buttons: observed.map { $0.1 }).canReconnect else { return false }
        let candidates = observed.filter { isReconnectButton($0.1) }
        guard candidates.count == 1 else { return false }
        return AXUIElementPerformAction(candidates[0].0, kAXPressAction as CFString) == .success
    }

    /// The gate and idle watcher share the same exclusive recovery lease and state machine.
    /// Failure to acquire the lease permits observation only, never an additional press.
    static func recoverOnce(allowInUse: Bool = true, polls: Int = 6,
                            ledgerPath: String = AppSettings.dbPath) -> ConnectionSnapshot {
        guard let lease = try? ScreenControlLease.beginMirroringRecovery(ledgerPath: ledgerPath) else { return connectionSnapshot() }
        defer { lease.release() }
        return recoverOnce(observe: { connectionSnapshot() }, press: { reconnect() }, allowInUse: allowInUse, polls: polls)
    }

    /// One action per attempt, followed only by observation. Explicit work may try a recovery button
    /// beside an in-use message; the background watcher must leave that same message alone.
    static func recoverOnce(observe: () -> ConnectionSnapshot,
                            press: () -> Bool,
                            settle: () -> Void = { Thread.sleep(forTimeInterval: 0.5) },
                            allowInUse: Bool = true,
                            polls: Int = 6) -> ConnectionSnapshot {
        var snapshot = observe()
        if snapshot.connected || snapshot.needsUnlock || (!allowInUse && snapshot.inUse) { return snapshot }
        if snapshot.canReconnect {
            guard press() else { return observe() }
        } else if !snapshot.connecting {
            return snapshot
        }
        for _ in 0..<max(1, min(polls, 6)) {
            settle()
            snapshot = observe()
            if snapshot.connected || snapshot.needsUnlock { break }
        }
        return snapshot
    }
}

/// Turns the mirroring window's accessibility events into state changes, with a 5 s poll as belt and braces (some transitions
/// raise no AX event) and to pick the app up when it launches later. Main thread only; onChange fires only on a change.
@MainActor
final class MirrorWatcher {
    var onChange: (MirrorState) -> Void
    private(set) var last: MirrorState = .none
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: Timer?
    private var checkPending = false
    private var warned = false

    init(onChange: @escaping (MirrorState) -> Void) { self.onChange = onChange }
    deinit { if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) } }

    func start() {
        stop()
        let t = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { self.attach(); self.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        attach(); check()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        detach()
    }

    /// (Re)attach the AXObserver when the mirroring app is running and is not the process we already observe.
    private func attach() {
        guard let app = Mirroring.app() else { detach(); return }
        if observer != nil, app.processIdentifier == observedPID { return }
        detach()
        guard AXIsProcessTrusted() else {
            if !warned { warned = true; Mirroring.trusted("watch") }
            return
        }
        var obs: AXObserver?
        let made = AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            MainActor.assumeIsolated { Unmanaged<MirrorWatcher>.fromOpaque(refcon).takeUnretainedValue().scheduleCheck() }
        }, &obs)
        guard made == .success, let o = obs else { print("MirrorWatcher: AXObserverCreate failed (\(made.rawValue))"); return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXLayoutChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification,
                  kAXCreatedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(o, ax, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observer = o; observedPID = app.processIdentifier
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observer = nil; observedPID = 0
    }

    /// AX events come in bursts; walk the tree once per burst.
    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self.checkPending = false; self.check() } }
    }

    private var lastRetry = Date.distantPast

    private func check() {
        var snapshot = Mirroring.connectionSnapshot()
        // Preserve idle recovery, but never try to reclaim a phone that the native app says is in use.
        // Each attempt shares the gate's exclusive recovery lock and observes the resulting state.
        if !snapshot.inUse, !snapshot.needsUnlock, snapshot.canReconnect,
           snapshot.state == .disconnected || snapshot.state == .paused,
           Date().timeIntervalSince(lastRetry) > 20,
           let lease = try? ScreenControlLease.beginControl(ledgerPath: AppSettings.dbPath) {
            defer { lease.release() }
            lastRetry = Date()
            snapshot = Mirroring.recoverOnce(allowInUse: false, polls: 1) // keep the main-thread watcher wait short; its timer observes later progress
        }
        let s = snapshot.state
        guard s != last else { return }
        last = s
        onChange(s)
    }
}
