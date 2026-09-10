import AppKit

/// What the assistant just did or is doing, drawn over the docked window's hole. Geometry and one short line only —
/// never text read off the screen: the window underneath is the truth and may already have changed.
enum OverlayMark: Equatable {
    case tap(x: Double, y: Double)      // 0~1 inside the docked window
    case box(CGRect, ok: Bool)          // 0~1 rect the filler validated; a failed one lingers so the person sees where
    case reading(Bool)                  // OCR / VLM in flight
    case note(String)                   // a VLM answer, ≤ 120 characters
}

final class WorkbenchOverlayView: NSView {
    private struct Shown { let mark: OverlayMark; let at: TimeInterval; let ttl: TimeInterval }
    private var shown: [Shown] = []
    private var reading = false
    private var timer: Timer?
    private let note = WorkbenchLabel(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        note.isHidden = true
        note.font = .ppomi(2)
        note.textColor = Palette.fg
        note.drawsBackground = true
        note.backgroundColor = Palette.surface
        note.maximumNumberOfLines = 3
        addSubview(note)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    /// Never a click target: whatever is under the pointer belongs to the docked window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ mark: OverlayMark) {
        let now = ProcessInfo.processInfo.systemUptime
        switch mark {
        case .reading(let on): reading = on
        case .note(let text):
            note.stringValue = String(text.prefix(120))
            note.isHidden = note.stringValue.isEmpty
            shown.removeAll { if case .note = $0.mark { return true }; return false }
            shown.append(.init(mark: mark, at: now, ttl: 4))
        case .tap: shown.append(.init(mark: mark, at: now, ttl: 1.2))
        case .box(_, let ok): shown.append(.init(mark: mark, at: now, ttl: ok ? 2.5 : 5))
        }
        needsLayout = true
        needsDisplay = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        shown.removeAll { now - $0.at > $0.ttl }
        if !shown.contains(where: { if case .note = $0.mark { return true }; return false }) { note.isHidden = true }
        needsDisplay = true
        if shown.isEmpty, !reading { timer?.invalidate(); timer = nil }
    }

    override func layout() {
        super.layout()
        let width = min(max(0, bounds.width - 24), 420)
        let height = note.sizeThatFits(CGSize(width: width - 16, height: 200)).height + 12
        note.frame = CGRect(x: 12, y: 12, width: width, height: height)
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: bounds.minX + bounds.width * x, y: bounds.maxY - bounds.height * y)   // normalized y grows downward
    }
    private func rect(_ n: CGRect) -> CGRect {
        CGRect(x: bounds.minX + bounds.width * n.minX, y: bounds.maxY - bounds.height * n.maxY,
               width: bounds.width * n.width, height: bounds.height * n.height)
    }

    override func draw(_ dirty: NSRect) {
        let now = ProcessInfo.processInfo.systemUptime
        for item in shown {
            let age = now - item.at, alpha = max(0, 1 - age / item.ttl)
            switch item.mark {
            case .tap(let x, let y):
                let radius = 12 + age * 14
                let ring = NSBezierPath(ovalIn: CGRect(origin: point(x, y), size: .zero).insetBy(dx: -radius, dy: -radius))
                ring.lineWidth = 2.5
                Palette.accent.withAlphaComponent(alpha).setStroke(); ring.stroke()
            case .box(let normalized, let ok):
                let path = NSBezierPath(roundedRect: rect(normalized).insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
                path.lineWidth = 2
                (ok ? Palette.accent : Palette.bad).withAlphaComponent(max(alpha, ok ? 0 : 0.35)).setStroke(); path.stroke()
            default: break
            }
        }
        if reading {
            // A sweep along the top edge: "reading" without covering anything.
            let period = 1.4, phase = now.truncatingRemainder(dividingBy: period) / period
            let width: CGFloat = 140, x = bounds.minX - width + CGFloat(phase) * (bounds.width + width)
            let bar = CGRect(x: x, y: bounds.maxY - 3, width: width, height: 3)
            Palette.accent.withAlphaComponent(0.9).setFill(); bar.intersection(bounds).fill()
        }
    }
}
