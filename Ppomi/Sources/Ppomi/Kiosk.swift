// The workbench stays directly behind the selected iPhone or Parallels window. Immersive mode lends
// its existing views to covers around that window without repeatedly activating it.
import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// Navigation leaves the mirroring app active; every explicit raise stays directly behind its window.
/// The workbench window. Its control slot (and a docked agent area) are transparent holes, so a docked native window
/// stays visible whether it is above or below this window; no cross-application z-ordering is attempted.
extension NSApplication {
    /// 앞으로 오기. macOS 14+ 의 activate(ignoringOtherApps:)는 우리가 방금 AX 로 앞세운 미러링 앱에서 활성을 되찾지 못한다(메뉴 막대가 미러링 것으로 남음).
    /// 미러링 앱을 앞세울 때와 같은 AX frontmost 를 우리 자신에게 건다 — 손쉬운 사용 권한이 있을 때(폰 조종에 이미 필요한 권한).
    func activateFront() {
        activate(ignoringOtherApps: true)
        if AXIsProcessTrusted() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}

final class MainPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var hasDockedWindow: Bool { phoneID != nil }
    var surfacePID: pid_t? {
        didSet {
            if oldValue != surfacePID { diagnosticSampler?.updateMirrorPID(surfacePID) }
        }
    }
    var phoneID: CGWindowID? {
        didSet {
            if WindowDiagnostics.enabled, oldValue != phoneID { diagnosticSampler?.updateMirrorPID(surfacePID) }
        }
    }
    private var kioskAction: (() -> Void)?
    private var diagnosticSampler: WindowDiagnosticsSampler?

    func startWindowDiagnostics() {
        guard WindowDiagnostics.enabled, diagnosticSampler == nil else { return }
        diagnosticSampler = WindowDiagnosticsSampler(panelID: CGWindowID(windowNumber), mirrorPID: surfacePID)
        WindowDiagnostics.panel("trace.started", self)
    }

    override func sendEvent(_ event: NSEvent) {
        guard WindowDiagnostics.enabled, WindowDiagnostics.isMouseBoundary(event) else { super.sendEvent(event); return }
        WindowDiagnostics.mouse("before", event: event, panel: self)
        super.sendEvent(event)
        WindowDiagnostics.mouse("after", event: event, panel: self)
    }

    override func becomeKey() {
        WindowDiagnostics.panel("key.become.before", self)
        super.becomeKey()
        WindowDiagnostics.panel("key.become.after", self)
    }

    override func resignKey() {
        WindowDiagnostics.panel("key.resign.before", self)
        super.resignKey()
        WindowDiagnostics.panel("key.resign.after", self)
    }

    /// Bind the button's semantic action so mouse clicks, accessibility presses, and performZoom agree.
    /// The controller supplies its state directly; no application-delegate launch ordering is required.
    func bindKioskButton(_ action: @escaping () -> Void) {
        kioskAction = action
        guard let button = standardWindowButton(.zoomButton) else { return }
        button.target = self
        button.action = #selector(performZoom(_:))
        button.toolTip = "키오스크"
        button.setAccessibilityLabel("키오스크")
    }
    override func performZoom(_ sender: Any?) {
        if let kioskAction { kioskAction() }
        else { super.performZoom(sender) }
    }

    /// True when this panel is the frontmost real window on screen (Stage Manager strip thumbnails are ignored).
    var isFrontmostOnScreen: Bool {
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        // The control windows this app docks (a mirror already on the stage) sit above the panel without making
        // another app the front one.
        let controlPIDs = Set(WorkSurface.allCases.flatMap(\.processIdentifiers))
        for w in l where (w["kCGWindowLayer"] as? Int) == 0 {
            let b = w["kCGWindowBounds"] as? [String: CGFloat] ?? [:]
            guard (b["Width"] ?? 0) >= 200, (b["Height"] ?? 0) >= 200 else { continue }
            if let owner = w["kCGWindowOwnerPID"] as? pid_t, controlPIDs.contains(owner) { continue }
            return (w["kCGWindowNumber"] as? Int ?? 0) == windowNumber
        }
        return false
    }

    /// True when this panel is drawn above the phone (a click on the workbench raised it). CGWindowList is front-to-back.
    func isAbove(_ phone: CGWindowID) -> Bool {
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in l {
            let id = w["kCGWindowNumber"] as? Int ?? 0
            if id == windowNumber { return true }
            if id == Int(phone) { return false }
        }
        return false
    }

}


/// Stable geometry snapshots use WindowServer coordinates (origin at the main screen's top left).
struct DockSnapshot {
    let phoneID: CGWindowID
    let panel: CGRect
    let phone: CGRect
}

enum DockChange: Equatable {
    case none, alignPhone, followPhone

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// A tab click or focus change has no geometry effect. A phone-only move must never be undone.
    static func between(_ previous: DockSnapshot?, and current: DockSnapshot, explicitLayout: Bool) -> DockChange {
        if explicitLayout { return .alignPhone }
        guard let previous, previous.phoneID == current.phoneID else { return .followPhone }
        if !near(previous.panel, current.panel) { return .alignPhone }
        if !near(previous.phone, current.phone) { return .followPhone }
        return .none
    }
}

