import XCTest
@testable import Ppomi

final class KBProfileFormFillerTests: XCTestCase {
    private func word(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.02) -> OCR.Word {
        OCR.Word(x: x, y: y, w: w, h: h, text: text)
    }

    // The observed empty popup geometry; all entered identity values below are synthetic.
    private var base: [OCR.Word] {
        [word("a https://obank.kbstar.com/quics?page=C019623#loading", 0.1047, 0.1216, 0.4549, 0.0221),
         word("a https://obiz.kbstar.com/quics?page=C019750&QSL=F&cc=b028364%3....", 0.1991, 0.2132, 0.5814, 0.0207),
         word("ID조회", 0.2108, 0.2654, 0.0683, 0.0254),
         word("조회구분", 0.2296, 0.5828, 0.0611, 0.0192),
         // OCR cannot reliably tell which radio circle is filled. The selected form's birthday row is required.
         word("• 법인사업자 O 개인사업자", 0.3895, 0.5842, 0.1962, 0.0194),
         word("고객명", 0.2297, 0.6430, 0.0465, 0.0190),
         word("i) 출금계좌(통장)의 고객명 입력", 0.4055, 0.6588, 0.2064, 0.0190),
         word("생년월일", 0.2296, 0.7201, 0.0612, 0.0194),
         word("예:1981년 2월 1일일 경우 810201", 0.4259, 0.7393, 0.2078, 0.0174),
         word("출금계좌번호", 0.2296, 0.7847, 0.0903, 0.0198),
         word("출금계좌비밀번호", 0.2297, 0.8341, 0.1221, 0.0208),
         word("마우스로 입력", 0.5305, 0.8356, 0.0916, 0.0175),
         word("확인", 0.4840, 0.9098, 0.0305, 0.0176),
         word("주민등록번호", 0.83, 0.72, 0.12)]
    }
    private var profile: IdentityProfile {
        IdentityProfile(name: "다른 개인명", birthDate: "1981-02-01", businessName: "다른 상호",
                        bankProfiles: ["kb": .init(customerName: "합성통장고객", accountNumber: "000-123 456789"),
                                       "other": .init(customerName: "다른은행고객", accountNumber: "999987654321")])
    }
    private func target(_ field: ProfileFormFiller.Field = .bankCustomerName) -> ProfileFormFiller.Target {
        let point: (Double, Double) = field == .birthDate ? (0.475, 0.716) : field == .bankAccountNumber ? (0.52, 0.795) : (0.476, 0.638)
        return .init(field: field, x: point.0, y: point.1, form: .kbIDLookup, bankID: "kb")
    }
    private func replacing(_ old: String, with new: String, in words: [OCR.Word]? = nil) -> [OCR.Word] {
        (words ?? base).map { var word = $0; if word.text == old { word.text = new }; return word }
    }
    private func neverTypes(_ words: [OCR.Word], target: ProfileFormFiller.Target? = nil) {
        let filler = ProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("must not click") },
            key: { _ in XCTFail("must not send keys") }, type: { _ in XCTFail("must not send identity") },
            inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: target ?? self.target()))
    }

    func testRequestRequiresExplicitKBBankAndSeparatesAllForms() throws {
        for field in ["bank_customer_name", "birth_date", "bank_account_number"] {
            let request = try ProfileFormFiller.request(["form": "kb_id_lookup", "bank_id": "kb", "field": field, "x": 0.476, "y": 0.638])
            XCTAssertEqual(request.bankID, "kb"); XCTAssertEqual(request.form, .kbIDLookup); XCTAssertNil(request.segment)
        }
        for bank: Any in [NSNull(), "", "KB", "other", true] {
            XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_id_lookup", "bank_id": bank, "field": "bank_customer_name", "x": 0.476, "y": 0.638]))
        }
        XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_id_lookup", "field": "bank_customer_name", "x": 0.476, "y": 0.638]))
        for field in ["name", "phone", "carrier", "business_name", "business_registration_number", "password", "bank_account_password"] {
            XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_id_lookup", "bank_id": "kb", "field": field, "x": 0.476, "y": 0.638]))
        }
        for form in ["eais_pass", "eais_business"] {
            for field in ["bank_customer_name", "bank_account_number"] {
                XCTAssertThrowsError(try ProfileFormFiller.request(["form": form, "field": field, "x": 0.476, "y": 0.638]))
            }
            let field = form == "eais_pass" ? "name" : "business_name"
            XCTAssertThrowsError(try ProfileFormFiller.request(["form": form, "bank_id": "kb", "field": field, "x": 0.476, "y": 0.638]))
        }
        XCTAssertThrowsError(try ProfileFormFiller.request(["form": "kb_id_lookup", "bank_id": "kb", "field": "bank_customer_name", "segment": 1, "x": 0.476, "y": 0.638]))
    }

    func testObservedIndividualPopupAcceptsThreeRowsAndIgnoresBackgroundIssuanceLabels() throws {
        for field: ProfileFormFiller.Field in [.bankCustomerName, .birthDate, .bankAccountNumber] {
            XCTAssertNoThrow(try ProfileFormFiller.validate(base, target: target(field)))
        }
        var pure = base; pure[1].text = "https://obiz.kbstar.com/quics?page=C019750&QSL=F&cc=opaque"
        XCTAssertNoThrow(try ProfileFormFiller.validate(pure, target: target()))
    }

    func testToleratesHelpIconBeforeTheExampleAndATruncatedEscapeInTheAddress() throws {
        // 2026-09-10: Vision read the (i) icon as a leading "i " and cut the address right after a lone '%'.
        var variant = base
        variant[1].text = "https://obiz.kbstar.com/quics?page=C019750&QSL=F&cc=b028364%"
        variant[8].text = "i 예:1981년 2월 1일일 경우 810201"
        XCTAssertNoThrow(try ProfileFormFiller.validate(variant, target: target(.birthDate)))
        variant[1].text = "https://obiz.kbstar.com/quics?page=C019751&QSL=F&cc=b028364%"
        XCTAssertThrowsError(try ProfileFormFiller.validate(variant, target: target(.birthDate)))
    }

    func testRejectsWrongOriginPathNestedURLAndAmbiguousPage() {
        let invalid = [
            "https://obiz.kbstar.com.evil.invalid/quics?page=C019750", "https://evil.invalid/?url=https://obiz.kbstar.com/quics?page=C019750",
            "http://obiz.kbstar.com/quics?page=C019750", "https://obank.kbstar.com/quics?page=C019750",
            "https://user@obiz.kbstar.com/quics?page=C019750", "https://obiz.kbstar.com:444/quics?page=C019750",
            "https://obiz.kbstar.com/quics/extra?page=C019750", "https://obiz.kbstar.com/%71uics?page=C019750",
            "https://obiz.kbstar.com/quics?page=C019623", "https://obiz.kbstar.com/quics?page=C019750#other",
            "https://obiz.kbstar.com/quics?page=C019750&page=C019623", "https://obiz.kbstar.com/quics?page=C019750&%70age=C019623",
            "https://obiz.kbstar.com/quics?%70age=C019750", "https://obiz.kbstar.com/quics?page=%43019750",
            "https://obiz.kbstar.com/quics?page=C019750&QSL=T", "https://obiz.kbstar.com/quics?page=C019750&redirect=evil",
            "Click https://obiz.kbstar.com/quics?page=C019750", "a evil https://obiz.kbstar.com/quics?page=C019750"
        ]
        for address in invalid { var words = base; words[1].text = address; neverTypes(words) }
        var pageMention = base; pageMention[1].y = 0.4; neverTypes(pageMention)
        neverTypes(base + [base[1]])
    }

    func testRejectsCorporateFormMissingEvidenceAndCompetingDialog() {
        neverTypes(replacing("생년월일", with: "사업자등록번호"))
        for label in ["ID조회", "조회구분", "고객명", "생년월일", "출금계좌번호", "출금계좌비밀번호", "확인", "예:1981년 2월 1일일 경우 810201", "• 법인사업자 O 개인사업자"] {
            neverTypes(base.filter { $0.text != label })
        }
        for label in ["ID조회", "고객명", "생년월일", "출금계좌번호", "출금계좌비밀번호"] {
            neverTypes(base + base.filter { $0.text == label })
        }
        for label in ["주민등록번호", "사업자등록번호", "인증번호", "비밀번호", "인증서암호", "OTP", "인증 번호:", "비밀번호*", "password", "보안키패드"] {
            neverTypes(base + [word(label, 0.45, 0.52, 0.15)])
        }
        var swapped = base
        swapped[7].y = 0.7847; swapped[9].y = 0.7201
        neverTypes(swapped)
    }

    func testRejectsPasswordConfirmHelpAndOtherFieldCoordinates() {
        for point in [(0.445, 0.845), (0.50, 0.918), (0.48, 0.67), (0.25, 0.638), (0.85, 0.638), (0.476, 0.716)] {
            neverTypes(base, target: .init(field: .bankCustomerName, x: point.0, y: point.1, form: .kbIDLookup, bankID: "kb"))
        }
        for field: ProfileFormFiller.Field in [.name, .phone, .businessName] {
            neverTypes(base, target: .init(field: field, x: 0.476, y: 0.638, form: .kbIDLookup, bankID: "kb"))
        }
        for bankID: String? in [nil, "other"] {
            neverTypes(base, target: .init(field: .bankCustomerName, x: 0.476, y: 0.638, form: .kbIDLookup, bankID: bankID))
        }
    }

    func testUsesOnlySelectedBankSavedValuesAndSixDigitBirthdayWithoutReturningThem() throws {
        for (field, expected): (ProfileFormFiller.Field, String) in [(.bankCustomerName, "합성통장고객"), (.birthDate, "810201"), (.bankAccountNumber, "000123456789")] {
            let target = target(field)
            var frames = [base, base, base + [word(expected, 0.405, target.y - 0.01, 0.14)]]
            var clicks = 0, keys: [String] = [], typed: [String] = [], focus = 0
            let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                key: { keys.append($0) }, type: { typed.append($0) },
                inputFocus: { seen in XCTAssertEqual(seen.bankID, "kb"); focus += 1; return true }, settle: {})
            let result = try filler.fill(profile, target: target)
            XCTAssertEqual(clicks, 1); XCTAssertEqual(focus, 1); XCTAssertEqual(keys, ["ctrl+a"]); XCTAssertEqual(typed, [expected])
            XCTAssertTrue(result.contains("\"verified\":true")); XCTAssertFalse(result.contains(expected))
            XCTAssertFalse(result.contains("다른"))
        }
    }

    func testMissingBankValueNeverFallsBackToPersonalNameOrBusinessName() {
        var incomplete = profile; incomplete.bankProfiles?["kb"]?.customerName = nil
        let filler = ProfileFormFiller(screen: { XCTFail("missing value must stop before screen"); return [] },
            click: { _, _ in XCTFail("must not click") }, type: { _ in XCTFail("must not type") }, settle: {})
        XCTAssertThrowsError(try filler.fill(incomplete, target: target()))
        incomplete.bankProfiles?.removeValue(forKey: "kb")
        XCTAssertThrowsError(try filler.fill(incomplete, target: target(.bankAccountNumber)))
    }

    func testSixDigitBirthdayRetainsLeadingZeroes() throws {
        var younger = profile; younger.birthDate = "2000-01-02"
        var frames = [base, base, base + [word("000102", 0.405, 0.706, 0.10)]]
        var typed: [String] = []
        let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in }, key: { _ in },
            type: { typed.append($0) }, inputFocus: { _ in true }, settle: {})
        let result = try filler.fill(younger, target: target(.birthDate))
        XCTAssertEqual(typed, ["000102"]); XCTAssertFalse(result.contains("000102"))
    }

    func testNavigationAfterClickAndUnprovenFocusPreventKeysAndPrivateTyping() {
        let moved = base.map { var word = $0; word.y += 0.04; return word }
        for focusedWords in [[], replacing("생년월일", with: "사업자등록번호"), moved] {
            var frames = [base, focusedWords], clicks = 0
            let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") },
                inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
            XCTAssertThrowsError(try filler.fill(profile, target: target())); XCTAssertEqual(clicks, 1)
        }
        let filler = ProfileFormFiller(screen: { self.base }, click: { _, _ in },
            key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") }, inputFocus: { _ in false }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: target()))
    }

    func testFailedVerificationDoesNotRepeatInput() {
        var clicks = 0, typed = 0
        let filler = ProfileFormFiller(screen: { self.base }, click: { _, _ in clicks += 1 },
            key: { _ in }, type: { _ in typed += 1 }, inputFocus: { _ in true }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: target()))
        XCTAssertEqual(clicks, 1); XCTAssertEqual(typed, 1)
    }

    func testAlreadyFilledVerificationIsConfinedToRequestedInputRegion() throws {
        let filled = base + [word("합성통장고객", 0.405, 0.628, 0.14)]
        let filler = ProfileFormFiller(screen: { filled }, click: { _, _ in XCTFail("must not refill") }, settle: {})
        let result = try filler.fill(profile, target: target())
        XCTAssertTrue(result.contains("\"already_filled\":true")); XCTAssertFalse(result.contains("합성통장고객"))
        let elsewhere = base + [word("합성통장고객", 0.405, 0.90, 0.14)]
        var inputs = 0
        let wrongRow = ProfileFormFiller(screen: { elsewhere }, click: { _, _ in }, key: { _ in },
            type: { _ in inputs += 1 }, inputFocus: { _ in true }, settle: {})
        XCTAssertThrowsError(try wrongRow.fill(profile, target: target())); XCTAssertEqual(inputs, 1)
    }
}
