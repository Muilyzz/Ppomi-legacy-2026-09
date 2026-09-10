import XCTest
@testable import Ppomi

final class VoiceApprovalTests: XCTestCase {
    let options = ["승인", "취소"]
    func testApprovalWordPicksApproveOption() {
        XCTAssertEqual(VoiceApproval.option(for: "네 승인이요", among: options), "승인")
        XCTAssertEqual(VoiceApproval.option(for: "취소해 줘", among: options), "취소")
    }
    func testAmbiguousOrWeakWordsPickNothing() {
        XCTAssertNil(VoiceApproval.option(for: "승인 말고 취소", among: options))
        XCTAssertNil(VoiceApproval.option(for: "네", among: options))
        XCTAssertNil(VoiceApproval.option(for: "여보세요", among: options))
    }
    func testOnlyOptionsThatExistCanBePicked() {
        XCTAssertNil(VoiceApproval.option(for: "승인", among: ["A 객실", "B 객실"]))
        XCTAssertEqual(VoiceApproval.option(for: "승인", among: ["예, 진행", "아니오"]), "예, 진행")
    }
}
