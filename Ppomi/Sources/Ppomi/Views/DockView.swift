import AppKit

/// 제어 자리 while it is empty: one line (the target name with its connection state, or a hint).
final class DockView: WorkbenchSurface {
    var onLayoutChange: (() -> Void)?
    var surface: WorkSurface = .iphone { didSet { if surface != oldValue { updateContent() } } }
    var hint = "" { didSet { if hint != oldValue { updateContent(); superview?.needsLayout = true; onLayoutChange?() } } }
    private let line = WorkbenchLabel(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        line.textColor = Palette.fg2
        line.alignment = .center
        line.lineBreakMode = .byTruncatingTail
        applyFonts()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Fonts.scaleChanged, object: nil)
        updateContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func applyFonts() {
        line.font = .ppomi(3)
        needsLayout = true
    }

    var text: String { line.stringValue }

    private func updateContent() {
        line.stringValue = hint.isEmpty ? "\(surface.displayName) · 연결 끊김" : hint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        let height = line.intrinsicContentSize.height
        line.frame = CGRect(x: 16, y: bounds.midY - height / 2, width: width, height: height)
    }

    override func draw(_ dirty: NSRect) {
        Palette.bg.setFill(); bounds.fill()
    }
}
