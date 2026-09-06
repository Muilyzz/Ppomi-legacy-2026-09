// The workbench stays directly behind the selected iPhone or Parallels window. Immersive mode lends
// its existing views to covers around that window without repeatedly activating it.
import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// Navigation leaves the mirroring app active; every explicit raise stays directly behind its window.
final class MainPanel: NSPanel {
    var agentWindowID: CGWindowID?
    var hasDockedWindow: Bool { phoneID != nil || agentWindowID != nil }
    private var lowestDockedWindow: CGWindowID? {
        let ids = Set([phoneID, agentWindowID].compactMap { $0 })
        guard !ids.isEmpty else { return nil }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.last(where: ids.contains)
    }
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

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        WindowDiagnostics.panel("order.before", self, fields: ["mode": place.rawValue,
            "relativeTo": phoneID.map { Int($0) == otherWin } == true ? "phone" : otherWin == 0 ? "default" : "other"])
        if place == .above, let p = lowestDockedWindow { super.order(.below, relativeTo: Int(p)) }
        else { super.order(place, relativeTo: otherWin) }
        WindowDiagnostics.panel("order.after", self)
    }
    override func orderFront(_ sender: Any?) {
        WindowDiagnostics.panel("orderFront", self)
        if let p = lowestDockedWindow { order(.below, relativeTo: Int(p)) } else { super.orderFront(sender) }
    }
    override func orderFrontRegardless() {
        WindowDiagnostics.panel("orderFrontRegardless", self)
        if let p = lowestDockedWindow { order(.below, relativeTo: Int(p)) } else { super.orderFrontRegardless() }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) { makeKey(); orderFront(sender) }
    /// True when this panel is not directly under the phone: drawn above it, or another app's window slid in between
    /// (Stage Manager re-layers on a stage switch). CGWindowList is front-to-back.
    func needsReorder(under phone: CGWindowID) -> Bool {
        let anchor = lowestDockedWindow ?? phone
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var belowPhone = false
        for w in l {
            let id = w["kCGWindowNumber"] as? Int ?? 0
            if id == windowNumber { return !belowPhone }                       // reached us: fine only if the phone came first
            if id == Int(anchor) { belowPhone = true; continue }
            if belowPhone, (w["kCGWindowLayer"] as? Int) == 0, (w["kCGWindowOwnerPID"] as? pid_t) != me { return true }   // someone in between
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
    private let workbench: NSView
    private let sidebar: AgentSidebar
    private let agentDock: AgentDockCoordinator
    private var sub: AnyCancellable?
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
    private var explicitRevealUntil: TimeInterval = 0
    private var placementRequested = false
    private var displayedSurface: WorkSurface = .iphone
    private struct DesktopFit {
        var requestedWindow: CGWindowID?
        var originalSize: CGSize?
        var deadline: TimeInterval = 0
    }
    private var desktopFit: DesktopFit?
    private var placedDesktopID: CGWindowID?
    private(set) var up = false

    private var surface: WorkSurface { displayedSurface }
    private var surfaceSize: CGSize { surface == .iphone ? state.phoneSize : state.windowsSize }

    init(state: AppState) {
        self.state = state
        let rootView = Workbench().environmentObject(state)
        workbench = WindowDiagnostics.enabled ? DiagnosticHostingView(rootView: rootView) : WorkbenchHostingView(rootView: rootView)
        workbench.autoresizingMask = [.width, .height]
        sidebar = AgentSidebar(records: workbench, state: state)
        agentDock = AgentDockCoordinator(state: state)
        sub = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
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
                    if self.up {
                        if Self.isFullscreenChord(e) { if !e.isARepeat { self.state.toggleKiosk() } }
                        else { self.immersive?.handleKey(e) }
                        return
                    }
                    guard self.main?.isVisible == true,
                          self.surface.isFrontmost,
                          Self.isFullscreenChord(e) else { return }
                    if !e.isARepeat { self.state.toggleKiosk() }
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
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
        ].compactMap { $0 }
        // Covers belong to one desktop/display. Leaving it must never strand an exit button elsewhere
        // or pull the person back to the phone's former Space.
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
                               (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.up, self.state.kioskOn else { return }
                    self.revealPhoneOnExit = false
                    self.state.toggleKiosk()
                }
            }
            displayObservers.append((center, token))
        }
        let screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.up, let p = self.main, let c = self.content else { return }
                Self.fitMain(p, content: c, phoneSize: self.surfaceSize)
                c.followedPhone = nil
                self.placementRequested = true
                self.agentDock.requestLayout(reveal: false)
                if self.surface == .windows { self.desktopFit = DesktopFit() }
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
        let terminateToken = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.agentDock.restore() }
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
        agentDock.syncSelection()
        if !state.agentVisible { main?.agentWindowID = nil }
        let switched = displayedSurface != state.workSurface
        if switched { switchSurface() }
        content?.phase = state.phase
        content?.band.sync()
        if state.shown != lastShown || switched { lastShown = state.shown; showMain() }
        if state.kioskOn != up { setExpanded(state.kioskOn) }
    }

    /// Target changes are explicit user actions. Polling and ordinary workbench clicks never enter here.
    private func switchSurface() {
        if up { revealPhoneOnExit = false; setExpanded(false) }
        displayedSurface = state.workSurface
        desktopFit = displayedSurface == .windows ? DesktopFit() : nil
        placedDesktopID = nil
        lastDock = nil
        mirrorPresence = MirrorPresence()
        awaitingPresentedPhone = false
        placementRequested = true
        guard let p = main, let c = content else { return }
        p.phoneID = nil
        c.surface = surface
        c.followedPhone = nil
        if !surface.isRunning { surface.launch() }
        if let size = surface.axFrame()?.size {
            if surface == .iphone { state.phoneSize = size } else { state.windowsSize = size }
        }
        Self.fitMain(p, content: c, phoneSize: surfaceSize)
    }

    private func makeMain() -> MainPanel {
        let c = WorkbenchContent(frame: CGRect(origin: .zero,
                                size: WorkbenchContent.size(bandWidth: surface == .iphone ? 620 : 380,
                                                            phone: surfaceSize, surface: surface)))
        c.surface = surface
        c.phoneSize = surfaceSize
        c.phase = state.phase; c.band.state = state; c.band.sync()
        c.workbench = sidebar
        c.workbenchArea.addSubview(sidebar)
        c.onExitExpanded = { [weak self] in self?.state.toggleKiosk() }
        let p = MainPanel(contentRect: c.frame,
                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.title = "뽀미"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = false
        p.isMovable = false
        p.backgroundColor = .black
        p.isFloatingPanel = false
        p.level = .normal
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllApplications, .fullScreenNone]
        p.contentView = c
        p.bindKioskButton { [weak self] in self?.state.toggleKiosk() }
        p.center()
        p.surfacePID = surface.processIdentifier
        p.startWindowDiagnostics()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wantMain = false; self?.agentDock.restore() }
        }
        content = c
        return p
    }

    private func showMain(stage: Bool = true) {
        let first = main == nil
        if first { main = makeMain() }
        wantMain = true
        guard let p = main, let c = content else { return }
        if up {
            if stage {
                agentDock.requestLayout()
                NSApp.unhideWithoutActivation()
                if Permissions.accessibility { _ = surface.revealWindow() }
            }
            updateImmersive()
            return
        }
        if first || stage {
            agentDock.requestLayout()
            Self.fitMain(p, content: c, phoneSize: surfaceSize)
            c.followedPhone = nil
            placementRequested = true
        }
        // A live window can still be buried behind another app. Explicit reopen raises the pair first;
        // ordinary clicks and the docking timer never enter this path.
        if stage {
            WindowDiagnostics.panel("reveal.request", p)
            NSApp.unhideWithoutActivation()
            if p.isMiniaturized { p.deminiaturize(nil) }
            if !surface.isRunning { surface.launch() }
            let presented = Permissions.accessibility && surface.revealWindow()
            p.surfacePID = surface.processIdentifier
            awaitingPresentedPhone = !presented
            if !presented { lastDock = nil }
            explicitRevealUntil = ProcessInfo.processInfo.systemUptime + 2
            p.phoneID = presented ? surface.liveWindow()?.id : nil
            WindowDiagnostics.panel("reveal.presented", p, fields: ["phonePresented": presented])
        } else {
            p.phoneID = surface.liveWindow()?.id
        }
        c.layoutSubtreeIfNeeded()
        p.orderFront(nil)
    }

    /// Move the same view objects between hosts, preserving the timeline page and pending human approval.
    private func setExpanded(_ expanded: Bool) {
        placedDesktopID = nil
        if main == nil { showMain(stage: false) }
        guard let p = main, let c = content else { return }
        if expanded {
            guard let screen = p.screen ?? NSScreen.main else { return }
            savedFrame = p.frame
            c.layoutSuspended = true
            p.orderOut(nil)
            up = true
            if immersive == nil {
                immersive = ImmersiveKiosk(workbench: sidebar, band: c.band) { [weak self] in
                    guard let self, self.state.kioskOn else { return }
                    self.state.toggleKiosk()
                }
            }
            if Permissions.accessibility { _ = surface.revealWindow() }
            agentDock.requestLayout()
            immersive?.show(on: screen, phone: immersivePhoneFrame())
            WindowDiagnostics.panel("immersive.enter", p)
        } else {
            immersive?.hide()
            up = false
            sidebar.reclaimToolbar()
            c.workbenchArea.addSubview(sidebar)
            c.addSubview(c.band)
            c.layoutSuspended = false
            c.expanded = false
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
        guard Permissions.accessibility, let phone = surface.liveWindow(),
              isSurfacePresented(phone.id),
              let frame = surface.axFrame(), DockChange.near(frame, phone.rect) else { return nil }
        return cgRect(frame)
    }

    private func updateImmersive() {
        guard up, !NSApp.isHidden else { return }
        let phone = immersivePhoneFrame()
        guard let screen = immersive?.screenFrame, let c = content else { return }
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        let footer = c.band.preferredHeight(for: max(0, layout.sidebar.width - 24))
        let area = ImmersiveKiosk.agentAvailableArea(in: layout.sidebar, bandHeight: footer)
        let agent = agentDock.update(available: cgRect(area), allowing: pairedPIDs)
        let presented = agent.flatMap { state.agentApp.isInFront($0.id, allowing: pairedPIDs) ? cgRect($0.rect) : nil }
        immersive?.update(phone: phone, agent: presented)
    }

    private var pairedPIDs: Set<pid_t> {
        Set([ProcessInfo.processInfo.processIdentifier, surface.processIdentifier].compactMap { $0 })
    }
    private func isSurfacePresented(_ id: CGWindowID) -> Bool {
        guard state.agentVisible, let pid = surface.processIdentifier else { return surface.isInFrontOfOtherApplications(id) }
        let windows = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { w -> MirroringOrder.Window? in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = w[kCGWindowLayer as String] as? Int else { return nil }
            return .init(id: id, owner: owner, layer: layer)
        }
        var allowed = pairedPIDs
        if let agent = state.agentApp.processIdentifier { allowed.insert(agent) }
        return AgentWindowPolicy.isInFront(id: id, pid: pid, allowedPIDs: allowed, windows: windows)
    }

    private func updateAgentDock(panel p: MainPanel) {
        sidebar.layoutSubtreeIfNeeded()
        let available = cgRect(p.convertToScreen(sidebar.convert(sidebar.agentArea, to: nil)))
        let agent = agentDock.update(available: available, allowing: pairedPIDs)
        p.agentWindowID = agent?.id
        if let anchor = agent?.id ?? p.phoneID, p.needsReorder(under: anchor) { p.orderFront(nil) }
    }

    static func fitExpanded(_ p: NSPanel, content c: WorkbenchContent, in frame: CGRect) {
        c.expanded = true
        c.followedPhone = nil
        p.contentMinSize = .zero
        p.contentMaxSize = CGSize(width: 10000, height: 10000)
        p.setFrame(frame, display: true)
        c.layoutSubtreeIfNeeded()
    }

    static func fitMain(_ p: NSPanel, content c: WorkbenchContent, phoneSize: CGSize, in visible: CGRect? = nil) {
        c.fullWindow = true
        c.phoneSize = phoneSize
        guard let frame = visible ?? (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        p.contentMinSize = .zero
        p.contentMaxSize = CGSize(width: 10000, height: 10000)
        if !DockChange.near(p.frame, frame) { p.setFrame(frame, display: true) }
        let size = p.contentRect(forFrameRect: frame).size
        p.contentMinSize = size
        p.contentMaxSize = size
        c.layoutSubtreeIfNeeded()
    }

    /// Keep the sidebar and its bottom approvals on screen even when the native target is oversized.
    static func centeredOrigin(for size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: max(visible.minX, visible.midX - size.width / 2),
                y: max(visible.minY, visible.midY - size.height / 2))
    }

    static func clampedOrigin(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
                y: max(visible.minY, min(origin.y, visible.maxY - size.height)))
    }

    static func fittedDesktopSize(_ current: CGSize, available: CGSize, frameOverhead: CGSize = .zero) -> CGSize {
        let margins = WorkbenchContent.size(bandWidth: WorkbenchContent.minimumBandWidth(for: .windows),
                                             phone: .zero, surface: .windows)
        let width = available.width - margins.width - frameOverhead.width - 48
        let height = available.height - margins.height - frameOverhead.height - 48
        guard current.width.isFinite, current.height.isFinite, current.width > 0, current.height > 0,
              width.isFinite, height.isFinite, width >= 240, height >= 180 else { return current }
        let scale = min(1, width / current.width, height / current.height)
        return CGSize(width: floor(current.width * scale), height: floor(current.height * scale))
    }

    /// Resize once on an explicit desktop selection, then wait for the native window to settle.
    private func finishDesktopFit(_ frame: CGRect, id: CGWindowID, panel p: MainPanel,
                                  content c: WorkbenchContent) -> Bool {
        guard var pending = desktopFit, surface == .windows,
              let visible = (p.screen ?? NSScreen.main)?.visibleFrame else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if pending.requestedWindow == nil {
            let contentSize = p.contentRect(forFrameRect: p.frame).size
            let overhead = CGSize(width: p.frame.width - contentSize.width, height: p.frame.height - contentSize.height)
            let desired = Self.fittedDesktopSize(frame.size, available: visible.size, frameOverhead: overhead)
            if abs(desired.width - frame.width) > 1 || abs(desired.height - frame.height) > 1 {
                pending.requestedWindow = id
                pending.originalSize = frame.size
                pending.deadline = now + 1
                desktopFit = pending
                if surface.resize(desired) { return false }
            }
        } else if pending.requestedWindow == id, pending.originalSize == frame.size, now < pending.deadline {
            return false
        }
        desktopFit = nil
        state.windowsSize = frame.size
        Self.fitMain(p, content: c, phoneSize: frame.size)
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
        // The normal workbench fills the display. A deliberate target move changes only its slot.
        let local = c.convert(p.convertFromScreen(cgRect(frame)), from: nil)
        c.followedPhone = local
        c.layoutSubtreeIfNeeded()
    }

    /// Maintain relative order without raising/activating the phone. Ignore transient Stage Manager animation frames.
    private func dock() {
        guard wantMain, let p = main, let c = content else { return }
        guard !NSApp.isHidden else { return }
        defer { updateAgentDock(panel: p) }
        guard Permissions.accessibility else {
            p.phoneID = nil; lastDock = nil; placedDesktopID = nil
            c.phoneSlot.hint = "\(surface.displayName) 창을 붙이려면\n설정 › 시작하기에서 손쉬운 사용을 허용해 주세요"
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        let livePhone = surface.liveWindow()
        if surface == .windows, state.windowsWindowVisible != (livePhone != nil) {
            state.windowsWindowVisible = livePhone != nil
        }
        if desktopFit != nil, let phone = livePhone, let frame = surface.axFrame(), DockChange.near(frame, phone.rect) {
            guard finishDesktopFit(frame, id: phone.id, panel: p, content: c) else { return }
        }
        if awaitingPresentedPhone {
            // A failed/unfinished reveal must leave the workbench accessible on its own, rather than
            // immediately tucking it under the same buried window on the next timer tick.
            guard let phone = livePhone, isSurfacePresented(phone.id) else {
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
            c.phoneSlot.hint = surface == .iphone ? "iPhone 미러링을 연결해 주세요" : "Parallels에서 Windows 창을 열어 주세요"
            // Follow the phone off stage without pulling the user back from another app or Space.
            if surface.isRunning, !NSApp.isActive, !p.isKeyWindow, !state.agentVisible,
               ProcessInfo.processInfo.systemUptime >= explicitRevealUntil {
                WindowDiagnostics.panel("dock.hide", p)
                p.orderOut(nil)
            }
            else if !p.isVisible { p.orderFront(nil) }
            return
        }
        guard let frame = surface.axFrame(), DockChange.near(frame, phone.rect) else { return }
        guard finishDesktopFit(frame, id: phone.id, panel: p, content: c) else { return }
        p.phoneID = phone.id
        p.surfacePID = surface.processIdentifier
        if !p.isVisible { p.orderFront(nil) }
        else if p.needsReorder(under: phone.id) {
            WindowDiagnostics.panel("dock.reorder", p)
            p.orderFront(nil)
        }
        c.phoneSlot.hint = ""
        let current = DockSnapshot(phoneID: phone.id, panel: cgRect(p.frame), phone: frame)
        let change = DockChange.between(lastDock, and: current, explicitLayout: placementRequested)
        if change != .alignPhone { placedDesktopID = nil }
        let resized = abs(frame.width - surfaceSize.width) > 1 || abs(frame.height - surfaceSize.height) > 1
        if resized {
            if surface == .iphone { state.phoneSize = frame.size } else { state.windowsSize = frame.size }
            c.phoneSize = frame.size
            if !up { Self.fitMain(p, content: c, phoneSize: frame.size) }
        }
        if change == .alignPhone {
            WindowDiagnostics.panel("dock.alignPhone", p, fields: ["explicitLayout": placementRequested])
            c.followedPhone = nil
            c.layoutSubtreeIfNeeded()
            let target = phoneTarget(p, c)
            let alreadyPlaced = placedDesktopID == phone.id
            placedDesktopID = nil
            if !alreadyPlaced && (abs(frame.minX - target.minX) > 1 || abs(frame.minY - target.minY) > 1) {
                surface.place(target.origin)
                if surface == .windows {
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
