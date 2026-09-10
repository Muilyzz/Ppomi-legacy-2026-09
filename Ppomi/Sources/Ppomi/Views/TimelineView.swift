// 타임라인: the net-worth step line, the accounting equation per day, and the selected day's balance sheets and journal —
// Web/timeline.html (report.py's TIMELINE_JS as it was) fed by the ledger this app read; the workbench's first tab.
import SwiftUI

enum Timeline {
    /// The live view keeps this document while its ledger data changes.
    static let template = Web.page("timeline")
    /// The page's data in the shape report.py timeline_data made (Tests/timeline-parity.json), plus uid per line.
    static func data(_ L: Ledger) -> [String: Any] { LedgerPage.timelineData(L) }

    static func html(_ L: Ledger) -> String {
        template.replacingOccurrences(of: "/*TIMELINE*/null", with: json(L))
    }

    static func updateScript(_ ledger: Ledger) -> String {
        "updateTimeline(\(json(ledger)));"
    }

    private static func json(_ ledger: Ledger) -> String {
        // Sorted keys make unchanged data a no-op; escaped slashes also keep standalone HTML safe.
        String(decoding: try! JSONSerialization.data(withJSONObject: data(ledger), options: .sortedKeys), as: UTF8.self)
    }

    /// The page posts its initial day after loading. An unchanged day must not invalidate the page again.
    @MainActor static func receive(_ message: Any, state: AppState) {
        guard let message = message as? [String: Any] else { return }
        let day = (message["day"] as? String).flatMap { TS.parse($0 + " 00:00") }
        if let day, state.selectedDay != day { state.selectedDay = day }
        if let uid = message["evidence"] as? String {
            state.showEvidence(day: day, uid: uid)
        }
    }
}

struct TimelineView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.recordsPageIsActive) private var isActive
    @State private var updateScript: String?
    @State private var renderedVersion: Int?

    var body: some View {
        Group {
            if let updateScript {
                WebPage(html: Timeline.template, updateScript: updateScript, onMessage: { message in
                    if isActive { Timeline.receive(message, state: state) }
                })
            }
            else {
                ContentUnavailableView(state.ledgerError == nil ? "장부 없음 · 설정에서 경로 확인" : "장부를 읽지 못함",
                                       systemImage: "book.closed", description: Text(state.ledgerError ?? AppSettings.dbPath))
            }
        }
        .onAppear { activate() }
        .onChange(of: isActive) { _, _ in activate() }
        .onChange(of: state.ledgerVersion) { _, _ in if isActive { rebuild() } }
    }

    private func activate() {
        guard isActive else { return }
        if state.ledger == nil { state.reloadLedger() }
        rebuild()
    }

    /// Update the existing document's values; the page owns its selected range, day, and scroll position.
    private func rebuild() {
        guard renderedVersion != state.ledgerVersion else { return }
        updateScript = state.ledger.map(Timeline.updateScript)
        renderedVersion = state.ledgerVersion
    }
}
