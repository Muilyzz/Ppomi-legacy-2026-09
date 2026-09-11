// The hands without a network: the SMS parser against am.py over test_am.py's samples, the permission gate, the ring's
// question/answer handshake through the state table, and the small tables (later, reminders, facts) on a temp db.
import XCTest
@testable import Ppomi

final class ServeTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("sms-parity.json")

    func testSMSParityWithPython() throws {
        guard let d = try? Data(contentsOf: Self.fixture) else { throw XCTSkip("no sms-parity.json") }
        let samples = try JSONSerialization.jsonObject(with: d) as! [[String: Any]]
        let now = TS.parse("2026-09-02 13:00")!
        for s in samples {
            let got = SMS.parse(s["text"] as! String, when: now), name = s["name"] as! String
            guard let want = s["parsed"] as? [String: Any] else { XCTAssertNil(got, name); continue }
            guard let got else { XCTFail("\(name): nil, want \(want)"); continue }
            XCTAssertEqual(got.ts, want["ts"] as? String, name); XCTAssertEqual(got.kind, want["kind"] as? String, name)
            XCTAssertEqual(got.amount, want["amount"] as? Int, name); XCTAssertEqual(got.merchant, want["merchant"] as? String, name)
            XCTAssertEqual(got.card, want["card"] as? String, name); XCTAssertEqual(got.cumulative, want["cumulative"] as? Int, name)
        }
    }

    func testGate() {
        XCTAssertTrue(Tools.consented("응 잠겨있어")); XCTAssertTrue(Tools.consented("폰으로 여기어때 열어서 가격 봐줘")); XCTAssertTrue(Tools.consented("ok"))
        XCTAssertFalse(Tools.consented("오늘 얼마 썼어?")); XCTAssertFalse(Tools.consented("타니베이 얼마야"))
    }

    func testMirroringUnlockOverlay() {
        XCTAssertTrue(Phone.needsUnlock(shot(["iPhone 잠금 해제", "연결"])))
        XCTAssertFalse(Phone.needsUnlock(shot(["숙소 상세", "모든 객실 보기"])))
        XCTAssertFalse(Phone.needsUnlock(shot([])))
        XCTAssertFalse(Phone.needsUnlock(shot(["iPhone 잠금 해제 방법 안내"])))
    }

    func testPayGate() throws {
        XCTAssertTrue(Tools.isPayWord("결제하기")); XCTAssertTrue(Tools.isPayWord("406,600원 결제")); XCTAssertTrue(Tools.isPayWord("주문 완료")); XCTAssertFalse(Tools.isPayWord("예약하기")); XCTAssertFalse(Tools.isPayWord("확인")); XCTAssertFalse(Tools.isPayWord("총 결제 금액 406,600원")); XCTAssertFalse(Tools.isPayWord("할인 및 결제 정보")); XCTAssertFalse(Tools.isPayWord("바로구매")); XCTAssertTrue(Tools.isPayWord("구매하기"))
        let path = NSTemporaryDirectory() + "ppomi-pay-\(UUID().uuidString)/ledger.db"
        let t = try Tools(db: try DB(path: path, writable: true))
        t.currentText = "응 잠겨있어"
        XCTAssertTrue(t.execute("confirm_payment", ["summary": "x", "amount": 1000, "method": "y"]).contains("승인 채널이 없다"))
        var asked: String? = nil
        t.askOwner = { html, opts in asked = html; return opts.last }                      // the owner presses 취소
        XCTAssertTrue(t.execute("confirm_payment", ["summary": "x", "amount": 1000, "method": "y"]).contains("취소"))
        XCTAssertTrue(asked!.contains("1,000원")); XCTAssertNil(t.approval)
        t.askOwner = { _, opts in opts.first }                                             // the owner approves
        XCTAssertTrue(t.execute("confirm_payment", ["summary": "x", "amount": 1000, "method": "y"]).contains("승인했다"))
        XCTAssertEqual(t.approval?.amount, 1000)
        XCTAssertTrue(t.execute("record_spend", ["merchant": "여기어때", "amount": 398000, "memo": "예약번호 1"]).hasPrefix("적어뒀다"))
        XCTAssertEqual(try t.db.scalar("SELECT status FROM transactions WHERE source='agent:ppomi'") as? String, "pending")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func testPayPreference() throws {
        let path = NSTemporaryDirectory() + "ppomi-pref-\(UUID().uuidString)/ledger.db"
        let db = try DB(path: path, writable: true)
        let t = try Tools(db: db)
        for (i, m) in ["쿠팡이츠", "APPLE", "이디야커피"].enumerated() {
            try db.insertTransaction(OCR.Tx(ts: TS.string(KST.day(KST.today, -i)), kind: "approval", amount: 1000 * (i + 1), merchant: m, card: "체크카드", cumulative: 0, uid: "u\(i)", rows: 0...0), app: "KAKAO")
        }
        try db.setState("installed:페이코", "0")
        XCTAssertTrue(t.payPreference().contains("토스: 미확인")) // A catalog entry alone never proves installation.
        try db.setState("installed:toss", "1")
        let p = t.payPreference()
        XCTAssertTrue(p.contains("카카오뱅크 체크카드: 3건 6,000원"), p)
        XCTAssertTrue(p.contains("토스: 설치됨") && p.contains("페이코: 미설치") && p.contains("네이버: 미확인"), p)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func testLaterRemindFacts() throws {
        let path = NSTemporaryDirectory() + "ppomi-serve-\(UUID().uuidString)/ledger.db"
        let t = try Tools(db: try DB(path: path, writable: true))
        XCTAssertTrue(t.laterAdd("김영희 회비 답장 #돈").contains("김영희"))
        XCTAssertTrue(t.laterList().contains("회비 답장 #돈"))
        XCTAssertTrue(t.laterDone("김영희").contains("✅"))
        XCTAssertEqual(t.laterList(), "미루고 있는 대화 없음 👍")
        XCTAssertTrue(t.remindAdd(at: "2030-01-01 09:00", text: "x").hasPrefix("01/01 09:00"))
        XCTAssertTrue(t.remember("테스트").hasPrefix("기억했어요")); XCTAssertEqual(t.facts().count, 1)
        XCTAssertEqual(t.forgetFact(1), "지웠어요.")
        XCTAssertEqual(t.sqlText("DELETE FROM facts"), "read-only: SELECT/WITH/EXPLAIN only")
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Another process asks through the state table; the console polls it onto state.ask and a button answers.
    @MainActor func testAskViaDBAnsweredByRingButton() throws {
        let path = NSTemporaryDirectory() + "ppomi-dbask-\(UUID().uuidString)/ledger.db"
        let other = try DB(path: path, writable: true)
        let s = AppState(); s.watchAsks(dbPath: path)
        var got: String? = "unset"
        let done = expectation(description: "answered"), shown = expectation(description: "shown")
        Thread.detachNewThread { got = Tools.askViaDB(other, "💳 <b>결제?</b>\n1,000원", ["결제 승인 1,000원", "취소"], timeout: 10); done.fulfill() }
        Thread.sleep(forTimeInterval: 0.3)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in shown.fulfill() }
        wait(for: [shown], timeout: 5)                                       // the run loop turns: the 1.5 s poll fires
        let q = try XCTUnwrap(s.ask)
        XCTAssertEqual(q.text, "💳 결제? · 1,000원"); XCTAssertEqual(q.options, ["결제 승인 1,000원", "취소"])
        XCTAssertEqual(s.phase, .humanTurn(reason: "승인 대기 · 작업대 하단 버튼"))
        s.answer("취소")
        XCTAssertNil(s.ask); XCTAssertEqual(s.phase, .idle)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, "취소"); XCTAssertNil(Tools.pendingQuestion(other))
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    // ---------------------------------------------------------------- 소뇌 through the tools, on a fake phone
    func shot(_ texts: [String]) -> [OCR.Word] { texts.enumerated().map { .init(x: 0.1, y: Double($0) / 10, w: 0.3, h: 0.02, text: $1) } }
    /// Tools on a temp ledger, consent given, footprints in a temp dir; the fake phone is set by the test (screens in order, the last repeats).
    func fakeTools() throws -> (Tools, String) {
        let path = NSTemporaryDirectory() + "ppomi-fp-\(UUID().uuidString)/ledger.db"
        let t = try Tools(db: try DB(path: path, writable: true))
        t.footprintDir = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("playbooks")
        t.currentText = "해줘"; t.currentApp = "여기어때"
        return (t, path)
    }

    func testTapLeavesAFootprintButNeverAPayTarget() throws {
        var screens = [["숙소 상세", "모든 객실 보기", "취소"], ["객실 목록", "예약하기"]], hands: [[String]] = []
        let (t, path) = try fakeTools()
        Tools.fake = (screen: { screens.count > 1 ? self.shot(screens.removeFirst()) : self.shot(screens[0]) }, hand: { hands.append($0) })
        defer { Tools.fake = nil; try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertEqual(t.execute("phone_tap", ["text": "모든 객실"]), "탭했다. phone_screen 으로 결과를 확인하라.")   // the brain sees nothing new
        var fps = FootprintStore.load("여기어때", in: t.footprintDir)
        XCTAssertEqual(fps.count, 1); XCTAssertEqual(fps[0].glyph, "⊙"); XCTAssertEqual(fps[0].target, "모든 객실"); XCTAssertEqual(fps[0].source, "brain")
        XCTAssertEqual(fps[0].fingerprintBefore, ["숙소", "상세", "모든", "객실", "보기", "취소"]); XCTAssertEqual(fps[0].fingerprintAfter, ["객실", "목록", "예약하기"])
        XCTAssertEqual(hands, [["tap", "모든 객실 보기"]])
        // a pay button is blocked before approval; a regex that names a pay word is tapped (it landed on 결제금액) but never written
        screens = [["최종 결제금액", "결제하기", "취소"]]
        XCTAssertTrue(t.execute("phone_tap", ["text": "결제하기"]).contains("confirm_payment"))
        XCTAssertTrue(t.execute("phone_tap", ["text": "결제|취소"]).hasPrefix("탭했다"))
        XCTAssertTrue(t.execute("phone_tap", ["x": 0.5, "y": 0.5]).hasPrefix("탭했다"))                    // no target: nothing to replay
        XCTAssertTrue(t.execute("phone_type", ["text": "010-1234-5678"]).hasPrefix("입력했다"))             // digits: never a target
        XCTAssertEqual(FootprintStore.load("여기어때", in: t.footprintDir).count, 1)
        // the same step on the same screen again: verified once more, not a second line
        screens = [["숙소 상세", "모든 객실 보기", "취소"], ["객실 목록", "예약하기"]]
        XCTAssertTrue(t.execute("phone_tap", ["text": "모든 객실"]).hasPrefix("탭했다"))
        fps = FootprintStore.load("여기어때", in: t.footprintDir)
        XCTAssertEqual(fps.count, 1); XCTAssertEqual(fps[0].verified.ok, 1)
        // scroll then tap is one ↓ step from the screen before the scroll
        screens = [["객실 목록", "예약하기"], ["아래쪽", "필수 동의"], ["약관", "동의 완료"]]
        _ = t.execute("phone_screen", [:]); XCTAssertEqual(t.execute("phone_scroll", ["dy": -430]), "스크롤했다.")
        XCTAssertTrue(t.execute("phone_tap", ["text": "필수"]).hasPrefix("탭했다"))
        fps = FootprintStore.load("여기어때", in: t.footprintDir)
        XCTAssertEqual(fps.last?.glyph, "↓"); XCTAssertEqual(fps.last?.fingerprintBefore, ["객실", "목록", "예약하기"]); XCTAssertEqual(fps.last?.fingerprintAfter, ["약관", "동의", "완료"])
    }

    func testRunComboWalksKnownStepsAndReportsTheRest() throws {
        var screens = [["숙소 상세", "모든 객실 보기"], ["객실 목록", "예약하기"]], hands: [[String]] = []
        let (t, path) = try fakeTools()
        Tools.fake = (screen: { screens.count > 1 ? self.shot(screens.removeFirst()) : self.shot(screens[0]) }, hand: { hands.append($0) })
        defer { Tools.fake = nil; try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertTrue(t.execute("run_combo", ["app": "없는앱"]).hasPrefix("아는 길 없음: 없는앱"))
        t.currentApp = nil; XCTAssertTrue(t.execute("run_combo", [:]).hasPrefix("앱 이름이 없다"))
        try FootprintStore.append("여기어때", Footprint(app: "여기어때", glyph: "⊙", target: "모든 객실", fingerprintBefore: ["숙소", "상세", "모든", "객실", "보기"], fingerprintAfter: ["객실", "목록", "예약하기"]), in: t.footprintDir)
        try FootprintStore.append("여기어때", Footprint(app: "여기어때", glyph: "⊙", target: "결제하기", fingerprintBefore: ["객실", "목록", "예약하기"], fingerprintAfter: ["완료"]), in: t.footprintDir)
        let out = t.execute("run_combo", ["app": "여기어때"])
        XCTAssertTrue(out.hasPrefix("⊙ 모든 객실 ✓\n멈춤: 승인 필요 지점 — 다음 걸음 ⊙결제하기 (confirm_payment 승인 뒤 phone_tap)\n0.01  객실 목록\n0.11  예약하기"), out)
        XCTAssertEqual(hands, [["tap", "모든 객실 보기"]])                                             // the pay step was never taken
        XCTAssertEqual(FootprintStore.load("여기어때", in: t.footprintDir).map(\.verified.ok), [1, 0])
        XCTAssertEqual(t.currentApp, "여기어때")
    }
}