@MainActor
final class KioskController {
    private let state: AppState
    private let records: NSView
    private let controlToolbar: NSView
    private let sidebar: AgentSidebar
    private let conversation: AgentVoicePanel?
    private var lastFocusRequest = 0
    private var focusLease: ScreenControlLease?
    private var parkedWindows: RecordsWindowParking?
    private var focusLedgerPath: String?
    private var focusSurface: WorkSurface?
    private var focusRestoreFailed = false
    private var sub: AnyCancellable?
    private var askSub: AnyCancellable?, rungAsk: String?
    private var askSteps: [DispatchWorkItem] = []      // 비서의 단계: 톡 → 1분 재촉 → 3분 전화
    private var reportTimer: Timer?                    // 정례 결산: 매일 21:00 톡 한 장, 전화 없음
    private var answeredObserver: NSObjectProtocol?
    private var main: MainPanel?
    private var content: WorkbenchContent?
    private var immersive: ImmersiveKiosk?
    private var wantMain = false
    private var lastShown = 0
    private var tick: Timer?
    private var keyMonitors: [Any] = []
    private var displayObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var revealPhoneOnExit = true
    private var savedFrame: CGRect?
    private var lastDock: DockSnapshot?
    private var mirrorPresence = MirrorPresence()
    private var awaitingPresentedPhone = false
    private var placementRequested = false
    private var displayedSurface: WorkSurface = .iphone
    private var launchingSurfaces = Set<WorkSurface>()
    private struct SurfaceFit {
        var requested = false
        var settleUntil: TimeInterval = 0
    }
    private var surfaceFit: SurfaceFit?
    private var placedDesktopID: CGWindowID?
    private var lastChatOpen = 0
    private var lastWorkbenchShown = 0
    private var revealingOnActivate = false
    private var lastRaiseReveal: TimeInterval = 0
    private var stagePullInFlight = false
    private var stagePullAttempted = false
    private var activateRevealFailedFor: CGWindowID?
    private var lastPointer = NSEvent.mouseLocation
    private var restoredFrame = false
    static let frameAutosaveName = "workbench"
    private(set) var up = false

    private var surface: WorkSurface { displayedSurface }
    private var surfaceSize: CGSize { state.size(for: surface) }

