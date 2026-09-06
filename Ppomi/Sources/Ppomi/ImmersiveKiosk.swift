import AppKit

/// Four disjoint covers in AppKit screen coordinates. The phone remains a separate, normal-level window.
struct ImmersiveLayout {
    let screen: CGRect
    let phone: CGRect?
    let bands: [CGRect]                         // top, bottom, left, right
    let sidebarIndex: Int
    var sidebar: CGRect { bands[sidebarIndex] }
    var exitFrame: CGRect {
        CGRect(x: screen.maxX - 48, y: screen.maxY - 48, width: 48, height: 48)
    }

    init(screen: CGRect, phone: CGRect?) {
        self.screen = screen
        let intersection = phone?.intersection(screen)
        let hole = intersection.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
        self.phone = hole
        if let hole {
            bands = [
                CGRect(x: screen.minX, y: hole.maxY, width: screen.width, height: screen.maxY - hole.maxY),
                CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: hole.minY - screen.minY),
                CGRect(x: screen.minX, y: hole.minY, width: hole.minX - screen.minX, height: hole.height),
                CGRect(x: hole.maxX, y: hole.minY, width: screen.maxX - hole.maxX, height: hole.height),
            ]
            sidebarIndex = bands[2].width >= bands[3].width ? 2 : 3
        } else {
            let empty = CGRect(origin: screen.origin, size: .zero)
            bands = [empty, empty, screen, empty]
            sidebarIndex = 2
        }
    }
}

/// A second, strictly contained hole replaces only the selected sidebar cover.
/// Coordinates remain in the screen's AppKit space, including displays with negative origins.
struct ImmersiveAgentLayout {
    let sidebar: CGRect
    let agent: CGRect
    let bands: [CGRect]                         // top, bottom, left, right

    static func availableArea(in sidebar: CGRect, bandHeight: CGFloat, toolbarHeight: CGFloat) -> CGRect {
        CGRect(x: sidebar.minX + 12, y: sidebar.minY + bandHeight + 20,
               width: max(0, sidebar.width - 24),
               height: max(0, sidebar.height - bandHeight - 20 - toolbarHeight - 12))
    }

    init?(sidebar: CGRect, agent: CGRect, bandHeight: CGFloat, toolbarHeight: CGFloat) {
        let available = Self.availableArea(in: sidebar, bandHeight: bandHeight, toolbarHeight: toolbarHeight)
        guard !available.isEmpty, !agent.isNull, !agent.isEmpty, available.contains(agent) else { return nil }
        self.sidebar = sidebar
        self.agent = agent
        bands = [
            CGRect(x: sidebar.minX, y: agent.maxY, width: sidebar.width, height: sidebar.maxY - agent.maxY),
            CGRect(x: sidebar.minX, y: sidebar.minY, width: sidebar.width, height: agent.minY - sidebar.minY),
            CGRect(x: sidebar.minX, y: agent.minY, width: agent.minX - sidebar.minX, height: agent.height),
            CGRect(x: agent.maxX, y: agent.minY, width: sidebar.maxX - agent.maxX, height: agent.height),
        ]
    }
}

/// Keys reveal the exit affordance; a deliberate second Escape exits. Repeated Escape never exits by itself.
struct ImmersiveExitState {
    private(set) var isVisible = false

    mutating func reveal() { isVisible = true }
    mutating func reset() { isVisible = false }
    mutating func keyPressed(isEscape: Bool, isRepeat: Bool) -> Bool {
        let exit = isVisible && isEscape && !isRepeat
        isVisible = true
        return exit
    }
}

private final class ImmersivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ImmersiveBandView: NSView {
    var onPress: (() -> Void)?
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
}

/// Immersive covers own no duplicate workbench or approval state. The controller lends its existing views while active.
/// This class never activates an app, moves the phone, changes application policy, or intercepts global input.
@MainActor
final class ImmersiveKiosk: NSObject {
    private let workbench: NSView
    private let band: PhoneBand
    private let onExit: () -> Void
    private var panels: [ImmersivePanel] = []
    private var agentPanels: [ImmersivePanel] = []
    private var agentLayout: ImmersiveAgentLayout?
    private var exitPanel: ImmersivePanel?
    private var exitState = ImmersiveExitState()
    private var exitRequested = false
    private(set) var screenFrame: CGRect?

    init(workbench: NSView, band: PhoneBand, onExit: @escaping () -> Void) {
        self.workbench = workbench
        self.band = band
        self.onExit = onExit
        super.init()
    }

    func show(on screen: NSScreen, phone: CGRect?, agent: CGRect? = nil) {
        screenFrame = screen.frame
        exitState.reset()
        exitRequested = false
        makePanelsIfNeeded()
        exitPanel?.orderOut(nil)
        update(phone: phone, agent: agent)
    }

