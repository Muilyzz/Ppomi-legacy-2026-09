import AppKit

/// A spanning top bar, records/control on the left, and persistent conversation on the right.
/// Native target dimensions affect whether the control fits, never the ownership of these regions.
enum WorkbenchLayout {
    static let horizontalInset: CGFloat = 12
    static let approvalBottom: CGFloat = 8
    static let contentGap: CGFloat = 8
    static let normalTop: CGFloat = 32       // Keep clear of the native titlebar.
    static let immersiveTop: CGFloat = 12
    /// Text-bearing heights follow the app's 글자 크기 (AppSettings.uiScale) so nothing overlaps at 2–3×.
    static var scale: CGFloat { CGFloat(AppSettings.uiScale) }
    static var toolbarHeight: CGFloat { 40 * scale }
    /// Space for the titlebar, top bar, control header and the smallest 515-point mirror, rounded up.
    static let minimumContentSize = CGSize(width: 1040, height: 680)
    /// 대화 열 폭(폰 스타일, 고정): 셸 388 + 여백. A wide target (Windows) pushes the window minimum out beside it.
    static let conversationWidth: CGFloat = 412
    static let compactWidth: CGFloat = 600

    struct Dashboard {
        let topBar: CGRect
        let workspace: CGRect
        let conversationColumn: CGRect
        let contentColumn: CGRect
        let isCompact: Bool
    }

    static func dashboard(in bounds: CGRect,
                          topInset: CGFloat = WorkbenchLayout.normalTop) -> Dashboard {
        let availableHeight = max(0, bounds.height - max(0, topInset))
        let barHeight = min(toolbarHeight, availableHeight)
        let workspace = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                               height: availableHeight - barHeight)
        let topBar = CGRect(x: bounds.minX, y: workspace.maxY, width: bounds.width, height: barHeight)
        let conversation: CGRect, control: CGRect
        let isCompact = workspace.width < compactWidth
        if isCompact {
            // Content is an explicit overlay. Conversation keeps its full, mounted viewport underneath.
            conversation = workspace
            control = workspace
        } else {
            let chatWidth = min(conversationWidth, workspace.width * 0.45)
            control = CGRect(x: workspace.minX, y: workspace.minY,
                             width: max(0, workspace.width - chatWidth), height: workspace.height)
            conversation = CGRect(x: control.maxX, y: workspace.minY, width: chatWidth, height: workspace.height)
        }
        return Dashboard(topBar: topBar, workspace: workspace, conversationColumn: conversation,
                         contentColumn: control, isCompact: isCompact)
    }

    /// A column: content (toolbar above the available area) and, only when `footerHeight` > 0, the 차례 띠 below.
    struct Pane {
        let content: CGRect
        let toolbar: CGRect
        let available: CGRect
        let footer: CGRect
    }

    static func pane(in bounds: CGRect, footerHeight: CGFloat = 0,
                     topInset: CGFloat = WorkbenchLayout.immersiveTop,
                     toolbarHeight: CGFloat = WorkbenchLayout.toolbarHeight) -> Pane {
        let width = max(0, bounds.width - horizontalInset * 2)
        let footer = CGRect(x: bounds.minX + horizontalInset, y: bounds.minY + approvalBottom,
                            width: width, height: max(0, footerHeight))
        let contentMinY = footerHeight > 0 ? footer.maxY + contentGap : footer.minY
        let content = CGRect(x: footer.minX, y: contentMinY, width: width,
                             height: max(0, bounds.maxY - contentMinY - topInset))
        let local = CGRect(origin: .zero, size: content.size)
        let toolbar = CGRect(x: content.minX, y: max(content.minY, content.maxY - toolbarHeight),
                             width: content.width, height: min(toolbarHeight, content.height))
        let available = agentArea(in: local, toolbarHeight: toolbarHeight)
            .offsetBy(dx: content.minX, dy: content.minY)
        return Pane(content: content, toolbar: toolbar, available: available, footer: footer)
    }

    static func topAlignedWindow(size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height,
               width: size.width, height: size.height)
    }

    static func agentArea(in bounds: CGRect, toolbarHeight: CGFloat = WorkbenchLayout.toolbarHeight) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width),
               height: max(0, bounds.height - toolbarHeight - contentGap))
    }
}

/// Retains a view while it is lent to another window; only its current parent may lay it out.
final class WorkbenchContentHost: WorkbenchSurface {
    private var content: NSView?

    func mount(_ view: NSView) {
        if let content, content !== view, content.superview === self { content.removeFromSuperview() }
        content = view
        reclaim()
    }

    func reclaim() {
        if let content, content.superview !== self { addSubview(content) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let content, content.superview === self { content.frame = bounds }
    }
}
