// The cerebellum on fake screens: fingerprints drop amounts/times, Jaccard at its edges, replay walks two steps and stops
// on the third, hands pay taps and the person's turn back, never repeats a step, and the store round-trips.
import XCTest
@testable import Ppomi

final class FootprintsTests: XCTestCase {
    func w(_ t: String, _ y: Double) -> OCR.Word { .init(x: 0.1, y: y, w: 0.3, h: 0.02, text: t) }
    func fp(_ glyph: String, _ target: String, _ before: [String], _ after: [String], ok: Int = 0) -> Footprint {
        Footprint(app: "여기어때", glyph: glyph, target: target, fingerprintBefore: before, fingerprintAfter: after, verified: .init(ok: ok, fail: 0))
    }

    func testFingerprintDropsNumbersAndKeepsOrder() {
        let words = [w("406,600원 결제하기", 0.9), w("10:53 m", 0.05), w("숙소 상세", 0.12), w("2026년 9월 5일", 0.3),
                     w("• 모든 객실 보기.", 0.5), w("×", 0.12), w("숙소", 0.7), w("객실", 0.55), w("길동님 고객님", 0.8)]
        XCTAssertEqual(Fingerprint.words(from: words), ["숙소", "상세", "모든", "객실", "보기", "고객님", "결제하기"])
        XCTAssertEqual(Fingerprint.words(from: (0..<20).map { w("단어\(Character(UnicodeScalar(0xAC00 + $0)!))", Double($0) / 20) }).count, 8)
    }

    func testSimilarityEdges() {
        XCTAssertEqual(Fingerprint.similarity(["a", "b"], ["b", "a"]), 1)
        XCTAssertEqual(Fingerprint.similarity(["a"], ["b"]), 0)
        XCTAssertEqual(Fingerprint.similarity([], []), 0)
        XCTAssertEqual(Fingerprint.similarity(["a", "b", "c"], ["a", "b", "d"]), 0.5)
        XCTAssertLessThan(Fingerprint.similarity(["a", "b", "c"], ["a", "d", "e"]), Fingerprint.threshold)
    }

    func testPayTargetCoversToolsPayWord() {
        for s in ["406,600원 결제하기", "송금", "이체하기", "충전 완료", "구독 진행", "결제|취소", "모든 객실 보기", "예약 조회"] {
            if Tools.isPayWord(s) { XCTAssertTrue(Footprint.isPayTarget(s), s) }
        }
        XCTAssertTrue(Footprint.isPayTarget("결제|취소")); XCTAssertFalse(Footprint.isPayTarget("모든 객실 보기")); XCTAssertFalse(Footprint.isPayTarget("바로구매"))
        XCTAssertEqual(fp("⊙", "결제하기", [], []).handoff, "승인 필요 지점")
        XCTAssertEqual(fp("⌨", "송금", [], []).handoff, nil)
        XCTAssertEqual(fp("👤", "", [], []).handoff, "사용자 차례")
        XCTAssertEqual(fp("✋", "", [], []).handoff, "승인 필요 지점")
        XCTAssertEqual(fp("🔍", "", [], []).handoff, "두뇌 판단")
        XCTAssertNotNil(Phone.find([w("예약(", 0.1)], "예약("))          // a target that is not a valid regex is taken literally, never a crash
    }

    /// Screens as word lists; `run` walks A then B, and C's promised screen never comes.
    func replay(_ fps: [Footprint], _ screens: [[String]]) throws -> (Replay.Result, [String]) {
        var i = 0, acted: [String] = []
        let r = try Replay(footprints: fps,
                           screen: { defer { i += 1 }; return screens[min(i, screens.count - 1)].enumerated().map { self.w($1, Double($0) / 10) } },
                           act: { acted.append($0.target) }, wait: { _ in }).run(maxSteps: 10)
        return (r, acted)
    }