    init(state: AppState, conversation: AgentVoicePanel? = nil) {
        self.state = state
        let rootView = RecordsView().environmentObject(state)
        records = WindowDiagnostics.enabled ? DiagnosticHostingView(rootView: rootView) : WorkbenchHostingView(rootView: rootView)
        records.autoresizingMask = [.width, .height]
        controlToolbar = WorkbenchHostingView(rootView: ControlTargetToolbar().environmentObject(state))
        sidebar = AgentSidebar(state: state)
        self.conversation = conversation
        sub = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
        }
        // The conversation lives inside the workbench's agent column, next to the control slot.
        conversation?.host = { [weak self] in self?.sidebar }
        // 구두 결재: 통화 중 사람이 "승인"/"취소"라고 말하면 차례의 그 선택지를 누른 것과 같다(모델의 말이 아니라 사람의 말).
        conversation?.heard = { [weak self] text in
            guard let self, let ask = self.state.ask, let option = VoiceApproval.option(for: text, among: ask.options) else { return }
            self.state.answer(option)
        }
        // 결재 기록: 버튼이든 말이든 사람이 답하면 대화에 한 줄 남는다("승인 · 62,000원 결제").
        answeredObserver = NotificationCenter.default.addObserver(forName: AppState.answered, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let line = n.userInfo?["line"] as? String { self?.conversation?.note(line) } }
        }
        // 정례 결산: 매일 21:00 오늘 지출을 톡으로 남긴다. 사람 차례가 아니므로 재촉도 전화도 없다.
        reportTimer = Timer(fire: DailyReport.nextFire(after: Date()), interval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let report = self.state.dailyReport() else { return }
                self.conversation?.notice("오늘 결산\n" + report, nudge: false)
            }
        }
        RunLoop.main.add(reportTimer!, forMode: .common)
        // 사람 차례는 비서처럼 밟는다(docs/ui-tree.md): 먼저 톡(말풍선 + 조용한 알림), 1분 뒤 재촉, 3분째 답이 없으면 전화.
        askSub = state.$ask.receive(on: DispatchQueue.main).sink { [weak self] ask in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let ask {
                    guard ask.id != self.rungAsk else { return }
                    self.rungAsk = ask.id
                    self.askSteps.forEach { $0.cancel() }
                    self.conversation?.notice(ask.text, nudge: false)
                    let nudge = DispatchWorkItem { [weak self] in self?.conversation?.notice(ask.text, nudge: true) }
                    let call = DispatchWorkItem { [weak self] in self?.conversation?.ring(ask.text) }
                    self.askSteps = [nudge, call]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: nudge)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: call)
                } else if self.rungAsk != nil {
                    self.rungAsk = nil
                    self.askSteps.forEach { $0.cancel() }; self.askSteps = []
                    self.conversation?.ring("")     // resolved: the page drops the banner and the notifications
                }
            }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.up { self.updateImmersive() } else { self.dock() }
            }
        }
        RunLoop.main.add(t, forMode: .common); tick = t
        keyMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Esc in another app belongs to that app. Focused records use the local monitor.
                    if self.state.recordsFocused { return }
                    if self.up {
                        if Self.isFullscreenChord(e) { if !e.isARepeat { self.state.toggleKiosk() } }
                        else { self.immersive?.handleKey(e) }
                        return
                    }
                    guard self.main?.isVisible == true, NSApp.isActive || self.surface.isFrontmost,
                          Self.isFullscreenChord(e) else { return }
                    if !e.isARepeat { self.state.toggleKiosk() }
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                if self.state.recordsFocused, e.keyCode == 53,
                   e.window === self.main || self.immersive?.contains(e.window) == true {
                    if !e.isARepeat { self.state.toggleRecordsFocus() }
                    return nil
                }
                if self.up {
                    if Self.isFullscreenChord(e) {
                        if !e.isARepeat { DispatchQueue.main.async { self.state.toggleKiosk() } }
                        return nil
                    }
                    self.immersive?.handleKey(e)
                    return e.keyCode == 53 ? nil : e
                }
                guard let main = self.main, e.window === main,
                      Self.isFullscreenChord(e) else { return e }
                if !e.isARepeat { DispatchQueue.main.async { self.state.toggleKiosk() } }
                return nil
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHoleClickThrough() }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
                MainActor.assumeIsolated { self?.updateHoleClickThrough() }
                return e
            },
        ].compactMap { $0 }
        // Covers belong to one desktop/display. Leaving it must never strand an exit button elsewhere
        // or pull the person back to the phone's former Space.
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
                               (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.state.recordsFocused { self.leaveRecordsFocus() }
                    guard self.up, self.state.kioskOn else { return }
                    self.revealPhoneOnExit = false
                    self.state.toggleKiosk()
                }
            }
            displayObservers.append((center, token))
        }
        let screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.up, !self.state.recordsFocused, let p = self.main, let c = self.content else { return }
                Self.fitMain(p, content: c, phoneSize: self.surfaceSize)
                c.followedPhone = nil
                self.placementRequested = true
                self.surfaceFit = SurfaceFit()
            }
        }
        displayObservers.append((NotificationCenter.default, screenToken))
        let dialogToken = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                   object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.up, self.state.kioskOn, let window = note.object as? NSWindow,
                      window !== self.main, self.immersive?.contains(window) != true else { return }
                // A file picker or settings window must be reachable above the workbench.
                self.revealPhoneOnExit = false
                self.state.toggleKiosk()
                // runModal() uses a nested event loop; remove the covers before returning to it,
                // without depending on the asynchronously scheduled state subscriber.
                self.setExpanded(false)
            }
        }
        displayObservers.append((NotificationCenter.default, dialogToken))
        // ⌘Tab or a click activates Ppomi without a reopen: AppKit raises the workbench above a buried control window and
        // the next docking tick would tuck it back under. Bring the control window along instead.
        let activateToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            // Run after the activation transition settles; AX front-most requests made inside it are dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    // Only a live, buried control window is raised; a Stage Manager thumbnail belongs to another stage.
                    // Another Ppomi window (settings, a picker) that was activated keeps its key status.
                    guard let self, !self.up, !self.state.recordsFocused, !self.revealingOnActivate, NSApp.isActive,
                          let p = self.main, p.isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === p, Permissions.accessibility,
                          let phone = self.surface.liveWindow(), !self.isSurfacePresented(phone.id),
                          self.activateRevealFailedFor != phone.id else { return }
                    self.revealingOnActivate = true
                    let revealed = self.surface.revealWindow()
                    // A reveal that hands the stage to the control app without presenting it would repeat on every
                    // re-activation below (뽀미 ↔ 미러링 flapping); one failure per window until it is seen presented.
                    self.activateRevealFailedFor = revealed ? nil : phone.id
                    // Revealing can hand activation to the control app; take it back so typing stays in the chat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MainActor.assumeIsolated {
                            NSApp.activateFront()
                            p.makeKey(); p.orderFront(nil)
                            WindowDiagnostics.panel("activate.reveal", p, fields: ["revealed": revealed])
                            self.revealingOnActivate = false
                        }
                    }
                }
            }
        }
        displayObservers.append((NotificationCenter.default, activateToken))
        let terminateToken = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.leaveRecordsFocus()
            }
        }
        displayObservers.append((NotificationCenter.default, terminateToken))
        sync()
    }

    deinit {
        tick?.invalidate()
        keyMonitors.forEach(NSEvent.removeMonitor)
        displayObservers.forEach { $0.0.removeObserver($0.1) }
    }

    private func sync() {
        if lastFocusRequest != state.recordsFocusRequest {
            lastFocusRequest = state.recordsFocusRequest
            if state.recordsFocused { leaveRecordsFocus() } else { enterRecordsFocus() }
        }
        if state.recordsFocused, !focusRestoreFailed,
           state.ask != nil || focusSurface != state.workSurface ||
           focusLedgerPath != ScreenControlLease.path(for: AppSettings.dbPath) {
            leaveRecordsFocus()
        }
        if state.recordsFocused {
            // A chat request while reviewing records ends the review instead of firing later as a surprise activation.
            if lastChatOpen != state.chatOpen || lastWorkbenchShown != state.workbenchShown {
                lastChatOpen = state.chatOpen; lastWorkbenchShown = state.workbenchShown
                leaveRecordsFocus()
            }
            content?.phase = state.phase
            content?.band.sync()
            if state.shown != lastShown { lastShown = state.shown; showMain() }
            if state.kioskOn != up { setExpanded(state.kioskOn) }
            return
        }
        sidebar.needsLayout = true
        if lastChatOpen != state.chatOpen || lastWorkbenchShown != state.workbenchShown {
            lastChatOpen = state.chatOpen; lastWorkbenchShown = state.workbenchShown
            showMain(stage: false)
            if !up {
                // A live control window buried under other apps comes up with the chat; a Stage Manager thumbnail
                // (another stage) is left alone, the slot explains how to bring it over.
                if Permissions.accessibility, let phone = surface.liveWindow(), !isSurfacePresented(phone.id) {
                    _ = surface.revealWindow()
                }
                NSApp.activateFront(); main?.makeKey(); main?.orderFront(nil)
            }
        }
        let switched = displayedSurface != state.workSurface
        if switched { switchSurface() }
        content?.phase = state.phase
        content?.band.sync()
        if state.shown != lastShown || switched { lastShown = state.shown; showMain() }
        if state.kioskOn != up { setExpanded(state.kioskOn) }
    }

    /// The 기록 button is disabled during a question or agent work; the remaining refusals simply keep the conversation.
    private func enterRecordsFocus() {
        guard state.ask == nil, launchingSurfaces.isEmpty else { return }
        if case .agent = state.phase { return }
        do {
            guard let lease = try ScreenControlLease.beginFocus(ledgerPath: AppSettings.dbPath) else { return }
            var targets: [RecordsWindowParking.Target] = []
            if let pid = surface.processIdentifier, let window = surface.liveWindow() {
                targets.append(.init(pid: pid, id: window.id, frame: window.rect))
            }
            let parking = try RecordsWindowParking(targets: targets)
            do { try parking.park() }
            catch {
                // A control window that refuses to minimize (Stage Manager, iPhone Mirroring) is simply covered:
                // without a docked window the workbench is opaque, and it comes to the front for the review.
                if !parking.restore() { focusRestoreFailed = true }   // keep the lease while a window still needs restoring
                WindowDiagnostics.panel("focus.parkFailed", main ?? NSPanel(), fields: ["error": String(describing: error)])
            }
            focusLease = lease
            parkedWindows = parking
            focusLedgerPath = ScreenControlLease.path(for: AppSettings.dbPath)
            focusSurface = surface
            state.beginRecordsFocus()
            if focusRestoreFailed { state.recordsFocusMessage = "창 복원 안 됨" }
            content?.recordsFocused = true
            main?.phoneID = nil
            surfaceFit = nil
            placementRequested = false
            awaitingPresentedPhone = false
            if up { updateImmersive() }
            else {
                content?.layoutSubtreeIfNeeded()
                // The review needs the whole workbench in front: without a docked window it is opaque and covers
                // a control window that could not be minimized.
                NSApp.activateFront()
                main?.makeKeyAndOrderFront(nil)
            }
        } catch {
            WindowDiagnostics.panel("focus.enterFailed", main ?? NSPanel(), fields: ["error": String(describing: error)])
        }
    }

    private func leaveRecordsFocus() {
        guard state.recordsFocused else { return }
        guard parkedWindows?.restore() != false else {
            focusRestoreFailed = true
            state.recordsFocusMessage = "창 복원 안 됨"
            return
        }
        parkedWindows = nil
        state.endRecordsFocus()
        state.recordsFocusMessage = nil
        content?.recordsFocused = false
        content?.layoutSubtreeIfNeeded()
        surfaceFit = nil
        placementRequested = false
        lastDock = nil
        focusLease?.release()
        focusLease = nil
        focusLedgerPath = nil
        focusSurface = nil
        focusRestoreFailed = false
        if up { updateImmersive() }
    }

    private func checkFocusedWindows() {
        if state.recordsFocused, !focusRestoreFailed, parkedWindows?.wasRevealedExternally == true {
            leaveRecordsFocus()
        }
    }

    /// Target changes are explicit user actions. Polling and ordinary workbench clicks never enter here.
    private func switchSurface() {
        if up { revealPhoneOnExit = false; setExpanded(false) }
        displayedSurface = state.workSurface
        surfaceFit = SurfaceFit()
        placedDesktopID = nil
        lastDock = nil
        mirrorPresence = MirrorPresence()
        awaitingPresentedPhone = false
        placementRequested = true
        guard let p = main, let c = content else { return }
        p.phoneID = nil
        c.surface = surface
        c.followedPhone = nil
        launchSurfaceIfNeeded()
        if let size = surface.axFrame()?.size {
            state.setSize(size, for: surface)
        }
        Self.fitMain(p, content: c, phoneSize: surfaceSize)
    }

    /// Explicit selection/reopen starts a missing mirror once and reports setup failures in its own pane.
    private func launchSurfaceIfNeeded() {
        let target = surface
        guard !state.recordsFocused, target.needsLaunch, launchingSurfaces.insert(target).inserted else { return }
        if target == .android {
            state.androidLaunchError = nil
            state.androidLaunching = true
        }
        Task { [weak self] in
            do {
                guard let lease = try ScreenControlLease.beginControl(ledgerPath: AppSettings.dbPath) else {
                    throw NSError(domain: "Ppomi.RecordsFocus", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: ScreenControlLease.blockedMessage])
                }
                defer { lease.release() }
                try await target.launch()
                guard let self else { return }
                self.launchingSurfaces.remove(target)
                if target == .android { self.state.androidLaunching = false }
                if self.surface == target, !self.state.recordsFocused {
                    // The mirror can replace the emulator fallback while preparation runs.
                    self.surfaceFit = SurfaceFit()
                    self.placementRequested = true
                    self.content?.followedPhone = nil
                    if Permissions.accessibility { self.awaitingPresentedPhone = !target.revealWindow() }
                }
            } catch {
                guard let self else { return }
                self.launchingSurfaces.remove(target)
                if target == .android {
                    self.state.androidLaunching = false
                    self.state.androidLaunchError = error.localizedDescription
                }
                if self.surface == target, !self.state.recordsFocused {
                    self.awaitingPresentedPhone = false
                    self.content?.phoneSlot.hint = self.state.connectionHint(for: target)
                }
            }
        }
    }

    private func makeMain() -> MainPanel {
        let c = WorkbenchContent(frame: CGRect(origin: .zero,
                                size: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)))
        c.surface = surface
        c.recordsFocused = state.recordsFocused
        c.phoneSize = surfaceSize
        c.phase = state.phase; c.band.state = state; c.band.sync()
        c.mount(sidebar: sidebar, records: records, controlToolbar: controlToolbar)
        // An ordinary window: it has its own Stage Manager stage, leaves with its app, and activates on click.
        let p = MainPanel(contentRect: c.frame,
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.title = "뽀미"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = false
        p.isMovable = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isFloatingPanel = false
        p.level = .normal
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenNone]
        p.contentView = c
        p.bindKioskButton { [weak self] in self?.state.toggleKiosk() }
        p.center()
        // The person's last size and position come back; only a first launch fits the display.
        restoredFrame = p.setFrameUsingName(Self.frameAutosaveName)
        p.setFrameAutosaveName(Self.frameAutosaveName)
        p.surfacePID = surface.processIdentifier
        p.startWindowDiagnostics()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leaveRecordsFocus()
                self?.wantMain = false
                // The conversation lives in this window: closing it ends the session and the microphone with it.
                self?.conversation?.close()
            }
        }
        content = c
        return p
    }

    private func showMain(stage: Bool = true) {
        let first = main == nil
        if first { main = makeMain() }
        wantMain = true
        guard let p = main, let c = content else { return }
        if state.recordsFocused {
            p.phoneID = nil
            NSApp.unhideWithoutActivation()
            if up { updateImmersive() }
            else {
                if p.isMiniaturized { p.deminiaturize(nil) }
                c.layoutSubtreeIfNeeded()
                p.makeKeyAndOrderFront(nil)
            }
            return
        }
        if up {
            if stage {
                surfaceFit = SurfaceFit()
                placementRequested = true
                NSApp.unhideWithoutActivation()
                if Permissions.accessibility { _ = surface.revealWindow() }
                NSApp.activateFront()
            }
            updateImmersive()
            return
        }
        if first || stage {
            surfaceFit = SurfaceFit()
            Self.fitMain(p, content: c, phoneSize: surfaceSize, initial: first && !restoredFrame)
            c.followedPhone = nil
            placementRequested = true
        }
        // A live window can still be buried behind another app. Explicit reopen raises the pair first;
        // ordinary clicks and the docking timer never enter this path.
        if stage {
            WindowDiagnostics.panel("reveal.request", p)
            NSApp.unhideWithoutActivation()
            if p.isMiniaturized { p.deminiaturize(nil) }
            launchSurfaceIfNeeded()
            // A window parked on another stage cannot be revealed: activating its app would hand the stage over.
            // The docking tick's thumbnail pull brings it here instead.
            let parked = surface.liveWindow() == nil && surfaceThumbnail != nil
            let presented = Permissions.accessibility && !parked && surface.revealWindow()
            p.surfacePID = surface.processIdentifier
            awaitingPresentedPhone = !presented
            if !presented { lastDock = nil }
            p.phoneID = presented ? surface.liveWindow()?.id : nil
            WindowDiagnostics.panel("reveal.presented", p, fields: ["phonePresented": presented])
        } else {
            // Without accessibility nothing can raise a buried control window, so the panel must not tuck itself under it.
            p.phoneID = Permissions.accessibility ? surface.liveWindow()?.id : nil
        }
        c.layoutSubtreeIfNeeded()
        p.orderFront(nil)
        // 사람이 뽀미를 불렀다(실행·Dock·메뉴): 미러링 창을 앞세우느라 넘어간 활성을 되찾아 메뉴 막대와 타자가 뽀미에 남게 한다.
        if stage { NSApp.activateFront(); p.makeKey() }
    }

    /// Move the same view objects between hosts, preserving the timeline page and pending human approval.
    private func setExpanded(_ expanded: Bool) {
        placedDesktopID = nil
        if main == nil { showMain(stage: false) }
        guard let p = main, let c = content else { return }
        if expanded {
            guard let screen = p.screen ?? NSScreen.main else { return }
            savedFrame = p.frame
            p.orderOut(nil)
            up = true
            if immersive == nil {
                immersive = ImmersiveKiosk(workbench: sidebar, records: records, controlToolbar: controlToolbar, controlPlaceholder: c.phoneSlot, band: c.band) { [weak self] in
                    guard let self, self.state.kioskOn else { return }
                    self.state.toggleKiosk()
                }
            }
            if !state.recordsFocused {
                if Permissions.accessibility { _ = surface.revealWindow() }
                surfaceFit = SurfaceFit()
                placementRequested = true
            }
            immersive?.show(on: screen, phone: immersivePhoneFrame(), controlWidth: surfaceSize.width,
                            recordsFocused: state.recordsFocused)
            WindowDiagnostics.panel("immersive.enter", p)
        } else {
            immersive?.hide()
            up = false
            c.reclaimContent()
            c.followedPhone = nil
            p.contentMinSize = .zero
            p.contentMaxSize = CGSize(width: 10000, height: 10000)
            if let savedFrame { p.setFrame(savedFrame, display: true) }
            Self.fitMain(p, content: c, phoneSize: surfaceSize)
            savedFrame = nil
            lastDock = nil
            placementRequested = false
            let stage = revealPhoneOnExit
            revealPhoneOnExit = true
            showMain(stage: stage)
            WindowDiagnostics.panel("immersive.exit", p)
        }
        p.standardWindowButton(.zoomButton)?.setAccessibilityLabel(expanded ? "키오스크 끄기" : "키오스크")
    }

    /// The opening is only for a visible phone, never a different app that has covered it.
    private func immersivePhoneFrame() -> CGRect? {
        guard !state.recordsFocused, Permissions.accessibility, let phone = surface.liveWindow(),
              isSurfacePresented(phone.id),
              let frame = surface.axFrame(), DockChange.near(frame, phone.rect) else { return nil }
        return cgRect(frame)
    }

    private func updateImmersive() {
        checkFocusedWindows()
        guard up, !NSApp.isHidden, let screen = immersive?.screenFrame, let c = content else { return }
        if state.recordsFocused {
            immersive?.update(phone: nil, controlWidth: surfaceSize.width, recordsFocused: true)
            return
        }
        // The control column follows the surface width, which the compact-size request may change.
        let currentControlArea = { () -> CGRect in
            ImmersiveKiosk.layout(screen: screen, phone: nil, controlWidth: self.surfaceSize.width,
                                  footerHeight: self.immersiveFooterHeight(screen: screen, content: c)).controlArea
        }
        let fitReady = finishSurfaceFit(available: currentControlArea())
        let controlArea = currentControlArea()
        if fitReady, placementRequested, let frame = surface.axFrame() {
            if frame.width <= controlArea.width, frame.height <= controlArea.height {
                surface.place(cgRect(WorkbenchLayout.topAlignedWindow(size: frame.size, in: controlArea)).origin)
                placementRequested = false
            } else {
                c.phoneSlot.hint = "제어 자리보다 큰 창"
            }
        }
        let actualPhone = immersivePhoneFrame()
        let phone = actualPhone.flatMap { controlArea.contains($0) ? $0 : nil }
        if actualPhone != nil, phone == nil, !placementRequested {
            releaseOutOfAreaControl(content: c)
        } else if phone != nil {
            c.phoneSlot.hint = ""
        }
        immersive?.update(phone: phone, controlWidth: surfaceSize.width)
    }

    private func immersiveFooterHeight(screen: CGRect, content c: WorkbenchContent) -> CGFloat {
        let column = WorkbenchLayout.dashboard(in: screen, controlWidth: surfaceSize.width, topInset: 0).controlColumn
        return c.band.preferredHeight(for: max(0, column.width - WorkbenchLayout.horizontalInset * 2))
    }

    /// Clicks over the hole belong to the native window showing through it, even while this window is above it.
    /// Re-evaluated on every pointer move (global + local monitors) so a fast move-and-click never falls through.
    private func updateHoleClickThrough() {
        guard let p = main, let c = content else { return }
        let pointer = p.convertPoint(fromScreen: NSEvent.mouseLocation)
        let overHole = !up && c.dockedPhone && c.phoneSlot.frame.contains(c.convert(pointer, from: nil))
        if p.ignoresMouseEvents != overHole { p.ignoresMouseEvents = overHole }
    }

    /// Stage Manager shows windows of other stages as small strip thumbnails: on screen, but not a live window.
    /// WindowServer coordinates (origin top-left).
    private var surfaceThumbnail: CGRect? {
        let pids = Set(surface.processIdentifiers)
        guard !pids.isEmpty else { return nil }
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in l {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(owner), (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let h = b["Height"], h > 40, h <= 200, let x = b["X"], let y = b["Y"], let width = b["Width"] else { continue }
            return CGRect(x: x, y: y, width: width, height: h)
        }
        return nil
    }

    /// Stage Manager has no API for grouping another app's window with ours, but the person's gesture can be made for
    /// them: drag the strip thumbnail into the control slot. Once per thumbnail episode (or per explicit placement), only while
    /// this app is in front and the pointer is idle, and the cursor goes back where it was.
    private func pullThumbnail(_ thumbnail: CGRect, panel p: MainPanel, content c: WorkbenchContent) {
        let pointer = NSEvent.mouseLocation
        let pointerIdle = abs(pointer.x - lastPointer.x) < 2 && abs(pointer.y - lastPointer.y) < 2
        lastPointer = pointer
        guard !stagePullInFlight, !stagePullAttempted || placementRequested, NSApp.isActive, p.isFrontmostOnScreen,
              Permissions.accessibility, pointerIdle, NSEvent.pressedMouseButtons == 0 else { return }
        stagePullInFlight = true
        stagePullAttempted = true
        placementRequested = false
        let target = phoneTarget(p, c)
        // Stage Manager puts the dropped window's top-left corner 100 pt up and left of the pointer, whatever part of
        // the thumbnail was grabbed (measured 2026-09-10 with iPhone Mirroring and Parallels; a drop at the slot's centre
        // therefore landed the window down and right of it). Grab the thumbnail's middle, where its image certainly is,
        // and release 100 pt inside the slot's corner; the alignment below only corrects what the app itself shifts.
        let carry = CGPoint(x: 100, y: 100)
        WindowDiagnostics.panel("dock.stagePull", p, fields: [
            "thumbnail": [thumbnail.minX, thumbnail.minY, thumbnail.width, thumbnail.height], "target": [target.minX, target.minY]])
        StageDrag.perform(from: CGPoint(x: thumbnail.midX, y: thumbnail.midY),
                          to: CGPoint(x: target.minX + carry.x, y: target.minY + carry.y)) { [weak self] in
            // Stage Manager animates the drop for about a second; only then does one explicit alignment put the
            // window exactly on the slot instead of the slot following wherever the drop landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let landed = self.surface.axFrame() {
                        WindowDiagnostics.log("dock.stagePull.landed", [
                            "frame": [landed.minX, landed.minY, landed.width, landed.height], "target": [target.minX, target.minY]])
                    }
                    self.stagePullInFlight = false
                    self.lastDock = nil
                    self.placementRequested = true
                    NSApp.activateFront(); p.makeKey()   // 썸네일을 끌어 놓는 합성 드래그가 미러링 앱을 활성화한다: 사람은 뽀미에 있다
                }
            }
        }
    }

    /// The control window is presented when nothing but this app's own windows sits above it.
    private func isSurfacePresented(_ id: CGWindowID) -> Bool {
        guard let pid = surface.processIdentifier else { return surface.isInFrontOfOtherApplications(id) }
        let windows = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { w -> MirroringOrder.Window? in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = w[kCGWindowLayer as String] as? Int else { return nil }
            return .init(id: id, owner: owner, layer: layer)
        }
        return MirroringOrder.isInFront(phoneID: id, phonePID: pid, ppomiPID: ProcessInfo.processInfo.processIdentifier, windows: windows)
    }

    /// The workbench is resizable and movable. `initial` fits it to the display once; every other call only keeps the
    /// person's frame at least the minimum size and on the display.
    /// Stage Manager keeps its strip of other apps' thumbnails along the left edge; a workbench that grows over it hides
    /// the very thumbnail the person (or the stage pull) needs to drag in. Treat that band as off-limits.
    /// A transient mark over the docked window: the assistant's tap, the field it filled, reading in progress.
    func showMark(_ mark: OverlayMark) { content?.show(mark) }

    static let stageStripWidth: CGFloat = 200
    static var stageManagerActive: Bool { UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false }
    nonisolated static func usable(_ display: CGRect, stageManager: Bool) -> CGRect {
        guard stageManager else { return display }
        return CGRect(x: display.minX + stageStripWidth, y: display.minY, width: max(0, display.width - stageStripWidth), height: display.height)
    }

    static func fitMain(_ p: NSPanel, content c: WorkbenchContent, phoneSize: CGSize, in visible: CGRect? = nil, initial: Bool = false) {
        c.phoneSize = phoneSize
        guard let full = visible ?? (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        let display = usable(full, stageManager: visible == nil && stageManagerActive)
        var minimum = WorkbenchLayout.minimumContentSize
        minimum.width = max(minimum.width, phoneSize.width + WorkbenchLayout.horizontalInset * 2 + WorkbenchLayout.minimumConversationWidth)
        let displayContent = p.contentRect(forFrameRect: display).size
        p.contentMinSize = CGSize(width: min(minimum.width, displayContent.width), height: min(minimum.height, displayContent.height))
        p.contentMaxSize = CGSize(width: 10000, height: 10000)
        let minimumFrame = p.frameRect(forContentRect: CGRect(origin: .zero, size: p.contentMinSize)).size
        let target = initial ? display : Self.fitted(p.frame, in: display, minimum: minimumFrame)
        if !DockChange.near(p.frame, target) { p.setFrame(target, display: true) }
        c.layoutSubtreeIfNeeded()
    }

    /// Pure: at least `minimum`, no larger than the display, moved (not shrunk) to stay on it.
    nonisolated static func fitted(_ frame: CGRect, in display: CGRect, minimum: CGSize) -> CGRect {
        let size = CGSize(width: min(max(frame.width, minimum.width), display.width),
                          height: min(max(frame.height, minimum.height), display.height))
        var origin = frame.origin
        if origin.x + size.width > display.maxX { origin.x = display.maxX - size.width }
        if origin.y + size.height > display.maxY { origin.y = display.maxY - size.height }
        if origin.x < display.minX { origin.x = display.minX }
        if origin.y < display.minY { origin.y = display.minY }
        return CGRect(origin: origin, size: size)
    }

    /// A user action permits one compact-size request. Later ticks only wait and read the settled native frame.
    private func finishSurfaceFit(available: CGRect) -> Bool {
        guard var pending = surfaceFit else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if !pending.requested {
            // Windows may take everything the display can give beside a full-width conversation (the workbench grows to
            // match), instead of the slot the previous, smaller surface left behind.
            var room = available.size
            if surface == .windows, let full = (main?.screen ?? NSScreen.main)?.visibleFrame {
                let usable = Self.usable(full, stageManager: Self.stageManagerActive)
                room.width = max(room.width, usable.width - WorkbenchLayout.horizontalInset * 2 - WorkbenchLayout.minimumConversationWidth)
                room.height = max(room.height, usable.height - WorkbenchLayout.normalTop - WorkbenchLayout.toolbarHeight - WorkbenchLayout.contentGap * 2 - 60)
            }
            let accepted = surface.requestCompactSize(available: room)
            if let panel = main {
                WindowDiagnostics.panel("dock.surfaceFit.requested", panel, fields: [
                    "surface": surface.rawValue, "availableSize": [available.width, available.height],
                    "accepted": accepted])
            }
            pending.requested = true
            pending.settleUntil = now + 0.35
            surfaceFit = pending
            return false
        }
        guard now >= pending.settleUntil, let frame = surface.axFrame() else { return false }
        surfaceFit = nil
        if let panel = main {
            WindowDiagnostics.panel("dock.surfaceFit.settled", panel, fields: [
                "surface": surface.rawValue, "actual": [frame.minX, frame.minY, frame.width, frame.height],
                "availableSize": [available.width, available.height]])
        }
        state.setSize(frame.size, for: surface)
        content?.phoneSize = frame.size
        content?.followedPhone = nil
        // The workbench grows around the measured window (Windows keeps its own size); without this the conversation
        // column was squeezed to whatever was left beside a 1247-point guest window.
        if let panel = main, let content { Self.fitMain(panel, content: content, phoneSize: frame.size) }
        content?.layoutSubtreeIfNeeded()
        lastDock = nil
        placementRequested = true
        return true
    }

    private func cgRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func phoneTarget(_ p: NSPanel, _ c: WorkbenchContent) -> CGRect {
        cgRect(p.convertToScreen(c.phoneSlot.convert(c.phoneSlot.bounds, to: nil)))
    }

    private func followPhone(_ frame: CGRect, panel p: MainPanel, content c: WorkbenchContent) {
        // Follow a deliberate move only while the complete native window stays in its reserved area.
        let local = c.convert(p.convertFromScreen(cgRect(frame)), from: nil)
        guard c.controlAvailableArea.contains(local) else {
            releaseOutOfAreaControl(content: c)
            return
        }
        c.followedPhone = local
        c.layoutSubtreeIfNeeded()
    }

    private func releaseOutOfAreaControl(content: WorkbenchContent) {
        main?.phoneID = nil
        placedDesktopID = nil
        content.followedPhone = nil
        content.phoneSlot.hint = "제어 자리 밖"
        content.layoutSubtreeIfNeeded()
    }

    /// Maintain relative order without raising/activating the phone. Ignore transient Stage Manager animation frames.
    private func dock() {
        checkFocusedWindows()
        guard wantMain, let p = main, let c = content else { return }
        guard !NSApp.isHidden, !p.inLiveResize else { return }
        defer {
            c.dockedPhone = p.phoneID != nil
            updateHoleClickThrough()
        }
        if state.recordsFocused {
            p.phoneID = nil
            c.layoutSubtreeIfNeeded()
            return
        }
        guard Permissions.accessibility else {
            p.phoneID = nil; lastDock = nil; placedDesktopID = nil
            c.phoneSlot.hint = "손쉬운 사용 허용 필요"
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        let livePhone = surface.liveWindow()
        if surface == .android, state.androidWindowVisible != (livePhone != nil) {
            state.androidWindowVisible = livePhone != nil
        }
        if surface == .windows, state.windowsWindowVisible != (livePhone != nil) {
            state.windowsWindowVisible = livePhone != nil
        }
        if awaitingPresentedPhone {
            // A failed/unfinished reveal must leave the workbench accessible on its own, rather than
            // immediately tucking it under the same buried window on the next timer tick.
            guard let phone = livePhone, isSurfacePresented(phone.id) else {
                if livePhone == nil {
                    // A reveal cannot present a window parked on another stage; only the pull brings it over.
                    if let thumbnail = surfaceThumbnail {
                        c.phoneSlot.hint = "다른 스테이지에 있음"
                        pullThumbnail(thumbnail, panel: p, content: c)
                    } else {
                        c.phoneSlot.hint = state.connectionHint(for: surface)
                    }
                }
                if !p.isVisible { p.orderFront(nil) }
                return
            }
            awaitingPresentedPhone = false
        }
        let presence = mirrorPresence.observe(appRunning: surface.isRunning,
                                               hasLiveWindow: livePhone != nil,
                                               hasAssociation: p.phoneID != nil,
                                               now: ProcessInfo.processInfo.systemUptime)
        // Stage Manager can briefly report only a thumbnail while handling a click. Keep the pairing during that gap.
        if presence == .transient { return }
        guard let phone = livePhone else {
            WindowDiagnostics.panel("dock.noLiveWindow", p)
            p.phoneID = nil; lastDock = nil; placedDesktopID = nil
            if let thumbnail = surfaceThumbnail {
                c.phoneSlot.hint = "다른 스테이지에 있음"
                pullThumbnail(thumbnail, panel: p, content: c)
            } else {
                c.phoneSlot.hint = state.connectionHint(for: surface)
            }
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        stagePullAttempted = false
        if stagePullInFlight { return }   // the drop is still animating: measure and align after it lands
        guard let frame = surface.axFrame(), DockChange.near(frame, phone.rect) else { return }
        guard finishSurfaceFit(available: c.controlAvailableArea) else { return }
        if c.phoneSize != frame.size {
            c.phoneSize = frame.size
            state.setSize(frame.size, for: surface)
            c.layoutSubtreeIfNeeded()
        }
        guard c.controlAvailableArea.width >= frame.width, c.controlAvailableArea.height >= frame.height else {
            p.phoneID = nil
            c.followedPhone = nil
            c.phoneSlot.hint = "제어 자리보다 큰 창"
            c.layoutSubtreeIfNeeded()
            return
        }
        let current = DockSnapshot(phoneID: phone.id, panel: cgRect(p.frame), phone: frame)
        let change = DockChange.between(lastDock, and: current, explicitLayout: placementRequested)
        let local = c.convert(p.convertFromScreen(cgRect(frame)), from: nil)
        if change != .alignPhone, !c.controlAvailableArea.contains(local) {
            releaseOutOfAreaControl(content: c)
            lastDock = current
            return
        }
        p.phoneID = phone.id
        p.surfacePID = surface.processIdentifier
        if activateRevealFailedFor != nil, isSurfacePresented(phone.id) { activateRevealFailedFor = nil }
        if !p.isVisible { p.orderFront(nil) }
        else if p.isAbove(phone.id), !isSurfacePresented(phone.id) {
            // Another app's window sits between this one and the control window, so the hole shows that app instead of
            // the phone: raise the control window and keep this app active. Never reorder this window under anything.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRaiseReveal > 2 {
                lastRaiseReveal = now
                WindowDiagnostics.panel("dock.raiseReveal", p)
                _ = surface.revealWindow()
                NSApp.activateFront()
                p.makeKey()
            }
        }
        c.phoneSlot.hint = ""
        if change != .alignPhone { placedDesktopID = nil }
        let resized = abs(frame.width - surfaceSize.width) > 1 || abs(frame.height - surfaceSize.height) > 1
        if resized {
            state.setSize(frame.size, for: surface)
            c.phoneSize = frame.size
            if !up { Self.fitMain(p, content: c, phoneSize: frame.size) }
        }
        if change == .alignPhone {
            c.followedPhone = nil
            c.layoutSubtreeIfNeeded()
            let target = phoneTarget(p, c)
            WindowDiagnostics.panel("dock.alignPhone", p, fields: ["explicitLayout": placementRequested,
                "frame": [frame.minX, frame.minY, frame.width, frame.height], "target": [target.minX, target.minY]])
            let alreadyPlaced = placedDesktopID == phone.id
            placedDesktopID = nil
            if !alreadyPlaced && (abs(frame.minX - target.minX) > 1 || abs(frame.minY - target.minY) > 1) {
                surface.place(target.origin)
                if surface != .iphone {
                    placedDesktopID = phone.id
                    return
                }
            }
        } else if change == .followPhone || resized {
            c.layoutSubtreeIfNeeded()
            followPhone(frame, panel: p, content: c)
        }
        placementRequested = false
        // Record the actual result (including any OS position constraint), never repeatedly force an unattainable point.
        let actual = change == .alignPhone ? (surface.axFrame() ?? frame) : frame
        if change == .alignPhone, !DockChange.near(actual, phoneTarget(p, c)) { followPhone(actual, panel: p, content: c) }
        lastDock = DockSnapshot(phoneID: phone.id, panel: cgRect(p.frame), phone: actual)
    }

    private static func isFullscreenChord(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 3 && mods.contains(.command) && mods.contains(.control)
            && !mods.contains(.shift) && !mods.contains(.option)
    }
}


/// Synthetic left-drag through the HID event tap (accessibility permission), on a background thread so the workbench
/// keeps drawing. The real cursor is borrowed for about a second and returned afterwards.
enum StageDrag {
    static func perform(from: CGPoint, to: CGPoint, done: @escaping @MainActor () -> Void) {
        let original = CGEvent(source: nil)?.location
        DispatchQueue.global(qos: .userInitiated).async {
            func post(_ type: CGEventType, _ point: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, from); usleep(150_000)
            post(.leftMouseDown, from); usleep(400_000)
            let steps = 40
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                usleep(25_000)
            }
            usleep(300_000)
            post(.leftMouseUp, to)
            usleep(200_000)
            if let original { CGWarpMouseCursorPosition(original) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}
