import AppKit
import SwiftUI

/// The conversation column: only the embedded shell. Its header and status live inside the shell itself.
@MainActor
final class AgentSidebar: WorkbenchSurface, ConversationHost {
    private let state: AppState
    private var conversation: NSView?
    private let placeholder = WorkbenchLabel(labelWithString: "대화 닫힘")

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        placeholder.textColor = Palette.fg2
        placeholder.alignment = .center
        addSubview(placeholder)
        applyFonts()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Fonts.scaleChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func applyFonts() { placeholder.font = .ppomi(3); needsLayout = true }

    var agentArea: CGRect { bounds }
    var hasConversation: Bool { conversation != nil }
    var placeholderHidden: Bool { placeholder.isHidden }

    /// Ppomi's own chat fills the column; the same rectangle hosts an external agent window otherwise.
    func mount(conversation view: NSView) {
        if let conversation, conversation !== view, conversation.superview === self { conversation.removeFromSuperview() }
        conversation = view
        if view.superview !== self { addSubview(view) }
        needsLayout = true
    }

    func unmount(conversation view: NSView) {
        guard conversation === view else { return }
        if view.superview === self { view.removeFromSuperview() }
        conversation = nil
        needsLayout = true
    }

    func revealConversation() { state.showWorkbench() }

    override func layout() {
        super.layout()
        let area = agentArea
        if let conversation, conversation.superview === self { conversation.frame = area }
        placeholder.isHidden = conversation != nil
        let height = placeholder.intrinsicContentSize.height
        placeholder.frame = CGRect(x: area.minX + 16, y: area.midY - height / 2, width: max(0, area.width - 32), height: height)
    }
}

/// 제어 머리띠: the target picker and the 기록 button, nothing else.
struct ControlTargetToolbar: View {
    @EnvironmentObject private var state: AppState

    /// Records wait for the person's turn to end and the agent to release the screen.
    private var recordsAvailable: Bool {
        if state.ask != nil { return false }
        if case .agent = state.phase { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("제어 화면", selection: Binding(get: { state.workSurface }, set: state.selectSurface)) {
                ForEach(WorkSurface.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .pickerStyle(.menu)       // a dropdown, like the Storybook <select>: the control column is only as wide as the target
            .labelsHidden()
            .font(.ppomi(2))
            .controlSize(.ppomiSmall)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(state.ask != nil)
            .accessibilityIdentifier("workbench-control-target")
            Spacer(minLength: 8)
            Button("기록", action: state.toggleRecordsFocus)
                .controlSize(.ppomiSmall)
                .disabled(!recordsAvailable)
                .accessibilityIdentifier("records-open")
        }
        .font(.ppomi(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: WorkbenchLayout.toolbarHeight)
        .ppomiTheme()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("제어")
    }
}