    func testReplayWalksThenStopsOnUnexpectedScreen() throws {
        let a = fp("▶", "여기어때", ["홈", "숙소", "검색"], ["숙소", "상세", "객실"])
        let b = fp("⊙", "모든 객실 보기", ["숙소", "상세", "객실"], ["객실", "목록", "예약하기"])
        let c = fp("↓", "예약하기", ["객실", "목록", "예약하기"], ["결제수단", "쿠폰", "최종"])
        let (r, acted) = try replay([c, b, a], [["홈", "숙소", "검색"], ["숙소", "상세", "객실", "요금"], ["객실", "목록", "예약하기"], ["오류", "네트워크"]])
        XCTAssertEqual(acted, ["여기어때", "모든 객실 보기", "예약하기"])
        XCTAssertEqual(r.steps.map(\.ok), [true, true, false])
        XCTAssertEqual(r.outcome, .stopped("화면이 예상과 다름"))
        XCTAssertEqual(r.lastWords.map(\.text), ["오류", "네트워크"])
    }

    func testReplayHandsOffBeforePayTap() throws {
        let pay = fp("⊙", "결제하기", ["최종", "결제금액", "결제하기"], ["완료"])
        let dot = fp("⊙", ".", ["최종", "결제금액", "결제하기"], ["완료"], ok: 9)      // regex hits the pay button though its text does not say so
        let (r, acted) = try replay([pay, dot], [["최종", "결제금액", "결제하기"]])
        XCTAssertEqual(acted, [])
        XCTAssertEqual(r.outcome, .handoff("승인 필요 지점", at: dot))
        let human = fp("👤", "", ["Face", "ID"], [])
        XCTAssertEqual(try replay([human], [["Face", "ID"]]).0.outcome, .handoff("사용자 차례", at: human))
        XCTAssertEqual(try replay([human], [["처음", "보는", "화면"]]).0.outcome, .stopped("아는 화면이 아님"))
    }

    func testReplayNeverRepeatsAStepAndPrefersVerified() throws {
        let same = fp("⊙", "더보기", ["목록", "더보기"], ["목록", "더보기"])           // screen unchanged after the tap
        let (r, acted) = try replay([same], [["목록", "더보기"]])
        XCTAssertEqual(acted, ["더보기"]); XCTAssertEqual(r.outcome, .done)
        let weak = fp("⊙", "약한", ["목록", "더보기"], ["상세", "화면"]), strong = fp("⊙", "센", ["목록", "더보기"], ["상세", "화면"], ok: 3)
        XCTAssertEqual(try replay([weak, strong], [["목록", "더보기"], ["상세", "화면"]]).1, ["센"])
    }

    func testStoreAppendLoadBump() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        XCTAssertEqual(FootprintStore.load("여기어때", in: dir), [])
        let a = fp("▶", "여기어때", ["홈"], ["숙소"]), b = fp("⊙", "숙소", ["숙소"], ["상세"])
        try FootprintStore.append("여기어때", a, in: dir); try FootprintStore.append("여기어때", b, in: dir)
        XCTAssertEqual(FootprintStore.load("여기어때", in: dir), [a, b])
        XCTAssertEqual(FootprintStore.url("여기어때", in: dir).lastPathComponent, "여기어때.jsonl")
        try FootprintStore.bump("여기어때", id: b.id, ok: true, in: dir); try FootprintStore.bump("여기어때", id: b.id, ok: false, in: dir)
        try FootprintStore.bump("여기어때", id: "없는", ok: true, in: dir)
        XCTAssertEqual(FootprintStore.load("여기어때", in: dir).map(\.verified), [.init(ok: 0, fail: 0), .init(ok: 1, fail: 1)])
        XCTAssertEqual(try String(contentsOf: FootprintStore.url("여기어때", in: dir), encoding: .utf8).split(separator: "\n").count, 2)
        try? FileManager.default.removeItem(at: dir)
    }
}
