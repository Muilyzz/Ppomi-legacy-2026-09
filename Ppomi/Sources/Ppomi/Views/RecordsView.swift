import AppKit
import SwiftUI

private struct RecordsPageActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Cached pages retain their content while background polling follows the visible page only.
    var recordsPageIsActive: Bool {
        get { self[RecordsPageActivityKey.self] }
        set { self[RecordsPageActivityKey.self] = newValue }
    }
}

/// One records owner beside or over conversation; presentation and parked-window restoration are separate actions.
struct RecordsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if state.compactWorkbench {
                    Button("대화로 돌아가기", action: state.dismissCompactContent)
                        .buttonStyle(.plain)
                        .font(.ppomi(2, weight: .medium))
                        .help("Esc · 승인 요청과 제어 상태는 유지됩니다")
                        .accessibilityIdentifier("compact-content-close")
                }
                if state.recordsFocused {
                    Button("제어로 돌아가기", action: state.toggleRecordsFocus)
                        .buttonStyle(.plain)
                        .font(.ppomi(2, weight: .medium))
                        .help("Esc")
                        .accessibilityLabel("제어로 돌아가기")
                        .accessibilityIdentifier("records-back")
                }
                RecordsNavigation(selection: state.tab, select: state.show)
                if let message = state.recordsFocusMessage {
                    Text(message).font(.ppomi(1)).foregroundStyle(.bad)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("records-focus-message")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: WorkbenchLayout.toolbarHeight, alignment: .leading)
            Divider().overlay(Color.line)
            RecordsPages(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.surface)
        .ppomiTheme()
    }
}

private struct RecordsNavigation: View {
    let selection: AppState.Tab
    let select: (AppState.Tab) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
            picker.pickerStyle(.menu)
        }
        .labelsHidden()
        .controlSize(.ppomiSmall)
        .font(.ppomi(2))
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("기록 보기")
    }

    private var picker: some View {
        Picker("기록 보기", selection: Binding(get: { selection }, set: select)) {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
                    .accessibilityIdentifier("records-tab-\(tab.rawValue)")
            }
        }
    }
}

private extension AppState.Tab {
    var title: String {
        switch self {
        case .timeline: "타임라인"
        case .evidence: "증빙"
        case .accounting: "분개"
        case .playbooks: "절차"
        case .health: "건강"
        case .spatial: "3D"
        }
    }
}

private struct RecordsPages: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeNSView(context: Context) -> RecordsPageHost { RecordsPageHost() }

    func updateNSView(_ host: RecordsPageHost, context: Context) {
        host.select(state.tab) { tab in
            WorkbenchHostingView(rootView: RecordsPage(tab: tab).environmentObject(state))
        }
    }
}

/// Each child has a permanent tab identity. Only the host's visibility changes on navigation.
private struct RecordsPage: View {
    @EnvironmentObject private var state: AppState
    let tab: AppState.Tab

    var body: some View {
        Group {
            switch tab {
            case .timeline: TimelineView()
            case .evidence: EvidenceView()
            case .accounting: AccountingView()
            case .spatial: SpatialAssetsView()
            case .playbooks: PlaybooksView()
            case .health: HealthView()
            }
        }
        .environment(\.recordsPageIsActive, state.recordsPageVisible && state.tab == tab)
        .ppomiTheme()
    }
}

/// Lazy native page cache keeps the actual WKWebView DOM, native selection, and scroll state alive.
final class RecordsPageHost: WorkbenchSurface {
    private var pages: [AppState.Tab: NSView] = [:]

    func select(_ tab: AppState.Tab, makePage: (AppState.Tab) -> NSView) {
        if pages[tab] == nil {
            let page = makePage(tab)
            page.identifier = NSUserInterfaceItemIdentifier("records-page-\(tab.rawValue)")
            pages[tab] = page
            addSubview(page)
        }
        for (key, page) in pages {
            if key != tab, let responder = window?.firstResponder as? NSView,
               responder.isDescendant(of: page) { window?.makeFirstResponder(nil) }
            page.isHidden = key != tab
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for page in pages.values where page.superview === self { page.frame = bounds }
    }
}
