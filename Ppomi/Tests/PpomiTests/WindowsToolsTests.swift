// The Windows (Parallels) hands through the tools, on a fake screen: the gate, the pay guard, and what each tool hands down.
import XCTest
@testable import Ppomi

final class WindowsToolsTests: XCTestCase {
    private var path = ""

    override func tearDown() {
        Tools.fake = nil
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Rows start below the browser chrome band (y > 0.2) that windows_scroll ignores when judging movement.
    private func shot(_ texts: [String]) -> [OCR.Word] { texts.enumerated().map { .init(x: 0.1, y: 0.3 + Double($0) / 10, w: 0.3, h: 0.02, text: $1) } }

    private func tools(screens: [[String]], hands: @escaping ([String]) -> Void) throws -> Tools {
        path = NSTemporaryDirectory() + "ppomi-win-\(UUID().uuidString)/ledger.db"
        let t = try Tools(db: try DB(path: path, writable: true))
        t.footprintDir = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("playbooks")
        t.currentText = "해줘"
        var queue = screens
        Tools.fake = (screen: { queue.count > 1 ? self.shot(queue.removeFirst()) : self.shot(queue[0]) }, hand: hands)
        return t
    }

    func testScreenClickTypeKeyOpenHandDownToTheWindowsDriver() throws {
        var hands: [[String]] = []
        let t = try tools(screens: [["인터넷등기소", "열람·발급", "등기소 소개"]], hands: { hands.append($0) })
        XCTAssertEqual(t.execute("windows_screen", [:]), "0.31  인터넷등기소\n0.41  열람·발급\n0.51  등기소 소개")   // row centres
        XCTAssertEqual(t.execute("windows_click", ["text": "등기소 소개"]), "클릭했다. windows_screen 으로 결과를 확인하라.")
        XCTAssertEqual(t.execute("windows_click", ["text": "없는 글자"]), "화면에 '없는 글자'가 없다")
        XCTAssertTrue(t.execute("windows_click", ["x": 0.5, "y": 0.5]).hasPrefix("클릭했다"))
        XCTAssertTrue(t.execute("windows_type", ["text": "서울특별시 강남구"]).hasPrefix("입력했다"))
        XCTAssertEqual(t.execute("windows_key", ["name": "ctrl+l"]), "보냈다.")
        XCTAssertTrue(t.execute("windows_open", ["target": "https://www.iros.go.kr/"]).hasPrefix("열었다"))
        XCTAssertTrue(t.execute("windows_open", [:]).hasPrefix("오류"))
        XCTAssertEqual(hands, [["click", "등기소 소개"], ["click"], ["type", "서울특별시 강남구"], ["key", "ctrl+l"], ["open", "https://www.iros.go.kr/"]])
    }

    func testPayButtonNeedsAnApprovalAndScrollReportsWhetherTheScreenMoved() throws {
        var hands: [[String]] = []
        let t = try tools(screens: [["열람 수수료 700원", "결제하기", "취소"]], hands: { hands.append($0) })
        XCTAssertTrue(t.execute("windows_click", ["text": "결제하기"]).contains("confirm_payment"))
        XCTAssertTrue(t.execute("windows_click", ["x": 0.2, "y": 0.41]).contains("confirm_payment"))   // the coordinate sits on the pay row
        XCTAssertEqual(hands, [])
        // the same screen after a scroll: not moved; a different one: moved, with the new rows
        _ = t.execute("windows_screen", [:])
        XCTAssertTrue(t.execute("windows_scroll", ["dy": -600]).hasPrefix("화면이 안 움직였다"))
        let moving = try tools(screens: [["표제부", "갑구"], ["을구", "근저당권설정"]], hands: { _ in })
        _ = moving.execute("windows_screen", [:])
        XCTAssertEqual(moving.execute("windows_scroll", ["dy": -600]), "스크롤했다.\n0.31  을구\n0.41  근저당권설정")
        // browser chrome (tab strip, address bar) is the same before and after; only the page body tells
        let chrome = (0..<9).map { OCR.Word(x: 0.1 * Double($0), y: 0.05, w: 0.05, h: 0.02, text: "탭\($0)") }
        var frames = [chrome + [OCR.Word(x: 0.1, y: 0.5, w: 0.3, h: 0.02, text: "공지사항")], chrome + [OCR.Word(x: 0.1, y: 0.5, w: 0.3, h: 0.02, text: "등기소 소개")]]
        let paged = try tools(screens: [[]], hands: { _ in })
        Tools.fake = (screen: { frames.count > 1 ? frames.removeFirst() : frames[0] }, hand: { _ in })
        _ = paged.execute("windows_screen", [:])
        XCTAssertTrue(paged.execute("windows_scroll", ["dy": -600]).hasPrefix("스크롤했다"))
    }

    func testGateNeedsConsentPermissionsAndAWindowInWindowMode() throws {
        let t = try tools(screens: [["홈"]], hands: { _ in XCTFail("no hand without consent") })
        t.currentText = "오늘 얼마 썼어?"
        XCTAssertTrue(t.execute("windows_screen", [:]).hasPrefix("실행 안 함"))
        t.currentText = "등기소 가서 읽어줘"
        t.windowsGateStatus = { (permissions: false, state: "READY") }
        XCTAssertTrue(t.execute("windows_click", ["text": "홈"]).contains("권한"))
        t.windowsGateStatus = { (permissions: true, state: "NONE") }
        XCTAssertTrue(t.execute("windows_type", ["text": "x"]).contains("창 모드"))
        t.windowsGateStatus = { (permissions: true, state: "READY") }
        XCTAssertEqual(t.execute("windows_screen", [:]), "0.31  홈")
    }

    /// Synthetic geometry based on the observed F01 card layout; contains no account or identity information.
    private func memberTypes() -> [OCR.Word] {
        func word(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> OCR.Word {
            .init(x: x, y: y, w: width, h: height, text: text)
        }
        // Public F01 text and geometry observed on 2026-09-09; no account or session data.
        return [word("a https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01", 0.1046, 0.1216, 0.4507, 0.0244),
                word("건축행정시스템", 0.4113, 0.3033, 0.1962, 0.0349), word("세움터에 오신 것을 환영합니다.", 0.3038, 0.3489, 0.4128, 0.0429),
                word("개인사용자", 0.1381, 0.6555, 0.0843, 0.0207), word("사업자(개인 및 법인)", 0.4331, 0.6556, 0.1541, 0.0222),
                word("일반회원", 0.1221, 0.6885, 0.1163, 0.0350), word("사업자회원", 0.4360, 0.6884, 0.1455, 0.0356),
                word("가입하기", 0.1482, 0.7833, 0.0626, 0.0210), word("가입하기", 0.4767, 0.7852, 0.0640, 0.0190),
                word("건축행정시스템", 0.0174, 0.2464, 0.0683, 0.0129)]
    }

    func testObservedEaisMemberTypeNavigationNeedsNoPaymentApproval() throws {
        var hands: [[String]] = []
        let t = try tools(screens: [[]], hands: { hands.append($0) })
        let words = memberTypes()
        Tools.fake = (screen: { words }, hand: { hands.append($0) })
        XCTAssertTrue(Tools.isPayWord("가입하기"), "the shared protected-word boundary is unchanged")
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("사업자회원 가입 경로 버튼을 눌렀다"))
        XCTAssertTrue(t.execute("windows_click", ["x": 0.26, "y": 0.7925]).contains("일반회원 가입 경로 버튼을 눌렀다"))
        XCTAssertEqual(hands, [["click", "가입하기"], ["click", "가입하기"]])
        XCTAssertNil(t.approval, "navigation neither creates nor needs a payment approval")
        hands = []
        XCTAssertTrue(t.execute("windows_click", ["text": "가입하기"]).contains("여러 개"))
        XCTAssertTrue(t.execute("windows_click", ["text": "가입하기", "x": "0.55", "y": "0.79"]).contains("여러 개"))
        XCTAssertTrue(t.execute("windows_click", ["text": "가입하기", "x": NSNull(), "y": NSNull()]).contains("여러 개"))
        XCTAssertTrue(hands.isEmpty, "identical type-choice labels must not select the first member type")
        XCTAssertTrue(t.execute("phone_tap", ["text": "가입하기"]).contains("confirm_payment"))
        XCTAssertTrue(hands.isEmpty, "Windows navigation evidence does not weaken the phone guard")
    }

    func testMemberTypeNavigationRejectsOtherURLsAndMissingAddressEvidence() throws {
        var hands: [[String]] = [], frame = memberTypes()
        let t = try tools(screens: [[]], hands: { hands.append($0) })
        Tools.fake = (screen: { frame }, hand: { hands.append($0) })
        let invalid = ["arbitrary https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01",
                       "a https://www.eais.go.kr.evil.invalid/moct/awp/aba01/AWPABA01F01",
                       "a https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F02",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F05",
                       "https://www.eais.go.kr.evil.invalid/moct/awp/aba01/AWPABA01F01",
                       "https://evil.invalid/?next=https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01",
                       "http://www.eais.go.kr/moct/awp/aba01/AWPABA01F01",
                       "https://user@www.eais.go.kr/moct/awp/aba01/AWPABA01F01",
                       "https://www.eais.go.kr:444/moct/awp/aba01/AWPABA01F01",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01/extra",
                       "https://www.eais.go.kr/moct/awp/aba01/%41WPABA01F01",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01#other",
                       "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F01?next=payment"]
        for url in invalid {
            frame = memberTypes(); frame[0].text = url
            XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), url)
        }
        frame = memberTypes(); frame.removeFirst()
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"))
        frame = memberTypes(); frame[0].y = 0.45
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), "a URL in the page body is not address evidence")
        XCTAssertTrue(hands.isEmpty)
    }

    func testMemberTypeNavigationRejectsIncompleteAmbiguousOrFinalizationScreens() throws {
        var hands: [[String]] = [], frame = memberTypes()
        let t = try tools(screens: [[]], hands: { hands.append($0) })
        Tools.fake = (screen: { frame }, hand: { hands.append($0) })
        for missing in 1...7 {
            frame = memberTypes(); frame.remove(at: missing)
            XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), "missing card evidence \(missing)")
        }
        frame = memberTypes(); frame.append(frame[6])
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), "duplicate member-type evidence")
        frame = memberTypes(); frame[6].x = 0.20
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), "the clicked button must be in the identified card column")
        for protected in ["결제하기", "가입완료", "구독 가입하기"] {
            frame = memberTypes(); frame[8].text = protected
            XCTAssertTrue(t.execute("windows_click", ["text": protected]).contains("confirm_payment"), protected)
            XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), protected)
        }
        frame = memberTypes(); frame.append(.init(x: 0.4, y: 0.85, w: 0.15, h: 0.025, text: "회원정보 입력"))
        XCTAssertTrue(t.execute("windows_click", ["x": 0.55, "y": 0.7925]).contains("confirm_payment"), "a later form cannot reuse stale card labels")
        XCTAssertTrue(hands.isEmpty)
    }

    func testBundledIrosPlaybookOpensItsURL() throws {
        var hands: [[String]] = []
        let t = try tools(screens: [["홈"]], hands: { hands.append($0) })
        // A temp playbooks dir sees no bundled packages: install the bundled iros package into it, as the kiosk import does.
        let bundled = try XCTUnwrap(PlaybookCatalog.bundledDirectory).appendingPathComponent("iros")
        _ = try PlaybookCatalog.install(from: bundled, in: t.footprintDir)
        XCTAssertTrue(t.execute("windows_open", ["app": "등기소"]).hasPrefix("열었다"))
        XCTAssertEqual(hands, [["open", "https://www.iros.go.kr/"]])
        XCTAssertNil(t.currentApp, "a desk playbook never becomes the phone footprint recorder's app")
    }
}
