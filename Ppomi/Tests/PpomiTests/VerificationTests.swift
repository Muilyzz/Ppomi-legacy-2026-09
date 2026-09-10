// 검증 장부: 판정은 명세에 있는 단계·세 낱말만 받고, 같은 버전에서는 마지막 판정이 이기며, 다른 버전의 판정은 stale 로만 센다.
import XCTest
@testable import Ppomi

final class VerificationTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("catalog/sample"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func record(version: String = "0.1.0") throws -> PlaybookRecord {
        let m = PlaybookManifest(id: "sample", name: "새 앱", version: version, aliases: [], launch: .init(search: "sample"), capabilities: [
            .init(id: "browse", title: "조회", description: "조회 절차", inputs: [], steps: [.init(id: "open", title: "▶앱", kind: "open"), .init(id: "read", title: "📝읽기", kind: "read")]),
            .init(id: "pay", title: "결제", description: "결제 절차", inputs: [], steps: [.init(id: "open", title: "▶앱", kind: "open"), .init(id: "confirm", title: "✋승인", kind: "human")]),
        ], humanSteps: [], guide: "guide.md")
        let dir = temporary.appendingPathComponent("catalog/sample")
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        try "# 안내\n".write(to: dir.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PlaybookCatalog.load(in: temporary, includeBundled: false).first)
    }

    func testJudgeAcceptsOnlyManifestStepsAndThreeOutcomes() throws {
        let r = try record()
        XCTAssertThrowsError(try VerificationStore.judge(r, capability: "nope", step: "open", outcome: "ok")) { XCTAssertTrue($0.localizedDescription.contains("browse, pay")) }
        XCTAssertThrowsError(try VerificationStore.judge(r, capability: "browse", step: "nope", outcome: "ok")) { XCTAssertTrue($0.localizedDescription.contains("open, read")) }
        XCTAssertThrowsError(try VerificationStore.judge(r, capability: "browse", step: "open", outcome: "maybe"))
        let v = try VerificationStore.judge(r, capability: "browse", step: "read", outcome: "changed", actual: "화면 읽기", note: " ")
        XCTAssertEqual([v.app, v.version, v.key, v.outcome, v.actual ?? "", v.by], ["sample", "0.1.0", "browse/read", "changed", "화면 읽기", "agent"])
        XCTAssertNil(v.note)   // a blank note is no note
    }

    func testSummaryCountsTheLatestJudgementPerStepForThisVersionOnly() throws {
        let r = try record()
        XCTAssertEqual(VerificationStore.summary(r, in: temporary), .init(version: "0.1.0", total: 4, unverified: 4))
        try VerificationStore.append(try VerificationStore.judge(r, capability: "browse", step: "open", outcome: "ok"), in: temporary)
        try VerificationStore.append(try VerificationStore.judge(r, capability: "browse", step: "read", outcome: "fail", note: "팝업"), in: temporary)
        try VerificationStore.append(try VerificationStore.judge(r, capability: "browse", step: "read", outcome: "changed", actual: "내역 보기"), in: temporary)   // the later line wins
        var old = try VerificationStore.judge(r, capability: "pay", step: "confirm", outcome: "ok"); old.version = "0.0.9"
        try VerificationStore.append(old, in: temporary)                                                                                       // another version: stale, not verified
        let s = VerificationStore.summary(r, in: temporary)
        XCTAssertEqual([s.total, s.ok, s.changed, s.fail, s.unverified, s.stale], [4, 1, 1, 0, 2, 1])
        XCTAssertEqual(s.steps["browse/read"]?.actual, "내역 보기")
        XCTAssertEqual(s.last, s.steps["browse/read"]?.at)
        XCTAssertEqual(VerificationStore.load("sample", in: temporary).count, 4)                     // the file keeps every judgement, in order
        XCTAssertEqual(VerificationStore.url("sample", in: temporary).lastPathComponent, "sample.verify.jsonl")
        let s2 = VerificationStore.summary(try record(version: "0.2.0"), in: temporary)              // a new version starts unverified; old judgements are stale
        XCTAssertEqual([s2.unverified, s2.stale, s2.ok], [4, 3, 0])
    }
}
