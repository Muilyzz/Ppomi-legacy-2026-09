// 은행정보 수집: 계좌번호는 정확히 하나여야 하고, 예금주명은 라벨 뒤나 바로 윗줄의 이름꼴 낱말 하나만 받으며, 응답에 원문이 없다.
import XCTest
@testable import Ppomi

final class BankProfileCaptureTests: XCTestCase {
    private func w(_ t: String, _ x: Double, _ y: Double, _ wd: Double = 0.2, _ h: Double = 0.02) -> OCR.Word { OCR.Word(x: x, y: y, w: wd, h: h, text: t) }

    func testFindsOneAccountAndTheHolderAfterTheLabelOrAbove() throws {
        let labelled = [w("계좌조회", 0.1, 0.1), w("예금주 합성상회", 0.1, 0.30), w("123456-04-123456", 0.1, 0.35), w("잔액 1,000원", 0.1, 0.40)]
        XCTAssertEqual(try BankProfileCapture.find(labelled), .init(customerName: "합성상회", accountNumber: "12345604123456"))
        let split = [w("예금주", 0.1, 0.30, 0.08), w("김합성", 0.25, 0.30, 0.1), w("계좌번호 1234-56-789012", 0.1, 0.35)]
        XCTAssertEqual(try BankProfileCapture.find(split), .init(customerName: "김합성", accountNumber: "123456789012"))
        let above = [w("합성 R&D", 0.1, 0.30), w("123456-04-123456", 0.1, 0.34), w("잔액", 0.1, 0.40)]
        XCTAssertEqual(try BankProfileCapture.find(above).customerName, nil)   // "&" 는 이름꼴이 아니다: 모르면 nil
        let plain = [w("합성상회", 0.1, 0.30), w("123456-04-123456", 0.1, 0.34)]
        XCTAssertEqual(try BankProfileCapture.find(plain).customerName, "합성상회")
    }

    func testRefusesZeroOrSeveralAccountsAndAmbiguousNames() {
        XCTAssertThrowsError(try BankProfileCapture.find([w("계좌조회", 0.1, 0.1), w("잔액 12,345원", 0.1, 0.3)]))
        XCTAssertThrowsError(try BankProfileCapture.find([w("123456-04-123456", 0.1, 0.3), w("654321-04-654321", 0.1, 0.5)]))
        let two = [w("합성상회", 0.1, 0.30), w("김합성", 0.5, 0.30), w("123456-04-123456", 0.1, 0.34)]
        XCTAssertNil(try BankProfileCapture.find(two).customerName)
    }

    func testCaptureStoresIntoTheKeychainProfileAndReturnsOnlyFlags() throws {
        var entries: [String: Data] = [:]
        let store = IdentityProfileStore(storage: .init(all: { entries.map { .init(account: $0.key, data: $0.value) } }, read: { entries[$0] },
                                                        write: { entries[$0] = $1 }, remove: { entries.removeValue(forKey: $0) }))
        let out = try BankProfileCapture.capture(profileID: "self", bankID: "kb", store: store) { [self.w("예금주 합성상회", 0.1, 0.3), self.w("123456-04-123456", 0.1, 0.35)] }
        XCTAssertFalse(out.contains("123456")); XCTAssertFalse(out.contains("합성상회"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual((json["registered"] as? [String: Bool])?["account_number"], true)
        XCTAssertEqual(json["account_tail"] as? String, "3456")
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles?["kb"]?.accountNumber, "12345604123456")
        XCTAssertThrowsError(try BankProfileCapture.capture(profileID: "self", bankID: "other", store: store) { [] })
    }
}
