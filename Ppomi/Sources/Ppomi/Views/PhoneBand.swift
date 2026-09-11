import AppKit

/// 차례 띠: one question line and its buttons, only while a question is pending. The same instance survives both window modes.
final class PhoneBand: WorkbenchSurface {
    weak var state: AppState?
    var onLayoutChange: (() -> Void)?
    private let question = WorkbenchLabel(labelWithString: "")
    private let buttons = WorkbenchStack()
    private var askID: String?
    static var lineHeight: CGFloat { 16 * AppSettings.uiScale }

    init() {
        super.init(frame: .zero)
        question.alignment = .center; question.lineBreakMode = .byTruncatingTail
        question.textColor = Palette.fg
        buttons.orientation = .horizontal; buttons.spacing = 8; buttons.alignment = .centerY
        [question, buttons].forEach(addSubview)
        isHidden = true
        applyFonts()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Fonts.scaleChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func applyFonts() {
        question.font = .ppomi(2)
        for case let b as NSButton in buttons.arrangedSubviews { style(b, index: b.tag) }
        needsLayout = true
        superview?.needsLayout = true
        onLayoutChange?()
    }

    /// The first "결제 승인" choice is the money button: accent fill, dark text.
    private func style(_ b: NSButton, index: Int) {
        b.font = .ppomi(3)
        guard index == 0, b.title.hasPrefix("결제 승인") else { return }
        b.bezelColor = Palette.accent
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: Palette.onAccent, .font: NSFont.ppomi(3)])
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

    /// 0 without a question. A narrow column stacks choices instead of clipping the human approval buttons.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard askID != nil else { return 0 }
        return 6 + Self.lineHeight + 4 + controlsLayout(for: width).size.height + 6
    }

    /// Pull what the state says now (KioskController.sync calls this on every change).
    func sync() {
        guard let s = state else { return }
        if s.ask?.id != askID {
            askID = s.ask?.id
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            question.stringValue = s.ask?.text ?? ""
            if let a = s.ask {
                for (i, o) in a.options.enumerated() {
                    let b = WorkbenchButton(title: o, target: self, action: #selector(pressed(_:)))
                    b.bezelStyle = .rounded; b.controlSize = .regular; b.tag = i
                    b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    b.lineBreakMode = .byTruncatingTail
                    style(b, index: i)
                    buttons.addArrangedSubview(b)
                    b.widthAnchor.constraint(lessThanOrEqualTo: buttons.widthAnchor).isActive = true
                }
            }
        }
        isHidden = askID == nil
        needsLayout = true
        superview?.needsLayout = true
        onLayoutChange?()
    }

    @objc private func pressed(_ b: NSButton) {
        guard let s = state, let a = s.ask, b.tag < a.options.count else { return }
        s.answer(a.options[b.tag])
    }

    /// From the top down: the question, then the choice row or column.
    override func layout() {
        super.layout()
        guard askID != nil else { return }
        let lh = Self.lineHeight
        let y = bounds.height - 6
        question.frame = NSRect(x: 0, y: y - lh, width: bounds.width, height: lh)
        let controls = controlsLayout(for: bounds.width)
        buttons.orientation = controls.vertical ? .vertical : .horizontal
        buttons.alignment = controls.vertical ? .centerX : .centerY
        buttons.frame = NSRect(x: (bounds.width - controls.size.width) / 2, y: y - lh - 4 - controls.size.height,
                               width: controls.size.width, height: controls.size.height)
        buttons.layoutSubtreeIfNeeded()
    }
}
