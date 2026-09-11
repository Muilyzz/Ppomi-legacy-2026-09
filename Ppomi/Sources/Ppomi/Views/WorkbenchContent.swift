// The normal workbench behind a native iPhone Mirroring or Windows window. Its views are lent to immersive covers.
import AppKit

/// Only the compact overlay paints over chat; a wide native opening remains transparent.
final class WorkbenchRecordSurface: WorkbenchSurface {
    var coversConversation = false
    override var isOpaque: Bool { coversConversation }
    override func draw(_ dirtyRect: NSRect) {
        if coversConversation { Palette.bg.setFill(); bounds.fill() }
    }
}

final class WorkbenchContent: WorkbenchSurface {
    let topBarArea = WorkbenchContentHost()
    let conversationArea = WorkbenchContentHost()
    let contentArea = WorkbenchRecordSurface()
    let recordsArea = WorkbenchContentHost()
    let controlToolbarArea = WorkbenchContentHost()
    let phoneSlot = DockView()
    let band = PhoneBand()
    /// Drawn over the hole: where the assistant tapped, the field it filled, reading in progress. Never a click target.
    let overlay = WorkbenchOverlayView()
    /// Explicitly parked control windows: independent from opening the compact content overlay.
    var recordsFocused = false { didSet { needsLayout = true } }
    var compactContentPresented = false { didSet { if oldValue != compactContentPresented { needsLayout = true } } }
    var onCompactLayout: ((Bool) -> Void)?
    /// 기록이 화면에 있을 때만 페이지들이 장부를 읽고 그린다(AppState.recordsOnScreen).
    var onRecordsVisibility: ((Bool) -> Void)?
    var surface: WorkSurface = .iphone {
        didSet {
            guard surface != oldValue else { return }
            phoneSlot.surface = surface
            phoneSlot.hint = ""
            needsLayout = true
        }
    }
    /// Native window coordinates relative to this root, regardless of the slot's nested parent.
    var followedPhone: CGRect? { didSet { needsLayout = true } }
    var phoneSize = Mirroring.defaultSize { didSet { needsLayout = true } }
    var phase: Phase = .idle { didSet { needsDisplay = true } }
    /// A docked native window shows through a transparent hole in this view instead of relying on window order.
    var dockedPhone = false { didSet { if dockedPhone != oldValue { needsLayout = true; needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [topBarArea, conversationArea, contentArea].forEach(addSubview)
        [phoneSlot, recordsArea, controlToolbarArea, band, overlay].forEach(contentArea.addSubview)
        phoneSlot.onLayoutChange = { [weak self] in
            guard let self, self.phoneSlot.superview === self.contentArea else { return }
            self.needsLayout = true
        }
        band.onLayoutChange = { [weak self] in
            guard let self, self.band.superview === self.contentArea else { return }
            self.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    func mount(topBar: NSView, sidebar: NSView, records: NSView, controlToolbar: NSView) {
        topBarArea.mount(topBar)
        conversationArea.mount(sidebar)
        recordsArea.mount(records)
        controlToolbarArea.mount(controlToolbar)
    }

    func reclaimContent() {
        topBarArea.reclaim()
        conversationArea.reclaim()
        recordsArea.reclaim()
        controlToolbarArea.reclaim()
        if band.superview !== contentArea { contentArea.addSubview(band) }
        if phoneSlot.superview !== contentArea { contentArea.addSubview(phoneSlot) }
        if overlay.superview !== contentArea { contentArea.addSubview(overlay) }
        needsLayout = true
    }

    func show(_ mark: OverlayMark) { overlay.show(mark) }

    var dashboard: WorkbenchLayout.Dashboard { WorkbenchLayout.dashboard(in: bounds) }

    /// 0 without a pending question: the 차례 띠 only takes height while it exists.
    var footerHeight: CGFloat {
        band.preferredHeight(for: max(0, dashboard.contentColumn.width - WorkbenchLayout.horizontalInset * 2))
    }
    /// Root coordinates, shared with native window placement.
    var controlAvailableArea: CGRect {
        dashboard.isCompact ? .zero : WorkbenchLayout.pane(in: dashboard.contentColumn, footerHeight: footerHeight).available
    }
    var nativeControlFits: Bool {
        !dashboard.isCompact && !recordsFocused && phoneSize.width <= controlAvailableArea.width && phoneSize.height <= controlAvailableArea.height
    }

    /// 넓은 화면에서 제어 창이 없을 때(연결 끊김·다른 스테이지·자리 밖)는 왼쪽에 기록을 보인다.
    var statusInSlot: Bool { !recordsFocused && !dockedPhone && followedPhone == nil && !phoneSlot.hint.isEmpty }
    private var showsRecords: Bool { dashboard.isCompact ? compactContentPresented : recordsFocused || statusInSlot }

    /// Drawing and click-through consume root coordinates, never the slot's content-local frame.
    var nativeHoleRect: CGRect? {
        guard !dashboard.isCompact, dockedPhone, !showsRecords, phoneSlot.superview === contentArea else { return nil }
        let rect = phoneSlot.convert(phoneSlot.bounds, to: self)
        return !rect.isEmpty && controlAvailableArea.contains(rect) ? rect : nil
    }

    override func layout() {
        super.layout()
        let dashboard = dashboard
        onCompactLayout?(dashboard.isCompact)
        topBarArea.frame = CGRect(x: dashboard.topBar.minX + WorkbenchLayout.horizontalInset,
                                  y: dashboard.topBar.minY,
                                  width: max(0, dashboard.topBar.width - WorkbenchLayout.horizontalInset * 2),
                                  height: dashboard.topBar.height)
        conversationArea.frame = WorkbenchLayout.pane(in: dashboard.conversationColumn).content
        contentArea.frame = dashboard.contentColumn
        contentArea.coversConversation = dashboard.isCompact
        let wasContentHidden = contentArea.isHidden
        contentArea.isHidden = dashboard.isCompact && !compactContentPresented
        if dashboard.isCompact, wasContentHidden, !contentArea.isHidden,
           let responder = window?.firstResponder as? NSView, responder.isDescendant(of: conversationArea) {
            window?.makeFirstResponder(nil)
        }
        contentArea.needsDisplay = true
        let control = WorkbenchLayout.pane(in: contentArea.bounds, footerHeight: footerHeight)
        topBarArea.isHidden = false
        conversationArea.isHidden = false
        controlToolbarArea.isHidden = dashboard.isCompact || showsRecords
        recordsArea.isHidden = !showsRecords
        onRecordsVisibility?(!contentArea.isHidden && !recordsArea.isHidden)
        controlToolbarArea.frame = control.toolbar
        recordsArea.frame = control.content
        if phoneSlot.superview === contentArea {
            phoneSlot.isHidden = dashboard.isCompact || showsRecords || dockedPhone
            if !dashboard.isCompact && !showsRecords {
                let followed = followedPhone.flatMap { controlAvailableArea.contains($0) ? contentArea.convert($0, from: self) : nil }
                phoneSlot.frame = followed ?? (nativeControlFits
                    ? WorkbenchLayout.topAlignedWindow(size: phoneSize, in: control.available) : control.available)
            }
        }
        if band.superview === contentArea {
            band.isHidden = footerHeight == 0
            band.frame = control.footer
        }
        if overlay.superview === contentArea {
            overlay.isHidden = dashboard.isCompact || showsRecords || phoneSlot.superview !== contentArea
            if phoneSlot.superview === contentArea { overlay.frame = phoneSlot.frame }
            contentArea.addSubview(overlay)
        }
        needsDisplay = true
    }

    /// The ink outline marks the person's turn only; the docked hole already shows the agent at work.
    override func draw(_ dirty: NSRect) {
        Palette.bg.setFill(); bounds.fill()
        if let hole = nativeHoleRect { NSColor.clear.setFill(); hole.fill(using: .copy) }
        guard !dashboard.isCompact, !showsRecords, phoneSlot.superview === contentArea else { return }
        guard case .humanTurn = phase else { return }
        let slot = phoneSlot.convert(phoneSlot.bounds, to: self)
        Palette.fg.setStroke()
        let outline = surface == .windows
            ? NSBezierPath(roundedRect: slot.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            : NSBezierPath(rect: slot.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2; outline.stroke()
    }
}
