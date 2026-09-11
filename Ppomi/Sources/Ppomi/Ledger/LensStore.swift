// 계좌 그룹(렌즈)과 판: 그룹은 이름 + 그 안의 계좌(잔액표 라벨) + 격자 위 자리, 그룹 밖 계좌 노드도 자리를 가진다. 계좌는 그룹 하나에만 속하고
// 어디에도 없으면 미분류(판 위에 떠 있음). "내 것 전부"는 늘 모든 계좌. 파일 lenses.json 은 ledger.db 옆; 서버엔 ledger 기록(SharedLedgerArchive)에 실려
// 가서 아이패드도 같은 판을 본다.
import Foundation

enum LensStore {
    /// 늘 있는 가계부(개인) 상자. 실체 상자에 안 든 계좌는 전부 여기. 이름이 같은 사용자 그룹은 읽을 때 지운다(그 계좌들은 가계부 미분류로).
    static let home = "가계부"
    static let entity = "entity"
    struct File: Codable { var lenses: [Lens] = []; var nodes: [String: [Int]] = [:] }
    static func url(dbPath: String) -> URL {
        URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("lenses.json")
    }
    static func read(dbPath: String) -> File {
        guard let data = try? Data(contentsOf: url(dbPath: dbPath)) else { return File() }
        var file = (try? JSONDecoder().decode(File.self, from: data))
            ?? File(lenses: (try? JSONDecoder().decode([Lens].self, from: data)) ?? [])     // 첫 판: 그룹 배열만 있던 파일
        file.lenses.removeAll { $0.name == home }                                            // 가계부는 상자가 아니라 바닥
        var seen = Set<String>()                                                             // 손으로 고친 파일이 겹쳐도 계좌는 첫 그룹에만
        for i in file.lenses.indices { file.lenses[i].inside.subtract(seen); seen.formUnion(file.lenses[i].inside) }
        return file
    }
    static func load(dbPath: String) -> [Lens] { read(dbPath: dbPath).lenses }
    static func nodes(dbPath: String) -> [String: [Int]] { read(dbPath: dbPath).nodes }
    static func save(_ file: File, dbPath: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url(dbPath: dbPath), options: .atomic)
    }
    static func save(_ lenses: [Lens], dbPath: String) throws {
        var file = read(dbPath: dbPath); file.lenses = lenses; try save(file, dbPath: dbPath)
    }
    /// 새 그룹. 이름이 비었거나 이미 있으면(기본 렌즈 이름 포함) 그대로.
    static func add(name: String, kind: String? = nil, dbPath: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var file = read(dbPath: dbPath)
        guard !name.isEmpty, name.count <= 40, name != LegacyAccountingRules.bundled.defaultLensName, name != home, !file.lenses.contains(where: { $0.name == name }) else { return }
        file.lenses.append(Lens(name: name, inside: [], kind: kind == entity ? entity : nil))
        try save(file, dbPath: dbPath)
    }
    /// 계좌를 그룹 하나에 넣는다(다른 그룹에서는 뺀다). nil = 미분류; 그때 자리를 주면 판 위 그 자리에 뜬다.
    static func assign(account: String, to name: String?, at place: (x: Int, y: Int)? = nil, dbPath: String) throws {
        var file = read(dbPath: dbPath)
        for i in file.lenses.indices { file.lenses[i].inside.remove(account) }
        if let name, let i = file.lenses.firstIndex(where: { $0.name == name }) { file.lenses[i].inside.insert(account); file.nodes[account] = nil }
        else if let place { file.nodes[account] = [max(0, place.x), max(0, place.y)] }
        try save(file, dbPath: dbPath)
    }
    /// 그룹 상자를 판 위 다른 자리로. 실체 칸으로 끌면 실체가 되고(kind "entity"), 가계부 안으로 끌면 그룹으로 돌아온다.
    static func move(lens name: String, x: Int, y: Int, kind: String? = nil, dbPath: String) throws {
        var file = read(dbPath: dbPath)
        guard let i = file.lenses.firstIndex(where: { $0.name == name }) else { return }
        file.lenses[i].x = max(0, x); file.lenses[i].y = max(0, y); file.lenses[i].kind = kind == entity ? entity : nil
        try save(file, dbPath: dbPath)
    }
}
