import AppKit

/// Four disjoint covers in AppKit screen coordinates. The phone remains a separate, normal-level window.
struct ImmersiveLayout {
    let screen: CGRect
    let phone: CGRect?
    let bands: [CGRect]                         // top, bottom, left, right

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
        } else {
            let empty = CGRect(origin: screen.origin, size: .zero)
            bands = [empty, empty, screen, empty]
        }
    }
}

/// The two columns stay fixed while real windows move inside their own areas; the records page covers the whole screen.
struct ImmersiveDashboardLayout {
    let screen: CGRect
    let dashboard: WorkbenchLayout.Dashboard
    let controls: ImmersiveLayout
    let recordsCover: CGRect
    let sidebar: CGRect
    let footerHeight: CGFloat
    let recordsFocused: Bool
    var controlArea: CGRect {
        recordsFocused ? .zero : WorkbenchLayout.pane(in: dashboard.controlColumn, footerHeight: footerHeight).available
    }
    var exitFrame: CGRect { CGRect(x: screen.maxX - 48, y: screen.maxY - 48, width: 48, height: 48) }

    init(screen: CGRect, phone: CGRect?, controlWidth: CGFloat, recordsFocused: Bool = false, footerHeight: CGFloat = 0) {
        self.screen = screen
        self.footerHeight = footerHeight
        self.recordsFocused = recordsFocused
        // Covers reach the screen edge; each pane keeps its own immersiveTop gap inside.
        dashboard = WorkbenchLayout.dashboard(in: screen, controlWidth: controlWidth, topInset: 0)
        let empty = CGRect(origin: screen.origin, size: .zero)
        if recordsFocused {
            controls = ImmersiveLayout(screen: empty, phone: nil)
            recordsCover = screen
            sidebar = empty
        } else {
            let available = WorkbenchLayout.pane(in: dashboard.controlColumn, footerHeight: footerHeight).available
            controls = ImmersiveLayout(screen: dashboard.controlColumn, phone: phone.flatMap { available.contains($0) ? $0 : nil })
            recordsCover = empty
            sidebar = dashboard.conversationColumn
        }
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
    /// Covers never take keys; the conversation cover does, so the embedded chat can be typed into (without activation).
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

private final class ImmersiveBandView: NSView {
    var onPress: (() -> Void)?
    var onLayout: ((NSView) -> Void)?
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func layout() { super.layout(); onLayout?(self) }
    override func draw(_ dirtyRect: NSRect) { Palette.bg.setFill(); bounds.fill() }
}

/// Immersive covers own no duplicate workbench or approval state. The controller lends its existing views while active.
/// This class never activates an app, moves the phone, changes application policy, or intercepts global input.
@MainActor
final class ImmersiveKiosk: NSObject {
    private let workbench: NSView
    private let records: NSView
    private let controlToolbar: NSView
    private let controlPlaceholder: NSView
    private let band: PhoneBand
    private let onExit: () -> Void
    private var panels: [ImmersivePanel] = []
    private var recordsPanel: ImmersivePanel?
    private var conversationPanel: ImmersivePanel?
    private var exitPanel: ImmersivePanel?
    private var exitState = ImmersiveExitState()
    private var exitRequested = false
    private(set) var screenFrame: CGRect?

    init(workbench: NSView, records: NSView, controlToolbar: NSView, controlPlaceholder: NSView, band: PhoneBand, onExit: @escaping () -> Void) {
        self.workbench = workbench
        self.records = records
        self.controlToolbar = controlToolbar
        self.controlPlaceholder = controlPlaceholder
        self.band = band
        self.onExit = onExit
        super.init()
    }

    func show(on screen: NSScreen, phone: CGRect?, controlWidth: CGFloat, recordsFocused: Bool = false) {
        screenFrame = screen.frame
        exitState.reset()
        exitRequested = false
        makePanelsIfNeeded()
        exitPanel?.orderOut(nil)
        update(phone: phone, controlWidth: controlWidth, recordsFocused: recordsFocused)
    }

    static func layout(screen: CGRect, phone: CGRect?, controlWidth: CGFloat, recordsFocused: Bool = false,
                       footerHeight: CGFloat = 0) -> ImmersiveDashboardLayout {
        ImmersiveDashboardLayout(screen: screen, phone: phone, controlWidth: controlWidth, recordsFocused: recordsFocused,
                                 footerHeight: footerHeight)
    }

    func update(phone: CGRect?, controlWidth: CGFloat, recordsFocused: Bool = false) {
        guard let screenFrame else { return }
        let column = WorkbenchLayout.dashboard(in: screenFrame, controlWidth: controlWidth, topInset: 0).controlColumn
        let footer = band.preferredHeight(for: max(0, column.width - WorkbenchLayout.horizontalInset * 2))
        let layout = Self.layout(screen: screenFrame, phone: phone, controlWidth: controlWidth, recordsFocused: recordsFocused,
                                 footerHeight: footer)
        if conversationPanel == nil { conversationPanel = makeCoverPanel(); conversationPanel?.allowsKey = true }
        if recordsPanel == nil { recordsPanel = makeCoverPanel() }
        guard let conversationPanel, let host = conversationPanel.contentView,
              let recordsPanel, let recordsHost = recordsPanel.contentView else { return }

        // The same record view stays mounted whether either native app is connected or folded away.
        updateCoverFrame(recordsPanel, frame: layout.recordsCover)
        Self.mountRecords(records, in: recordsHost)
        updateCover(recordsPanel, frame: layout.recordsCover)
        for (panel, frame) in zip(panels, layout.controls.bands) { updateCoverFrame(panel, frame: frame) }
        let controlHost = panels[layout.controls.phone == nil ? 2 : 0].contentView!
        if layout.controls.phone == nil {
            Self.mountControl(toolbar: controlToolbar, placeholder: controlPlaceholder, band: band, footerHeight: footer,
                              recordsFocused: recordsFocused, in: controlHost)
        } else {
            controlPlaceholder.removeFromSuperview()
            Self.mountPaneControls(toolbar: controlToolbar, footer: band, footerHeight: footer,
                                   top: controlHost, bottom: panels[1].contentView!)
        }
        for (panel, frame) in zip(panels, layout.controls.bands) { updateCover(panel, frame: frame) }

        updateCoverFrame(conversationPanel, frame: layout.sidebar)
        Self.mountConversation(workbench: workbench, recordsFocused: recordsFocused, in: host)
        updateCover(conversationPanel, frame: layout.sidebar)
        if let exitPanel, exitPanel.frame != layout.exitFrame { exitPanel.setFrame(layout.exitFrame, display: true) }
        if phone == nil || layout.controls.phone == nil { revealExit() }
        else { updateExitVisibility() }
    }

    func hide() {
        let covers = panels + [recordsPanel, conversationPanel].compactMap { $0 }
        covers.forEach { $0.orderOut(nil) }
        exitPanel?.orderOut(nil)
        if covers.contains(where: { $0.contentView === workbench.superview }) { workbench.removeFromSuperview() }
        if covers.contains(where: { $0.contentView === records.superview }) { records.removeFromSuperview() }
        if covers.contains(where: { $0.contentView === band.superview }) { band.removeFromSuperview() }
        if covers.contains(where: { $0.contentView === controlToolbar.superview }) { controlToolbar.removeFromSuperview() }
        if covers.contains(where: { $0.contentView === controlPlaceholder.superview }) { controlPlaceholder.removeFromSuperview() }
        // The normal host controls its own visibility after it reclaims these same views.
        [workbench, controlToolbar, controlPlaceholder].forEach { $0.isHidden = false }
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
        return panels.contains { $0 === window } || recordsPanel === window || conversationPanel === window || exitPanel === window
    }

    /// Each host lays out only its currently mounted children. The conversation column is the shell alone.
    static func mountConversation(workbench: NSView, recordsFocused: Bool = false, in host: NSView) {
        if workbench.superview !== host { host.addSubview(workbench) }
        workbench.isHidden = recordsFocused
        (host as? ImmersiveBandView)?.onLayout = { [weak workbench] host in
            guard let workbench, workbench.superview === host else { return }
            layoutConversation(workbench: workbench, recordsFocused: recordsFocused, in: host.bounds)
        }
        layoutConversation(workbench: workbench, recordsFocused: recordsFocused, in: host.bounds)
    }

    static func layoutConversation(workbench: NSView, recordsFocused: Bool = false, in bounds: CGRect) {
        if !recordsFocused { workbench.frame = WorkbenchLayout.pane(in: bounds).content }
    }

    /// The same record view moves between hosts, retaining its selected page and scroll position.
    static func mountRecords(_ records: NSView, in host: NSView) {
        if records.superview !== host { records.removeFromSuperview(); host.addSubview(records) }
        (host as? ImmersiveBandView)?.onLayout = { [weak records] host in
            guard let records, records.superview === host else { return }
            layoutRecords(records, in: host.bounds)
        }
        layoutRecords(records, in: host.bounds)
    }

    private static func layoutRecords(_ records: NSView, in bounds: CGRect) {
        let frame = CGRect(x: bounds.minX + WorkbenchLayout.horizontalInset,
                           y: bounds.minY + WorkbenchLayout.contentGap,
                           width: max(0, bounds.width - WorkbenchLayout.horizontalInset * 2),
                           height: max(0, bounds.height - WorkbenchLayout.contentGap - WorkbenchLayout.immersiveTop))
        if records.frame != frame { records.frame = frame }
    }

    private static func mountControl(toolbar: NSView, placeholder: NSView, band: PhoneBand,
                                     footerHeight: CGFloat, recordsFocused: Bool = false, in host: NSView) {
        if toolbar.superview !== host { host.addSubview(toolbar) }
        if placeholder.superview !== host { host.addSubview(placeholder) }
        if band.superview !== host { host.addSubview(band) }
        toolbar.isHidden = recordsFocused
        placeholder.isHidden = recordsFocused
        let layout: (NSView) -> Void = { [weak toolbar, weak placeholder, weak band] host in
            let pane = WorkbenchLayout.pane(in: host.bounds, footerHeight: footerHeight)
            if let toolbar, !recordsFocused, toolbar.superview === host {
                toolbar.frame = pane.toolbar.divided(atDistance: 48, from: .maxXEdge).remainder
            }
            if let placeholder, !recordsFocused, placeholder.superview === host { placeholder.frame = pane.available }
            if let band, band.superview === host { band.frame = pane.footer }
        }
        (host as? ImmersiveBandView)?.onLayout = layout
        layout(host)
    }

    /// Headers and footers use the same geometry on both sides of native-window openings.
    static func mountPaneControls(toolbar: NSView, footer: NSView, footerHeight: CGFloat, top: NSView, bottom: NSView) {
        if toolbar.superview !== top { top.addSubview(toolbar) }
        if footer.superview !== bottom { bottom.addSubview(footer) }
        toolbar.isHidden = false
        (top as? ImmersiveBandView)?.onLayout = { [weak toolbar] host in
            guard let toolbar, toolbar.superview === host else { return }
            layoutToolbar(toolbar, in: host.bounds)
        }
        (bottom as? ImmersiveBandView)?.onLayout = { [weak footer] host in
            guard let footer, footer.superview === host else { return }
            layoutFooter(footer, height: footerHeight, in: host.bounds)
        }
        layoutToolbar(toolbar, in: top.bounds)
        layoutFooter(footer, height: footerHeight, in: bottom.bounds)
    }

    private static func layoutToolbar(_ toolbar: NSView, in bounds: CGRect) {
        let frame = CGRect(x: bounds.minX + WorkbenchLayout.horizontalInset,
                           y: bounds.maxY - WorkbenchLayout.toolbarHeight - WorkbenchLayout.immersiveTop,
                           width: max(0, bounds.width - WorkbenchLayout.horizontalInset * 2 - 48), height: WorkbenchLayout.toolbarHeight)
        if toolbar.frame != frame { toolbar.frame = frame }
    }

    private static func layoutFooter(_ footer: NSView, height: CGFloat, in bounds: CGRect) {
        let frame = CGRect(x: bounds.minX + WorkbenchLayout.horizontalInset,
                           y: bounds.minY + WorkbenchLayout.approvalBottom,
                           width: max(0, bounds.width - WorkbenchLayout.horizontalInset * 2), height: height)
        if footer.frame != frame { footer.frame = frame; footer.needsLayout = true }
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

    private func makeCoverPanel() -> ImmersivePanel {
        let panel = Self.makePanel()
        let view = ImmersiveBandView()
        view.onPress = { [weak self] in self?.revealExit() }
        panel.contentView = view
        return panel
    }

    private func makePanelsIfNeeded() {
        guard panels.isEmpty else { return }
        panels = (0..<4).map { _ in makeCoverPanel() }
        let exit = Self.makePanel()
        exit.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let button = NSButton(title: "×", target: self, action: #selector(exitPressed))
        button.font = .ppomi(6)
        button.isBordered = false
        button.contentTintColor = Palette.fg
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
        panel.backgroundColor = Palette.bg
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
