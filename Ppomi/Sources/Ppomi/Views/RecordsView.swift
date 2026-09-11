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

/// 기록 페이지: it replaces the whole workspace. Header row = "← 대화" + the tabs; body = the tab's page.
struct RecordsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if state.recordsFocused {   // 제어 열 안의 상태 뷰일 땐 대화가 옆에 있으니 돌아갈 곳이 없다
                    Button("← 대화", action: state.toggleRecordsFocus)
                        .buttonStyle(.plain)
                        .font(.ppomi(2, weight: .medium))
                        .help("Esc")
                        .accessibilityLabel("대화로 돌아가기")
                        .accessibilityIdentifier("records-back")
                }
                RecordsNavigation(selection: state.tab, select: state.show)   // 첫 화면은 타임라인의 재무 트리맵; 절차(플레이북 나무)를 보려면 탭이 필요해 다시 보인다 (2026-09-11)
                if let message = state.recordsFocusMessage {
                    Text(message).font(.ppomi(1)).foregroundStyle(.bad).lineLimit(1)
                        .accessibilityIdentifier("records-focus-message")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: WorkbenchLayout.toolbarHeight)
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
        Picker("기록 보기", selection: Binding(get: { selection }, set: select)) {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
                    .accessibilityIdentifier("records-tab-\(tab.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.ppomiSmall)
        .font(.ppomi(2))
        .frame(maxWidth: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("기록 보기")
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
        .environment(\.recordsPageIsActive, (state.recordsFocused || state.recordsOnScreen) && state.tab == tab)   // 평상시 제어 열의 상태 뷰도 살아 있는 페이지
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
