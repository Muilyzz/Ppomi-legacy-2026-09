import AppKit

/// The workbench tree (docs/ui-tree.md): 대화 takes the remaining width, 제어 the target window's width; the 차례 띠
/// exists only while a question is pending. Records replace the whole workspace as a page.
enum WorkbenchLayout {
    static let horizontalInset: CGFloat = 12
    static let approvalBottom: CGFloat = 8
    static let contentGap: CGFloat = 8
    static let normalTop: CGFloat = 32       // Keep clear of the native titlebar.
    static let immersiveTop: CGFloat = 12
    /// Text-bearing heights follow the app's 글자 크기 (AppSettings.uiScale) so nothing overlaps at 2–3×.
    static var scale: CGFloat { CGFloat(AppSettings.uiScale) }
    static var toolbarHeight: CGFloat { 40 * scale }
    /// The small iPhone mirror (232×515) with its insets: the control column never gets narrower.
    static let minimumControlWidth: CGFloat = 232 + horizontalInset * 2
    /// Height: normalTop + immersiveTop + toolbar + gap + 515 + approvalBottom = 615, rounded up.
    static let minimumContentSize = CGSize(width: 1040, height: 640)
    /// A wide target (Windows) pushes the window minimum out so the shell keeps a usable width beside it.
    static let minimumConversationWidth: CGFloat = 400

    struct Dashboard {
        let workspace: CGRect
        let conversationColumn: CGRect
        let controlColumn: CGRect
    }

    static func dashboard(in bounds: CGRect, controlWidth: CGFloat,
                          topInset: CGFloat = WorkbenchLayout.normalTop) -> Dashboard {
        let workspace = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, bounds.height - topInset))
        let control = min(workspace.width, max(minimumControlWidth, controlWidth + horizontalInset * 2))
        let right = CGRect(x: workspace.maxX - control, y: workspace.minY, width: control, height: workspace.height)
        let left = CGRect(x: workspace.minX, y: workspace.minY, width: workspace.width - control, height: workspace.height)
        return Dashboard(workspace: workspace, conversationColumn: left, controlColumn: right)
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
