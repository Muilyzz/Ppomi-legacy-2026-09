import AppKit
import SwiftUI
import Combine

/// The native agent occupies this view's content rectangle. The toolbar and approval band remain Ppomi controls.
@MainActor
final class AgentSidebar: WorkbenchSurface {
    static let toolbarHeight: CGFloat = 40
    let toolbar: NSView
    private let records: NSView
    private let state: AppState
    private let hint = WorkbenchLabel(wrappingLabelWithString: "")
    private var subscription: AnyCancellable?

    init(records: NSView, state: AppState) {
        self.records = records; self.state = state
        toolbar = WorkbenchHostingView(rootView: AgentDockToolbar().environmentObject(state))
        super.init(frame: .zero)
        [toolbar, records, hint].forEach(addSubview)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 13)
        hint.maximumNumberOfLines = 5
        subscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
        }
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    var agentArea: CGRect {
        CGRect(x: 0, y: 0, width: max(0, bounds.width),
               height: max(0, bounds.height - Self.toolbarHeight - 12))
    }
    func reclaimToolbar() {
        if toolbar.superview !== self { addSubview(toolbar) }
        needsLayout = true
    }
    private func sync() {
        records.isHidden = state.agentVisible
        hint.isHidden = !state.agentVisible
        hint.stringValue = state.agentDockMessage
        needsLayout = true
    }
    override func layout() {
        super.layout()
        if toolbar.superview === self {
            toolbar.frame = CGRect(x: 0, y: max(0, bounds.height - Self.toolbarHeight),
                                   width: bounds.width, height: min(Self.toolbarHeight, bounds.height))
        }
        records.frame = agentArea
        hint.frame = CGRect(x: 20, y: max(0, agentArea.midY - 50), width: max(0, bounds.width - 40), height: min(100, agentArea.height))
    }
}

private struct AgentDockToolbar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 8) {
            Button("대화", systemImage: "bubble.left.and.bubble.right") { state.showAgent(true) }
                .tint(state.agentVisible ? .mint : .secondary)
                .accessibilityIdentifier("workbench-show-agent")
            Button("기록", systemImage: "square.stack") { state.showAgent(false) }
                .tint(state.agentVisible ? .secondary : .mint)
                .accessibilityIdentifier("workbench-show-records")
            if state.agentVisible {
                Menu {
                    ForEach(AgentApp.allCases, id: \.rawValue) { app in
                        Button(app.displayName) { state.selectAgent(app) }.disabled(!app.isInstalled)
                    }
                    Divider()
                    Button("대화창 다시 배치") { state.showAgent(true) }
                } label: { Text(state.agentApp.displayName).lineLimit(1) }
                .accessibilityIdentifier("workbench-agent-app")
                Spacer(minLength: 0)
                Menu {
                    ForEach(WorkSurface.allCases) { surface in
                        Button(surface.displayName) { state.selectSurface(surface) }
                            .disabled(state.ask != nil && surface != .iphone)
                    }
                } label: { Label(state.workSurface.displayName, systemImage: state.workSurface.symbolName) }
                .accessibilityIdentifier("workbench-agent-target")
            } else { Spacer(minLength: 0) }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
