// 증빙·전표: the evidence column (Web/evidence.html) fed by what this app computed from data/shots — parse, register, mark —
// with no report.py in between. The workbench window and the kiosk's left band show the same page. {timeline:1} from the page = '← 타임라인'.
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
        let sub = "생성 \(TS.string(Date())) · 거래 \(inDB.count)건"
        let json = String(data: try! JSONEncoder().encode(Page(sub: sub, apps: apps)), encoding: .utf8)!   // "/" is escaped, so no "</script>" can leak
        let tpl = Web.page("evidence")
        return tpl.replacingOccurrences(of: "/*EVIDENCE*/null", with: json)
    }
}

/// The one workbench: tabs over the timeline, 증빙 or the playbooks. The window shows it at its own width, the kiosk's left
/// band at the band's — same view, one UI, dark in both.
struct Workbench: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("작업 화면")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Picker("작업 화면", selection: Binding(get: { state.workSurface }, set: { state.selectSurface($0) })) {
                    ForEach(WorkSurface.allCases) { surface in
                        Label(surface.displayName, systemImage: surface.symbolName).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("work-surface-picker")
                .disabled(state.ask != nil)
                .frame(maxWidth: 240)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            HStack(spacing: 32) {
                HStack(spacing: 12) { tab("타임라인", .timeline); tab("증빙·전표", .evidence) }
                tab("절차", .playbooks)
                Spacer()
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
            Group {
                switch state.tab {
                case .playbooks: PlaybooksView()
                case .evidence: EvidenceView()
                case .timeline: TimelineView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func tab(_ title: String, _ t: AppState.Tab) -> some View {
        let on = state.tab == t
        return Button(title) { state.show(t) }
            .foregroundStyle(on ? Color(white: 0.9) : Color(white: 0.54))
            .overlay(alignment: .bottom) { Rectangle().fill(.white).frame(height: 1).offset(y: 3).opacity(on ? 1 : 0) }
    }
}

struct EvidenceView: View {
    @EnvironmentObject var state: AppState
    @State private var html: String? = nil

    var body: some View {
        Group {
            if let html {
                WebPage(html: html, focus: state.evidenceFocus?.uid.map { Column.evidID($0) },
                        onMessage: { m in if (m as? [String: Any])?["timeline"] != nil { state.tab = .timeline } })   // '← 타임라인'
            }
            else { ProgressView("스크린샷 읽는 중…") }
        }
        .onAppear { if html == nil { rebuild() } }
        .onChange(of: state.ledgerVersion) { _, _ in rebuild() }
    }

    private func rebuild() {
        DispatchQueue.global(qos: .userInitiated).async {
            let h = Evidence.html()
            DispatchQueue.main.async { html = h }
        }
    }
}