    func update(phone: CGRect?, agent: CGRect? = nil) {
        guard let screenFrame else { return }
        let layout = ImmersiveLayout(screen: screenFrame, phone: phone)
        guard let host = panels[layout.sidebarIndex].contentView else { return }
        let sidebar = workbench as? AgentSidebar
        let footer = band.preferredHeight(for: max(0, layout.sidebar.width - 24))
        agentLayout = sidebar.flatMap { _ in agent.flatMap {
            ImmersiveAgentLayout(sidebar: layout.sidebar, agent: $0, bandHeight: footer,
                                 toolbarHeight: AgentSidebar.toolbarHeight)
        } }

        if let sidebar, let agentLayout {
            makeAgentPanelsIfNeeded()
            if workbench.superview !== host {
                workbench.removeFromSuperview()
                host.addSubview(workbench)
            }
            let top = agentPanels[0].contentView!, bottom = agentPanels[1].contentView!
            let remounted = sidebar.toolbar.superview !== top || band.superview !== bottom
            for (index, panel) in panels.enumerated() {
                updateCover(panel, frame: layout.bands[index], visible: index != layout.sidebarIndex)
            }
            // Set all host bounds before lending controls; no visible full-sidebar cover remains above the agent.
            for (panel, frame) in zip(agentPanels, agentLayout.bands) {
                updateCoverFrame(panel, frame: frame)
            }
            Self.mountAgentControls(toolbar: sidebar.toolbar, band: band, top: top, bottom: bottom,
                                    toolbarHeight: AgentSidebar.toolbarHeight)
            for (panel, frame) in zip(agentPanels, agentLayout.bands) { updateCover(panel, frame: frame) }
            if remounted { top.window?.orderFrontRegardless(); bottom.window?.orderFrontRegardless() }
        } else {
            let remounted = workbench.superview !== host || band.superview !== host || agentPanels.contains { $0.isVisible }
            if remounted { Self.mount(workbench: workbench, band: band, in: host) }
            for (panel, frame) in zip(panels, layout.bands) {
                if remounted, panel.contentView === host { host.needsLayout = true }
                updateCover(panel, frame: frame)
            }
            agentPanels.forEach { if $0.isVisible { $0.orderOut(nil) } }
            // Present the actual controls ahead of the otherwise empty covers for accessibility.
            if remounted { host.window?.orderFrontRegardless() }
        }
        if let exitPanel, exitPanel.frame != layout.exitFrame { exitPanel.setFrame(layout.exitFrame, display: true) }
        if layout.phone == nil { revealExit() }
        else { updateExitVisibility() }
    }

    func hide() {
        let covers = panels + agentPanels
        covers.forEach { $0.orderOut(nil) }
        exitPanel?.orderOut(nil)
        (workbench as? AgentSidebar)?.reclaimToolbar()
        if covers.contains(where: { $0.contentView === workbench.superview }) { workbench.removeFromSuperview() }
        if covers.contains(where: { $0.contentView === band.superview }) { band.removeFromSuperview() }
        agentLayout = nil
        screenFrame = nil
        exitState.reset()
        exitRequested = false
    }

    func revealExit() {
        guard screenFrame != nil else { return }
        exitState.reveal()
        updateExitVisibility()
    }

    /// Called by the owner's local/global monitor. It does not consume, repost, or modify the original event.
    func handleKey(_ event: NSEvent) {
        guard screenFrame != nil, event.type == .keyDown else { return }
        if exitState.keyPressed(isEscape: event.keyCode == 53, isRepeat: event.isARepeat) { requestExit() }
        else { updateExitVisibility() }
    }

