// 증빙·전표: the evidence column (Web/evidence.html) fed by what this app computed from data/shots — parse, register, mark —
// with no report.py in between. The records area in either window mode shows the same page. {timeline:1} from the page = '← 타임라인'.
import SwiftUI
import AppKit

/// Which day's 전표 to show, and optionally which voucher to select.
struct EvidenceFocus: Equatable {
    var day: Date
    var uid: String?
}

enum Evidence {
    private struct Page: Encodable { var sub: String; var apps: [AppColumn] }
    private struct AppColumn: Encodable { var app, title, account, col: String; var frames, placed, ok, bad: Int }

    /// The whole page as HTML: template + the data as JSON. Heavy (every frame is parsed and JPEG-encoded); call off the main thread.
    static func html(dbPath: String = AppSettings.dbPath) -> String {
        let shots = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("shots")
        let inDB = Set((try? DB(path: dbPath).transactions().map(\.uid)) ?? [])
        var apps: [AppColumn] = []
        for app in OCR.listMarkers.keys.sorted() {
            var frames = Stitch.loadFrames(app: app, shots: shots)
            if frames.isEmpty { continue }
            let placed = Stitch.place(&frames, app: app)
            let b = Column.build(app: app, placed: placed, frames: frames, inDB: inDB)
            apps.append(AppColumn(app: app, title: Rules.title(app), account: Rules.account[app]?.name ?? app, col: b.html,
                                  frames: frames.count, placed: placed.count, ok: b.drawn, bad: b.anomalies))
        }
        let sub = "거래 \(inDB.count)건 · 화면용 증빙 · 원본 파일은 수집한 Mac에 보관"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(Page(sub: sub, apps: apps)), encoding: .utf8)!   // "/" is escaped, so no "</script>" can leak
        let tpl = Web.page("evidence")
        return tpl.replacingOccurrences(of: "/*EVIDENCE*/null", with: json)
    }
}

struct EvidenceView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.recordsPageIsActive) private var isActive
    @State private var html: String? = nil
    @State private var renderedVersion: Int?
    @State private var error: String?

    var body: some View {
        Group {
            if let html {
                WebPage(html: html, focus: state.evidenceFocus?.uid.map { Column.evidID($0) },
                        onMessage: { m in if (m as? [String: Any])?["timeline"] != nil { state.tab = .timeline } })   // '← 타임라인'
            }
            else if let error { Text(error).foregroundStyle(.fg2) }
            else { ProgressView("증빙 읽는 중…") }
        }
        .task(id: isActive ? state.ledgerVersion : nil) { await rebuild() }
    }

    private func rebuild() async {
        guard isActive, renderedVersion != state.ledgerVersion else { return }
        let version = state.ledgerVersion, path = AppSettings.dbPath
        let rendered = await Task.detached(priority: .userInitiated) { Result { try SharedRecordsSource.evidence(path: path) } }.value
        guard !Task.isCancelled else { return }
        switch rendered {
        case .success(let value): html = value; renderedVersion = version; error = nil
        case .failure: error = "확인된 서버 증빙을 읽지 못했습니다."
        }
    }
}
