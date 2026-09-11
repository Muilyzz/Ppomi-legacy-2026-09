// 타임라인 페이지 데이터: report.py timeline_data 의 모양(Tests/timeline-parity.json) + 줄마다 uid. Mac(Views/TimelineView)과 아이패드가 같은 함수로 같은 페이지를 만든다.
import Foundation

enum LedgerPage {
    static func timelineData(_ L: Ledger) -> [String: Any] {
        ["accounts": L.accounts.map { ["id": $0.id, "app": $0.title] },
         "series": L.series.mapValues { $0.map { [TS.string($0.ts), $0.value, $0.how.rawValue] as [Any] } },
         "inside": Array(L.defaultLens.inside).sorted(),
         "lines": L.lines.map { ["ts": TS.string($0.ts), "memo": $0.memo, "dr": $0.dr, "cr": $0.cr, "amount": $0.amount, "rev": $0.rev, "uid": $0.uid] },
         "defaultLens": L.defaultLens.name,
         "lenses": L.lenses.map { l -> [String: Any] in
             var d: [String: Any] = ["name": l.name, "inside": Array(l.inside).sorted()]
             if let x = l.x, let y = l.y { d["x"] = x; d["y"] = y }
              return d },
         "home": Lens.home,
         "invest": L.accounts.filter { Rules.investApps.contains($0.app) }.map(\.id).sorted(),   // 증권: 자산 › 투자
         "business": L.accounts.filter { Rules.isBusiness(app: $0.app, label: $0.id) }.map(\.id).sorted(),   // 사업자 계좌(사실): 기업뱅킹에서 읽었거나 이름이 사업자
         "nodes": L.nodes,
         "lens": UserDefaults.standard.string(forKey: "timelineLens") ?? L.defaultLens.name]   // 마지막으로 보던 그룹
    }
    /// Web/timeline.html 의 /*TIMELINE*/null 자리에 데이터를 넣은 한 장.
    static func timelineHTML(template: String, ledger: Ledger) -> String {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: timelineData(ledger), options: .sortedKeys), as: UTF8.self)
        return template.replacingOccurrences(of: "/*TIMELINE*/null", with: json)
    }
}
