import XCTest
@testable import Ppomi

final class LensStoreTests: XCTestCase {
    func testGroupsAreExclusiveAndSurviveReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("ledger.db").path
        XCTAssertEqual(LensStore.load(dbPath: db), [])
        try LensStore.add(name: " 생활비 ", dbPath: db); try LensStore.add(name: "생활비", dbPath: db); try LensStore.add(name: "  ", dbPath: db)
        try LensStore.add(name: "사업", dbPath: db); try LensStore.add(name: LegacyAccountingRules.bundled.defaultLensName, dbPath: db)   // 기본 렌즈 이름은 못 쓴다
        try LensStore.add(name: LensStore.home, dbPath: db)                                                                   // 가계부는 바닥이라 상자로 못 만든다
        try LensStore.assign(account: "a", to: "생활비", dbPath: db)
        try LensStore.assign(account: "a", to: "사업", dbPath: db)          // 한 그룹에만
        try LensStore.assign(account: "b", to: "없는 그룹", dbPath: db)     // = 가계부 미분류
        XCTAssertEqual(LensStore.load(dbPath: db), [Lens(name: "생활비", inside: []), Lens(name: "사업", inside: ["a"])])
        try LensStore.assign(account: "a", to: nil, at: (x: 3, y: -2), dbPath: db)         // 판 위로: 자리를 갖는다(음수는 0)
        XCTAssertEqual(LensStore.load(dbPath: db).flatMap(\.inside), []); XCTAssertEqual(LensStore.nodes(dbPath: db), ["a": [3, 0]])
        try LensStore.assign(account: "a", to: "사업", dbPath: db); XCTAssertEqual(LensStore.nodes(dbPath: db), [:], "상자에 들어가면 판 자리는 지운다")
        try LensStore.move(lens: "사업", x: 7, y: 1, dbPath: db); try LensStore.move(lens: "없는 그룹", x: 1, y: 1, dbPath: db)
        XCTAssertEqual(LensStore.load(dbPath: db).map { [$0.x, $0.y] }, [[nil, nil], [7, 1]])
        try LensStore.add(name: "법인", kind: "entity", dbPath: db)                                                            // 실체
        XCTAssertEqual(LensStore.load(dbPath: db).map { $0.name + ":" + ($0.kind ?? "-") }, ["생활비:-", "사업:-", "법인:entity"])
        try LensStore.move(lens: "사업", x: 30, y: 2, kind: "entity", dbPath: db); try LensStore.move(lens: "법인", x: 1, y: 1, kind: nil, dbPath: db)   // 실체 칸으로 / 가계부 안으로
        XCTAssertEqual(LensStore.load(dbPath: db).map { $0.kind ?? "-" }, ["-", "entity", "-"])
        try Data(#"[{"name":"옛 그룹","inside":["z","y"]},{"name":"겹침","inside":["z"]},{"name":"가계부","inside":["q"]}]"#.utf8).write(to: LensStore.url(dbPath: db))   // 첫 판 파일: 배열만, 손으로 겹치게, 가계부 이름
        XCTAssertEqual(LensStore.load(dbPath: db), [Lens(name: "옛 그룹", inside: ["z", "y"]), Lens(name: "겹침", inside: [])], "가계부 이름의 상자는 읽을 때 사라진다"); XCTAssertEqual(LensStore.nodes(dbPath: db), [:])
        XCTAssertEqual(try JSONDecoder().decode(SharedLedgerArchive.self, from: Data(#"{"formatVersion":1,"snapshots":[],"transactions":[],"me":"","originalTables":"e30="}"#.utf8)).lenses, nil, "옛 기록엔 그룹이 없다")
    }
}
