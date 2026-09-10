// KB 기업 인증서 발급/재발급 1단계의 사업자등록번호 세 칸: 주소·행 앵커·상자 셋이 증명될 때만, 요청한 칸 안에서만, 숫자키로만 입력한다.
import XCTest
@testable import Ppomi

final class KBCertificateFormFillerTests: XCTestCase {
    private func word(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.015) -> OCR.Word { OCR.Word(x: x, y: y, w: w, h: h, text: text) }
    // Observed empty form (2026-09-10) plus the box words and empty markers the pixel pass adds. Every value below is synthetic.
    private var page: [OCR.Word] {
        [word("https://obank.kbstar.com/quics?page=C019623#loading", 0.0858, 0.1102, 0.2805, 0.0175),
         word("사용자 본인확인", 0.3459, 0.3607, 0.0756, 0.0194),
         word("ID를 모르시는 경우다", 0.5407, 0.4016, 0.0756, 0.0155),
         word("사용자 ID", 0.3561, 0.4124, 0.0349, 0.0132),
         word("인증서를 사용할 Master 또는 Sub의 ID 입력하세요. (ID조회는 Master만 가능합니다.)", 0.4651, 0.4254, 0.2747, 0.0131),
         word("사업자등록번호", 0.3561, 0.46, 0.0538, 0.0131),
         word("(납세번호/고유번호)", 0.3547, 0.4795, 0.0727, 0.013),
         word("V 마우스로 입력", 0.6366, 0.5161, 0.0625, 0.0152),
         word("i 개인사업자만 입력", 0.7006, 0.5184, 0.0858, 0.0151),
         word("주민등록번호", 0.3561, 0.5269, 0.0465, 0.0153),
         word("i 숫자만 입력하실 수 있으며, 붙여넣기는 지원되지 않습니다.", 0.4535, 0.54, 0.2049, 0.0151)]
    }
    private let boxes: [(Double, Double)] = [(0.446, 0.040), (0.492, 0.037), (0.536, 0.039)]
    private var boxWords: [OCR.Word] { boxes.enumerated().map { word(KBCertificateFormGeometry.boxPrefix + "\($0.offset + 1)__", $0.element.0, 0.466, $0.element.1, 0.021) } }
    private var markers: [OCR.Word] { boxes.enumerated().map { BusinessFormGeometry.emptyMarker(segment: $0.offset + 1, x: $0.element.0 + $0.element.1 / 2, y: 0.4763) } }
    private var base: [OCR.Word] { page + boxWords + markers }
    private func target(_ segment: Int, x: Double? = nil, y: Double = 0.476) -> ProfileFormFiller.Target {
        .init(field: .businessRegistrationNumber, x: x ?? [0.466, 0.5105, 0.5555][segment - 1], y: y, form: .kbCertificate, segment: segment)
    }
    private let profile = IdentityProfile(name: "합성 이름", businessName: "합성 상호", businessRegistrationNumber: "123-45-67890")
    private func json(_ s: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
    private func neverTypes(_ words: [OCR.Word], target: ProfileFormFiller.Target, line: UInt = #line) {
        let filler = ProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("must not click", line: line) }, key: { _ in XCTFail("must not send keys", line: line) },
                                       type: { _ in XCTFail("must not send identity", line: line) }, typeDigits: { _ in XCTFail("must not send digits", line: line) },
                                       inputFocus: { _ in XCTFail("must not inspect focus", line: line); return false }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: target), line: line)
    }

    func testRequestAcceptsOnlyBusinessNumberSegmentsWithoutBankID() throws {
        let t = try ProfileFormFiller.request(["form": "kb_certificate_identity", "field": "business_registration_number", "segment": 2, "x": 0.51, "y": 0.476])
        XCTAssertEqual(t.form, .kbCertificate); XCTAssertEqual(t.segment, 2); XCTAssertNil(t.bankID)
        XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_certificate_identity", "field": "business_registration_number", "x": 0.51, "y": 0.476]))
        XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_certificate_identity", "field": "birth_date", "x": 0.51, "y": 0.476]))
        XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_certificate_identity", "field": "business_registration_number", "segment": 1, "bank_id": "kb", "x": 0.51, "y": 0.476]))
    }

    func testObservedPageAcceptsEachBoxAndReturnsItsRegion() throws {
        for s in 1...3 {
            let r = try KBCertificateFormGeometry.region(base, target: target(s))
            XCTAssertEqual(r.minX, boxes[s - 1].0, accuracy: 0.001); XCTAssertEqual(r.width, boxes[s - 1].1, accuracy: 0.001)
            XCTAssertNoThrow(try ProfileFormFiller.validate(base, target: target(s)))
        }
    }

    func testToleratesObservedOCRVariantsOfTheAddressAndLabel() throws {
        // A second window size read the zero as O and put a period after the label (2026-09-10).
        let variant = base.map { w -> OCR.Word in
            var v = w
            if v.text.hasPrefix("https://obank") { v.text = "https://obank.kbstar.com/quics?page=CO19623#loading" }
            if v.text == "사업자등록번호" { v.text = "사업자등록번호." }
            return v
        }
        XCTAssertNoThrow(try ProfileFormFiller.validate(variant, target: target(1)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(variant.map { var v = $0; if v.text.hasPrefix("https://obank") { v.text = "https://obank.kbstar.com/quics?page=CO19624#loading" }; return v }, target: target(1)))
    }

    func testRejectsOtherPageRowGapCredentialDialogAndMissingEvidence() {
        func swap(_ old: String, _ new: String) -> [OCR.Word] { base.map { var w = $0; if w.text == old { w.text = new }; return w } }
        neverTypes(swap("https://obank.kbstar.com/quics?page=C019623#loading", "https://obiz.kbstar.com/quics?page=C019750&QSL=F"), target: target(1))   // the ID-lookup popup
        neverTypes(swap("https://obank.kbstar.com/quics?page=C019623#loading", "https://obank.kbstar.com/quics?page=C019623&evil=1"), target: target(1))
        neverTypes(base, target: target(1, y: 0.535))       // the 주민등록번호 row below
        neverTypes(base, target: target(2, x: 0.489))       // the gap between box 1 and box 2
        neverTypes(base, target: target(1, x: 0.5105))      // segment 1 requested at box 2
        neverTypes(base + [word("인증서 암호", 0.5, 0.6, 0.05)], target: target(1))
        neverTypes(base.filter { $0.text != KBCertificateFormGeometry.boxPrefix + "3__" }, target: target(1))
        neverTypes(base.filter { $0.text != "(납세번호/고유번호)" }, target: target(1))
        neverTypes(base.filter { $0.text != "주민등록번호" }, target: target(1))
    }

    func testFillsOneSegmentWithDigitKeysAndVerifiesItInsideItsBox() throws {
        for (s, digits) in [(1, "123"), (2, "45"), (3, "67890")] {
            var calls = 0, typed: [String] = [], clicks = 0
            let after = base + [word(digits, boxes[s - 1].0 + 0.006, 0.469, 0.02)]
            let filler = ProfileFormFiller(screen: { calls += 1; return calls >= 3 ? after : self.base }, click: { _, _ in clicks += 1 },
                                           key: { _ in XCTFail("digits go through the private digit driver") }, type: { _ in XCTFail("no text typing") },
                                           typeDigits: { typed.append($0) }, inputFocus: { _ in true }, settle: {})
            let result = try filler.fill(profile, target: target(s))
            XCTAssertEqual(typed, [digits]); XCTAssertEqual(clicks, 1)
            XCTAssertEqual(try json(result)["verified"] as? Bool, true, result); XCTAssertFalse(result.contains(digits))
        }
    }

    func testWithoutEmptyEvidenceNothingIsTypedAndAFilledBoxIsReportedAsFilled() throws {
        let noMarkers = page + boxWords
        let filler = ProfileFormFiller(screen: { noMarkers }, click: { _, _ in XCTFail("must not click") }, key: { _ in }, type: { _ in XCTFail() },
                                       typeDigits: { _ in XCTFail("must not type into an unproven box") }, inputFocus: { _ in false }, settle: {})
        XCTAssertEqual(try json(try filler.fill(profile, target: target(1)))["input_attempted"] as? Bool, false)
        let filled = base + [word("123", 0.452, 0.469, 0.02)]
        let done = ProfileFormFiller(screen: { filled }, click: { _, _ in XCTFail() }, key: { _ in }, type: { _ in XCTFail() }, typeDigits: { _ in XCTFail() }, inputFocus: { _ in false }, settle: {})
        XCTAssertEqual(try json(try done.fill(profile, target: target(1)))["already_filled"] as? Bool, true)
    }
}
