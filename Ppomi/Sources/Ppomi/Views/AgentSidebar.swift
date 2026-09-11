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

/// Account and app-level actions remain available above both workspace panes.
struct WorkbenchTopBar: View {
    @EnvironmentObject private var state: AppState
    @State private var me = false

    var body: some View {
        HStack(spacing: 8) {
            Text("뽀미")
            Spacer(minLength: 8)
            if state.compactWorkbench {
                Button(state.compactContentActionTitle, action: state.presentCompactContent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compact-content-open")
                    .help("기록과 승인 요청 보기")
            }
            Button { me = true } label: { AvatarView(session: GoogleAccount.session, size: 20) }
                .buttonStyle(.plain)
                .accessibilityLabel("나")
                .accessibilityIdentifier("me-open")
                .sheet(isPresented: $me) { MeSheet().environmentObject(state) }
        }
        .font(.ppomi(2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ppomiTheme()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("앱")
    }
}

/// The wide record action parks native control windows inside the content pane.
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
            // 대상 선택기 없음: 어느 창을 데려올지는 도구 호출이 정한다(phone_*→iPhone, windows_*→Windows, android_*→Android)
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
