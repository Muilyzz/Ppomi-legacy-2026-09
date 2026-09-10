// The normal workbench behind a native iPhone Mirroring or Windows window. Its views are lent to immersive covers.
import AppKit

final class WorkbenchContent: WorkbenchSurface {
    let workbenchArea = WorkbenchContentHost()
    let recordsArea = WorkbenchContentHost()
    let controlToolbarArea = WorkbenchContentHost()
    let phoneSlot = DockView()
    let band = PhoneBand()
    /// Drawn over the hole: where the assistant tapped, the field it filled, reading in progress. Never a click target.
    let overlay = WorkbenchOverlayView()
    /// The records page replaces the whole workspace.
    var recordsFocused = false { didSet { needsLayout = true } }
    var surface: WorkSurface = .iphone {
        didSet {
            guard surface != oldValue else { return }
            phoneSlot.surface = surface
            phoneSlot.hint = ""
            needsLayout = true
        }
    }
    var followedPhone: CGRect? { didSet { needsLayout = true } }
    var phoneSize = Mirroring.defaultSize { didSet { needsLayout = true } }
    var phase: Phase = .idle { didSet { needsDisplay = true } }
    /// A docked native window shows through a transparent hole in this view instead of relying on window order.
    var dockedPhone = false { didSet { if dockedPhone != oldValue { needsLayout = true; needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [phoneSlot, workbenchArea, recordsArea, controlToolbarArea, band, overlay].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    func mount(sidebar: NSView, records: NSView, controlToolbar: NSView) {
        workbenchArea.mount(sidebar)
        recordsArea.mount(records)
        controlToolbarArea.mount(controlToolbar)
    }

    func reclaimContent() {
        workbenchArea.reclaim()
        recordsArea.reclaim()
        controlToolbarArea.reclaim()
        if band.superview !== self { addSubview(band) }
        if phoneSlot.superview !== self { addSubview(phoneSlot) }
        if overlay.superview !== self { addSubview(overlay) }
        needsLayout = true
    }

    func show(_ mark: OverlayMark) { overlay.show(mark) }

    var dashboard: WorkbenchLayout.Dashboard { WorkbenchLayout.dashboard(in: bounds, controlWidth: phoneSize.width) }

    /// 0 without a pending question: the 차례 띠 only takes height while it exists.
    var footerHeight: CGFloat {
        band.preferredHeight(for: max(0, dashboard.controlColumn.width - WorkbenchLayout.horizontalInset * 2))
    }
    var controlAvailableArea: CGRect { WorkbenchLayout.pane(in: dashboard.controlColumn, footerHeight: footerHeight).available }
    var nativeControlFits: Bool {
        !recordsFocused && phoneSize.width <= controlAvailableArea.width && phoneSize.height <= controlAvailableArea.height
    }

    override func layout() {
        super.layout()
        workbenchArea.isHidden = recordsFocused
        controlToolbarArea.isHidden = recordsFocused
        recordsArea.isHidden = !recordsFocused
        if phoneSlot.superview === self { phoneSlot.isHidden = recordsFocused || dockedPhone }
        if band.superview === self { band.isHidden = recordsFocused || footerHeight == 0 }
        needsDisplay = true
        if recordsFocused {
            recordsArea.frame = WorkbenchLayout.pane(in: dashboard.workspace, topInset: 0).content
            return
        }
        let dashboard = dashboard
        let control = WorkbenchLayout.pane(in: dashboard.controlColumn, footerHeight: footerHeight)
        controlToolbarArea.frame = control.toolbar
        if phoneSlot.superview === self {
            let followed = followedPhone.flatMap { control.available.contains($0) ? $0 : nil }
            phoneSlot.frame = followed ?? (nativeControlFits
                ? WorkbenchLayout.topAlignedWindow(size: phoneSize, in: control.available) : control.available)
        }
        if band.superview === self { band.frame = control.footer }
        overlay.frame = phoneSlot.frame
        overlay.isHidden = recordsFocused
        if overlay.superview === self { addSubview(overlay) }   // stays above the slot and the lent areas
        workbenchArea.frame = WorkbenchLayout.pane(in: dashboard.conversationColumn).content
    }

    /// The ink outline marks the person's turn only; the docked hole already shows the agent at work.
    override func draw(_ dirty: NSRect) {
        Palette.bg.setFill(); bounds.fill()
        guard !recordsFocused else { return }
        if dockedPhone { NSColor.clear.setFill(); phoneSlot.frame.fill(using: .copy) }
        guard case .humanTurn = phase else { return }
        Palette.fg.setStroke()
        let outline = surface == .windows
            ? NSBezierPath(roundedRect: phoneSlot.frame.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            : NSBezierPath(rect: phoneSlot.frame.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2; outline.stroke()
    }
}
