// 절차 페이지(Web/playbooks.html): 카탈로그 전부를 계정과목표처럼 한 나무로 — 자리(Catalog/categories.json: 공공은 부문 › 부처 › 기관, 앱은 분류) › 패키지 › 기능 —
// 그 아래 고른 패키지의 명세 나무(Web/playbook.js) + 판정 장부(✓△✗) + 발자국 그래프. 데이터 모양은 Storybook 과 같아 뷰 코드는 하나다.
import Foundation

enum PlaybooksPage {
    private struct Pkg: Encodable {
        var id, name, path, target, version: String
        var manifest: PlaybookManifest; var verification: VerificationSummary; var footprints: [Footprint]
        var guide: String; var humanSteps: [String]; var openable: Bool
    }
    private struct Data: Encodable { var packages: [Pkg] }

    static func html(_ entries: [PlaybookEntry], categories: [String: String] = PlaybookCatalog.categories(), dir: URL = Playbooks.dir) -> String {
        let pkgs = entries.map { e -> Pkg in
            let launch = e.record.manifest.launch
            return Pkg(id: e.id, name: e.record.name, path: categories[e.id] ?? "기타", target: launch.isBrowser ? "Mac 브라우저" : launch.isWindows ? "Windows" : "폰",
                       version: e.record.manifest.version, manifest: e.record.manifest, verification: VerificationStore.summary(e.record, in: dir), footprints: e.footprints,
                       guide: e.record.guideText, humanSteps: e.record.manifest.humanSteps, openable: launch.browserURL != nil || launch.windowsURL != nil)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try! enc.encode(Data(packages: pkgs)), as: UTF8.self)   // "/" is escaped: no "</script>" can leak
        return Web.page("playbooks").replacingOccurrences(of: "/*PLAYBOOK_JS*/", with: Web.file("playbook", "js") + "\n" + Web.file("facts", "js"))
            .replacingOccurrences(of: "/*PLAYBOOKS*/null", with: json)
    }
}

extension PlaybookCatalog {
    /// 계정과목표: 패키지 → 자리. 없으면 '기타'.
    static func categories() -> [String: String] {
        guard let url = bundledDirectory?.appendingPathComponent("categories.json"), let data = try? Foundation.Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map.filter { $0.key != "_" }
    }
}
