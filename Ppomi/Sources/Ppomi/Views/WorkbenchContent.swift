// The normal workbench behind a native iPhone Mirroring or Windows window. Its views are lent to immersive covers.
import AppKit

final class WorkbenchContent: WorkbenchSurface {
    static let rimTop: CGFloat = 32, rimBottom: CGFloat = 96, rimRight: CGFloat = 32, bandMin: CGFloat = 560
    let workbenchArea = WorkbenchSurface()
    let phoneSlot = DockView()
    let band = PhoneBand()
    private let exitButton = WorkbenchButton(title: "창으로 돌아가기", target: nil, action: nil)
    private let surfaceLabel = WorkbenchLabel(labelWithString: "Windows · Parallels")
    weak var workbench: NSView?
    var surface: WorkSurface = .iphone {
        didSet {
            guard surface != oldValue else { return }
            phoneSlot.surface = surface
            phoneSlot.hint = ""
            surfaceLabel.isHidden = surface != .windows
            needsLayout = true
        }
    }
    var fullWindow = false { didSet { needsLayout = true } }
    var layoutSuspended = false
    var onExitExpanded: (() -> Void)?
    var expanded = false { didSet { needsLayout = true; exitButton.isHidden = !expanded } }
    var followedPhone: CGRect? { didSet { needsLayout = true } }
    var phoneSize = Mirroring.defaultSize { didSet { needsLayout = true } }
    var phase: Phase = .idle { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [phoneSlot, workbenchArea, band, exitButton, surfaceLabel].forEach(addSubview)
        exitButton.target = self; exitButton.action = #selector(exitExpanded)
        exitButton.bezelStyle = .rounded; exitButton.controlSize = .small
        exitButton.isHidden = true
        surfaceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        surfaceLabel.textColor = NSColor(white: 1, alpha: 0.55)
        surfaceLabel.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    @objc private func exitExpanded() { onExitExpanded?() }

    static func minimumBandWidth(for surface: WorkSurface) -> CGFloat {
        surface == .windows ? 380 : bandMin
    }

    private static func insets(for surface: WorkSurface) -> (top: CGFloat, bottom: CGFloat, right: CGFloat) {
        surface == .windows ? (48, 32, 24) : (rimTop, rimBottom, rimRight)
    }

    static func size(bandWidth: CGFloat, phone: CGSize, surface: WorkSurface = .iphone) -> CGSize {
        let inset = insets(for: surface)
        return CGSize(width: bandWidth + phone.width + inset.right, height: phone.height + inset.top + inset.bottom)
    }

    override func layout() {
        super.layout()
        guard !layoutSuspended else { return }
        let b = bounds
        let inset = Self.insets(for: surface)
        let y = (expanded || fullWindow) ? max(0, (b.height - phoneSize.height) / 2) : inset.bottom
        let h = followedPhone ?? CGRect(x: b.maxX - inset.right - phoneSize.width,
                                         y: y, width: phoneSize.width, height: phoneSize.height)
        phoneSlot.frame = h
        surfaceLabel.frame = CGRect(x: h.minX + 12, y: h.maxY + 14, width: max(0, h.width - 24), height: 18)
        surfaceLabel.isHidden = surface != .windows || !b.contains(surfaceLabel.frame)
        // Pick the roomier side if the person drags the phone across the expanded workbench.
        let leftWidth = max(0, min(b.width, h.minX))
        let rightX = max(0, min(b.width, h.maxX))
        let column = leftWidth >= b.maxX - rightX
            ? CGRect(x: 0, y: 0, width: leftWidth, height: b.height)
            : CGRect(x: rightX, y: 0, width: b.maxX - rightX, height: b.height)
        // The human approval controls stay in the visible sidebar even with a tall phone or a short display.
        let sidebarWidth = max(0, column.width - 24)
        let footer = band.preferredHeight(for: sidebarWidth)
        band.frame = CGRect(x: column.minX + 12, y: 8, width: sidebarWidth, height: footer)
        workbenchArea.frame = CGRect(x: column.minX + 12, y: footer + 20,
                                     width: max(0, column.width - 24), height: max(0, b.height - footer - 52))
        workbench?.frame = workbenchArea.bounds
        exitButton.frame = CGRect(x: max(column.minX + 76, column.maxX - 140), y: b.maxY - 28, width: 128, height: 22)
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let (color, width): (NSColor, CGFloat) = switch phase {
        case .agent: (NSColor(red: 0.78, green: 0.64, blue: 0, alpha: 1), 2)
        case .humanTurn: (NSColor(white: 1, alpha: 0.9), 1)
        default: (NSColor(white: 1, alpha: 0.25), 1)
        }
        color.setStroke()
        let outline = surface == .windows
            ? NSBezierPath(roundedRect: phoneSlot.frame.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            : NSBezierPath(rect: phoneSlot.frame.insetBy(dx: -1, dy: -1))
        outline.lineWidth = width; outline.stroke()
    }
}

/// Status and human approval controls. The same instance survives both window modes.
final class PhoneBand: WorkbenchSurface {
    weak var state: AppState?
    private let question = WorkbenchLabel(labelWithString: "")
    private let buttons = WorkbenchStack()
    private let clock = WorkbenchLabel(labelWithString: "")
    private let caption = WorkbenchLabel(wrappingLabelWithString: "")
    private var askID: String?, deadline = Date(), timer: Timer?
    static let lineHeight: CGFloat = 16

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        for t in [question, caption] { t.font = .systemFont(ofSize: 12); t.alignment = .center; t.lineBreakMode = .byTruncatingTail }
        question.textColor = NSColor(white: 1, alpha: 0.9)
        caption.textColor = NSColor(white: 1, alpha: 0.7); caption.maximumNumberOfLines = 3
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); clock.textColor = NSColor(white: 1, alpha: 0.55)
        buttons.orientation = .horizontal; buttons.spacing = 8; buttons.alignment = .centerY
        [question, buttons, caption].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func captionHeight(for width: CGFloat) -> CGFloat {
        let measured = (caption.stringValue as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: caption.font ?? NSFont.systemFont(ofSize: 12)]).height
        return Self.lineHeight * max(1, min(3, ceil(measured / Self.lineHeight)))
    }

