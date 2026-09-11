// Timeline.data against report.py timeline_data over the same ledger.db (timeline-parity.json).
import XCTest
@testable import Ppomi

final class TimelineTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("timeline-parity.json")

    func testParityWithPython() throws {
        guard FileManager.default.fileExists(atPath: LedgerTests.dbPath), !LedgerTests.me.isEmpty, let d = try? Data(contentsOf: Self.fixture)
        else { throw XCTSkip("no ledger.db, STYLE_ME or timeline-parity.json") }
        let want = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        var got = Timeline.data(try Ledger.load(dbPath: LedgerTests.dbPath, me: LedgerTests.me))
        ["defaultLens", "lenses", "lens", "nodes"].forEach { got.removeValue(forKey: $0) }   // 계좌 그룹은 우리 것, report.py 에 없다
        let show = { (x: Any) in String(data: try! JSONSerialization.data(withJSONObject: x, options: .sortedKeys), encoding: .utf8)! }
        XCTAssertEqual(show(got["accounts"]!), show(want["accounts"]!))
        XCTAssertEqual(show(got["series"]!), show(want["series"]!))
        XCTAssertEqual(Set(got["inside"] as! [String]), Set(want["inside"] as! [String]))
        let strip = { (l: Any) -> Any in var l = l as! [String: Any]; l["uid"] = nil; return l }   // uid is ours, for the 증빙 link
        XCTAssertEqual(show((got["lines"] as! [Any]).map(strip)), show(want["lines"]!))
    }
}