    func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return (panels + agentPanels).contains { $0 === window } || exitPanel === window
    }

    static func agentAvailableArea(in sidebar: CGRect, bandHeight: CGFloat) -> CGRect {
        ImmersiveAgentLayout.availableArea(in: sidebar, bandHeight: bandHeight,
                                          toolbarHeight: AgentSidebar.toolbarHeight)
    }

    /// Kept separate from window creation so mounting and layout can be verified without showing any UI.
    static func mount(workbench: NSView, band: PhoneBand, in host: NSView) {
        (workbench as? AgentSidebar)?.reclaimToolbar()
        if workbench.superview !== host { workbench.removeFromSuperview(); host.addSubview(workbench) }
        if band.superview !== host { band.removeFromSuperview(); host.addSubview(band) }
        layoutContent(workbench: workbench, band: band, in: host.bounds)
    }

    static func layoutContent(workbench: NSView, band: PhoneBand, in bounds: CGRect) {
        let width = max(0, bounds.width - 24)
        let footer = band.preferredHeight(for: width)
        band.frame = CGRect(x: bounds.minX + 12, y: bounds.minY + 8, width: width, height: footer)
        workbench.frame = CGRect(x: bounds.minX + 12, y: bounds.minY + footer + 20,
                                 width: width, height: max(0, bounds.height - footer - 32))
        band.needsLayout = true
    }

    /// Reparents the same toolbar and approval band. No duplicate state or native windows are needed for testing.
    static func mountAgentControls(toolbar: NSView, band: PhoneBand, top: NSView, bottom: NSView,
                                   toolbarHeight: CGFloat) {
        if toolbar.superview !== top { toolbar.removeFromSuperview(); top.addSubview(toolbar) }
        if band.superview !== bottom { band.removeFromSuperview(); bottom.addSubview(band) }
        layoutAgentControls(toolbar: toolbar, band: band, top: top, bottom: bottom, toolbarHeight: toolbarHeight)
    }

    private static func layoutAgentControls(toolbar: NSView, band: PhoneBand, top: NSView, bottom: NSView,
                                            toolbarHeight: CGFloat) {
        let toolbarFrame = CGRect(x: top.bounds.minX + 12, y: top.bounds.maxY - toolbarHeight - 12,
                                  width: max(0, top.bounds.width - 24), height: toolbarHeight)
        if toolbar.frame != toolbarFrame { toolbar.frame = toolbarFrame }
        let width = max(0, bottom.bounds.width - 24)
        let bandFrame = CGRect(x: bottom.bounds.minX + 12, y: bottom.bounds.minY + 8,
                               width: width, height: band.preferredHeight(for: width))
        if band.frame != bandFrame { band.frame = bandFrame; band.needsLayout = true }
    }

    private func updateCover(_ panel: ImmersivePanel, frame: CGRect, visible: Bool = true) {
        updateCoverFrame(panel, frame: frame)
        if !visible || frame.isEmpty {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func updateCoverFrame(_ panel: ImmersivePanel, frame: CGRect) {
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.contentView?.needsLayout = true
            WindowDiagnostics.panel("immersive.cover", panel, fields: [
                "frame": [frame.minX, frame.minY, frame.width, frame.height], "level": panel.level.rawValue])
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func makeAgentPanelsIfNeeded() {
        guard agentPanels.isEmpty else { return }
        agentPanels = (0..<4).map { _ in makeCoverPanel() }
    }

    private func makeCoverPanel() -> ImmersivePanel {
        let panel = Self.makePanel()
        let view = ImmersiveBandView()
        view.onPress = { [weak self] in self?.revealExit() }
        view.onLayout = { [weak self, weak view] in
            guard let self, let view else { return }
            if self.workbench.superview === view, self.band.superview === view {
                Self.layoutContent(workbench: self.workbench, band: self.band, in: view.bounds)
            } else if self.agentLayout != nil, let sidebar = self.workbench as? AgentSidebar,
                      let top = self.agentPanels.first?.contentView,
                      let bottom = self.agentPanels.dropFirst().first?.contentView,
                      view === top || view === bottom {
                Self.layoutAgentControls(toolbar: sidebar.toolbar, band: self.band, top: top, bottom: bottom,
                                         toolbarHeight: AgentSidebar.toolbarHeight)
            }
        }
        panel.contentView = view
        return panel
    }

    private func makePanelsIfNeeded() {
        guard panels.isEmpty else { return }
        panels = (0..<4).map { _ in makeCoverPanel() }
        let exit = Self.makePanel()
        exit.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let button = NSButton(title: "×", target: self, action: #selector(exitPressed))
        button.font = .systemFont(ofSize: 30, weight: .light)
        button.isBordered = false
        button.contentTintColor = .white
        button.setAccessibilityLabel("전체화면 나가기")
        button.toolTip = "전체화면 나가기"
        button.autoresizingMask = [.width, .height]
        let content = ImmersiveBandView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        button.frame = content.bounds
        content.addSubview(button)
        exit.contentView = content
        exitPanel = exit
    }

    private static func makePanel() -> ImmersivePanel {
        let panel = ImmersivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        return panel
    }

    private func updateExitVisibility() {
        guard let exitPanel else { return }
        if exitState.isVisible {
            if !exitPanel.isVisible {
                exitPanel.orderFrontRegardless()
                WindowDiagnostics.panel("immersive.exitShown", exitPanel)
            }
        } else if exitPanel.isVisible {
            exitPanel.orderOut(nil)
        }
    }

    @objc private func exitPressed() { requestExit() }

    private func requestExit() {
        guard !exitRequested else { return }
        exitRequested = true
        onExit()
    }
}