    /// Measure the controls at their natural widths, even after a narrow layout compressed them.
    private func controlsLayout(for width: CGFloat) -> (vertical: Bool, size: CGSize) {
        let sizes = buttons.arrangedSubviews.map { view -> CGSize in
            let intrinsic = view.intrinsicContentSize
            return CGSize(width: max(0, intrinsic.width), height: max(0, intrinsic.height))
        }
        let gaps = CGFloat(max(0, sizes.count - 1)) * buttons.spacing
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width } + gaps
        let vertical = naturalWidth > max(0, width)
        let height = vertical ? sizes.reduce(CGFloat.zero) { $0 + $1.height } + gaps : sizes.map(\.height).max() ?? 0
        return (vertical, CGSize(width: vertical ? max(0, width) : naturalWidth, height: height))
    }

    /// A narrow sidebar stacks choices instead of clipping the human approval buttons.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let questionAndControls = askID == nil ? 0 : Self.lineHeight + 4 + controlsLayout(for: width).size.height + 4
        return max(116, 6 + questionAndControls + captionHeight(for: width) + 6)
    }

    /// Pull what the state says now (KioskController.sync calls this on every change).
    func sync() {
        guard let s = state else { return }
        caption.stringValue = [s.statusLine, s.heard, s.said].filter { !$0.isEmpty }.joined(separator: "\n")
        if s.ask?.id != askID {
            askID = s.ask?.id
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            timer?.invalidate(); timer = nil
            question.stringValue = s.ask?.text ?? ""
            if let a = s.ask {
                for (i, o) in a.options.enumerated() {
                    let b = WorkbenchButton(title: o, target: self, action: #selector(pressed(_:)))
                    b.bezelStyle = .rounded; b.controlSize = .regular; b.tag = i
                    b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    b.lineBreakMode = .byTruncatingTail
                    if i == 0, o.hasPrefix("결제 승인") {                   // the money button: white fill, black text
                        b.bezelColor = .white
                        b.attributedTitle = NSAttributedString(string: o, attributes: [.foregroundColor: NSColor.black, .font: b.font ?? .systemFont(ofSize: 13)])
                    }
                    buttons.addArrangedSubview(b)
                    b.widthAnchor.constraint(lessThanOrEqualTo: buttons.widthAnchor).isActive = true
                }
                buttons.addArrangedSubview(clock)
                clock.widthAnchor.constraint(lessThanOrEqualTo: buttons.widthAnchor).isActive = true
                deadline = Date(timeIntervalSinceNow: 300)
                tick()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
        question.isHidden = askID == nil; buttons.isHidden = askID == nil
        needsLayout = true
        superview?.needsLayout = true
    }

    private func tick() {
        let left = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        clock.stringValue = String(format: "%d:%02d", left / 60, left % 60)
    }

    @objc private func pressed(_ b: NSButton) {
        guard let s = state, let a = s.ask, b.tag < a.options.count else { return }
        s.answer(a.options[b.tag])
    }

    /// From the top down: question, the choice row or column, then the caption's lines.
    override func layout() {
        super.layout()
        var y = bounds.height - 6
        let lh = Self.lineHeight
        if askID != nil {
            question.frame = NSRect(x: 0, y: y - lh, width: bounds.width, height: lh); y -= lh + 4
            let controls = controlsLayout(for: bounds.width)
            buttons.orientation = controls.vertical ? .vertical : .horizontal
            buttons.alignment = controls.vertical ? .centerX : .centerY
            buttons.frame = NSRect(x: (bounds.width - controls.size.width) / 2, y: y - controls.size.height,
                                   width: controls.size.width, height: controls.size.height)
            buttons.layoutSubtreeIfNeeded()
            y -= controls.size.height + 4
        }
        let captionHeight = captionHeight(for: bounds.width)
        caption.frame = NSRect(x: 0, y: max(0, y - captionHeight), width: bounds.width, height: captionHeight)
    }
}

/// Native labels behind the selected external window, visible while it is disconnected.
final class DockView: WorkbenchSurface {
    var surface: WorkSurface = .iphone { didSet { if surface != oldValue { updateContent() } } }
    var hint = "" { didSet { if hint != oldValue { updateContent() } } }
    private let icon = NSImageView()
    private let title = WorkbenchLabel(labelWithString: "")
    private let instruction = WorkbenchLabel(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        [icon, title, instruction].forEach(addSubview)
        icon.contentTintColor = NSColor(white: 1, alpha: 0.45)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.7)
        instruction.font = .systemFont(ofSize: 13)
        instruction.textColor = NSColor(white: 1, alpha: 0.5)
        instruction.maximumNumberOfLines = 4
        [title, instruction].forEach { $0.alignment = .center }
        updateContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateContent() {
        icon.image = NSImage(systemSymbolName: surface.symbolName, accessibilityDescription: nil)
        title.stringValue = surface.displayName
        instruction.stringValue = hint.isEmpty
            ? (surface == .windows ? "Parallels에서 Windows를 창 모드로 열면\n그 창이 여기에 붙습니다"
                                   : "iPhone 미러링을 실행하면\n그 창이 여기에 붙습니다")
            : hint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let center = bounds.midY
        let width = max(0, bounds.width - 32)
        icon.frame = CGRect(x: bounds.midX - 18, y: center + 24, width: 36, height: 36)
        title.frame = CGRect(x: 16, y: center - 4, width: width, height: 20)
        instruction.frame = CGRect(x: 16, y: center - 80, width: width, height: 64)
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
    }
}
