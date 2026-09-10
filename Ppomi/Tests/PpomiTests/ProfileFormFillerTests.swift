import XCTest
@testable import Ppomi

final class ProfileFormFillerTests: XCTestCase {
    private func word(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.07) -> OCR.Word {
        OCR.Word(x: x, y: y, w: width, h: 0.02, text: text)
    }
    private var base: [OCR.Word] {
        [word("https://www.eais.go.kr/moct/", 0.12, 0.10, 0.5), word("통신사PASS", 0.48, 0.165),
         word("본인인증 정보 입력", 0.43, 0.25, 0.2), word("이름", 0.445, 0.325, 0.03),
         word("생년월일", 0.445, 0.395), word("휴대폰 번호", 0.445, 0.465, 0.085), word("010", 0.735, 0.465, 0.03)]
    }
    private var profile: IdentityProfile { IdentityProfile(name: "합성 본인", birthDate: "2000-01-02", phone: "01012345678", carrier: "kt") }

    func testRejectsUnsupportedFormsBooleansAndNonFiniteLocations() throws {
        for args: [String: Any] in [[:], ["form": "bank", "field": "name", "x": 0.7, "y": 0.3],
                                     ["form": "eais_pass", "field": "password", "x": 0.7, "y": 0.3],
                                     ["form": "eais_pass", "field": "name", "x": true, "y": 0.3],
                                     ["form": "eais_pass", "field": "name", "x": Double.nan, "y": 0.3],
                                     ["form": "eais_pass", "field": "name", "x": 0.7, "y": 0.3, "approved": true]] {
            XCTAssertThrowsError(try ProfileFormFiller.request(args))
        }
    }

    func testWrongOriginFormAndFieldCannotPostAnyInput() throws {
        let target = ProfileFormFiller.Target(field: .name, x: 0.75, y: 0.335)
        var wrongHost = base; wrongHost[0].text = "https://www.eais.go.kr.evil.invalid/"
        var nestedHost = base; nestedHost[0].text = "https://evil.invalid/?next=https://www.eais.go.kr/"
        var pageMention = base; pageMention[0].y = 0.75
        var otherForm = base; otherForm.remove(at: 1)
        let protected = base + [word("인증번호", 0.445, 0.60)]
        let ambiguous = base + [word("이름", 0.445, 0.53, 0.03)]
        for words in [wrongHost, nestedHost, pageMention, otherForm, protected, ambiguous, []] {
            let filler = ProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("must not click") },
                                           key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") }, inputFocus: { _ in true }, settle: {})
            XCTAssertThrowsError(try filler.fill(profile, target: target))
        }
        XCTAssertThrowsError(try ProfileFormFiller.validate(base, target: .init(field: .name, x: 0.75, y: 0.405)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(base, target: .init(field: .phone, x: 0.65, y: 0.475)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(base, target: .init(field: .carrier, x: 0.85, y: 0.475)))
        for label in ["비밀 번호", "주민등록번호", "인증 번호", "Password", "OTP", "카드 번호"] {
            XCTAssertThrowsError(try ProfileFormFiller.validate(base + [word(label, 0.445, 0.60)], target: target))
        }
    }

    func testAddressBarIsJudgedAgainstTheHeaderNotAFixedBand() throws {
        var shrunk = base; shrunk[0].y = 0.18; shrunk[1].y = 0.24
        for index in 2..<shrunk.count { shrunk[index].y += 0.09 }
        XCTAssertNoThrow(try ProfileFormFiller.validate(shrunk, target: .init(field: .name, x: 0.75, y: 0.425)))
        var belowHeader = shrunk; belowHeader[0].y = 0.26
        XCTAssertThrowsError(try ProfileFormFiller.validate(belowHeader, target: .init(field: .name, x: 0.75, y: 0.425)))
    }

    func testInputTooltipRepeatingTheLabelDoesNotMakeTheRowAmbiguous() throws {
        let tooltip = base + [word("이름", 0.70, 0.36, 0.03)]
        XCTAssertNoThrow(try ProfileFormFiller.validate(tooltip, target: .init(field: .name, x: 0.75, y: 0.335)))
    }

    func testProtectedWordsCountOnlyInsideTheFormPanel() throws {
        let target = ProfileFormFiller.Target(field: .name, x: 0.75, y: 0.335)
        // The login page behind the modal keeps its "아이디와 비밀번호를 이용" copy on screen, left of the panel.
        let background = base + [word("와 비밀번호를 이용", 0.20, 0.62, 0.12), word("비밀번호 찾기", 0.85, 0.30, 0.08)]
        XCTAssertNoThrow(try ProfileFormFiller.validate(background, target: target))
        for inside in [word("비밀번호", 0.445, 0.60), word("인증번호", 0.62, 0.15), word("password", 0.60, 0.70)] {
            XCTAssertThrowsError(try ProfileFormFiller.validate(base + [inside], target: target))
        }
    }

    func testSelectedPASSHeaderFollowsMovedFormTitleButProviderListDoesNotCount() throws {
        var moved = base
        for index in 2..<moved.count { moved[index].y += 0.087 }
        moved[1].x = 0.485; moved[1].y = 0.275
        moved[2].x = 0.461
        let target = ProfileFormFiller.Target(field: .name, x: 0.75, y: 0.422)
        let provider = word("통신사PASS", 0.385, 0.355)
        XCTAssertNoThrow(try ProfileFormFiller.validate(moved + [provider], target: target))
        XCTAssertNoThrow(try ProfileFormFiller.validate(base, target: .init(field: .name, x: 0.75, y: 0.335)))

        var providerOnly = moved; providerOnly.remove(at: 1); providerOnly.append(provider)
        var leftProvider = moved; leftProvider[1].x = 0.385
        var overlapping = moved; overlapping[1].y = moved[2].y
        let duplicateTitle = moved + [word("본인인증정보입력", 0.461, 0.60, 0.2)]
        let duplicateHeader = moved + [word("통신사PASS", 0.485, 0.24)]
        for words in [providerOnly, leftProvider, overlapping, duplicateTitle, duplicateHeader] {
            let filler = ProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("unproven selected method must not click") },
                                           key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") },
                                           inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
            XCTAssertThrowsError(try filler.fill(profile, target: target))
        }
    }

    func testUnprovenFocusNeverReceivesPrivateTextOrSelectAll() throws {
        let filler = ProfileFormFiller(screen: { self.base }, click: { _, _ in },
                                       key: { _ in XCTFail("unproven focus must not receive keys") },
                                       type: { _ in XCTFail("unproven focus must not receive identity") },
                                       inputFocus: { _ in false }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: .init(field: .name, x: 0.75, y: 0.335)))
    }

    func testEachBasicTextFieldUsesLocalValueAndOnlyReturnsVerification() throws {
        let cases: [(ProfileFormFiller.Field, Double, Double, String)] = [(.name, 0.75, 0.335, "합성 본인"), (.birthDate, 0.75, 0.405, "20000102"), (.phone, 0.85, 0.475, "12345678")]
        for (field, x, y, expected) in cases {
            var frames = [base, base, base + [word(expected, x - 0.02, y - 0.01)]]
            var clicked = 0, keys: [String] = [], typed: [String] = []
            let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicked += 1 },
                                           key: { keys.append($0) }, type: { typed.append($0) }, inputFocus: { _ in true }, settle: {})
            let result = try filler.fill(profile, target: .init(field: field, x: x, y: y))
            XCTAssertEqual(clicked, 1); XCTAssertEqual(keys, ["ctrl+a"]); XCTAssertEqual(typed, [expected])
            XCTAssertFalse(result.contains(expected)); XCTAssertTrue(result.contains("\"verified\":true"))
        }
    }

    func testNavigationAfterClickStopsBeforeTypingAndFailedVerificationDoesNotRetry() throws {
        var frames = [base, []]
        var clicks = 0
        var filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                                       key: { _ in XCTFail("changed form must not type") }, type: { _ in XCTFail("changed form must not type") }, inputFocus: { _ in true }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: .init(field: .name, x: 0.75, y: 0.335)))
        XCTAssertEqual(clicks, 1)
        frames = [base, base, base]; clicks = 0
        var typed = 0
        filler.key = { _ in }; filler.type = { _ in typed += 1 }
        XCTAssertThrowsError(try filler.fill(profile, target: .init(field: .name, x: 0.75, y: 0.335)))
        XCTAssertEqual(typed, 1); XCTAssertEqual(clicks, 1)
    }

    func testCarrierUsesObservedChoiceWithoutKeysTypingOrConsentClicks() throws {
        let menu = base + [word("SKT", 0.59, 0.55), word("KT", 0.59, 0.58), word("KT알뜰폰", 0.59, 0.69)]
        let after = base + [word("KT", 0.59, 0.465)]
        var frames = [base, menu, after], clicks: [(Double, Double)] = []
        let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { clicks.append(($0, $1)) },
                                       key: { _ in XCTFail("carrier needs no key") }, type: { _ in XCTFail("carrier needs no typing") }, inputFocus: { _ in true }, settle: {})
        let result = try filler.fill(profile, target: .init(field: .carrier, x: 0.65, y: 0.475))
        XCTAssertEqual(clicks.count, 2); XCTAssertEqual(clicks[1].1, 0.59, accuracy: 0.001)
        XCTAssertFalse(result.contains("KT"))
    }

    // Synthetic geometry of the observed EAIS business page; no user's registration details are fixtures.
    private var business: [OCR.Word] {
        [word("https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04", 0.12, 0.12, 0.68),
         word("사업자명", 0.052, 0.364, 0.076), word("사업자등록번호", 0.467, 0.364, 0.128),
         word("-", 0.733, 0.364, 0.008), word("-", 0.861, 0.364, 0.008),
         word("개인사업자는 주민등록번호가 아닌 사업자등록번호를 사용합니다.", 0.15, 0.46, 0.70)] +
        (1...3).map { BusinessFormGeometry.emptyMarker(segment: $0, x: [0.67, 0.80, 0.93][$0 - 1], y: 0.374) }
    }
    private var businessProfile: IdentityProfile {
        IdentityProfile(businessName: "합성사업장", businessRegistrationNumber: "1234567891")
    }
    private func businessTarget(_ segment: Int) -> ProfileFormFiller.Target {
        .init(field: .businessRegistrationNumber, x: [0.67, 0.80, 0.93][segment - 1], y: 0.374,
              form: .eaisBusiness, segment: segment)
    }

    func testBusinessRequestSeparatesFormFieldsAndRequiresIntegerSegment() throws {
        for segment in 1...3 {
            let target = try ProfileFormFiller.request(["form": "eais_business", "field": "business_registration_number",
                                                        "segment": segment, "x": 0.8, "y": 0.374])
            XCTAssertEqual(target.form, .eaisBusiness); XCTAssertEqual(target.segment, segment)
        }
        let name = try ProfileFormFiller.request(["form": "eais_business", "field": "business_name", "x": 0.25, "y": 0.374])
        XCTAssertNil(name.segment)
        let invalid: [[String: Any]] = [
            ["form": "eais_business", "field": "name", "x": 0.25, "y": 0.374],
            ["form": "eais_pass", "field": "business_name", "x": 0.25, "y": 0.374],
            ["form": "eais_business", "field": "business_registration_number", "x": 0.8, "y": 0.374],
            ["form": "eais_business", "field": "business_name", "segment": 1, "x": 0.25, "y": 0.374],
            ["form": "eais_pass", "field": "name", "segment": 1, "x": 0.75, "y": 0.335]
        ]
        for request in invalid { XCTAssertThrowsError(try ProfileFormFiller.request(request)) }
        for segment: Any in [0, 4, true, 1.5, "1", Double.nan, Double.infinity] {
            XCTAssertThrowsError(try ProfileFormFiller.request(["form": "eais_business", "field": "business_registration_number",
                                                               "segment": segment, "x": 0.8, "y": 0.374]))
        }
    }

    func testBusinessRequiresExactVisibleHTTPSAddressAndUniqueSameRowLabels() throws {
        let target = businessTarget(1)
        XCTAssertNoThrow(try ProfileFormFiller.validate(business, target: target))
        var withIcon = business; withIcon[0].text = "a " + withIcon[0].text
        XCTAssertNoThrow(try ProfileFormFiller.validate(withIcon, target: target))
        let addresses = ["https://www.eais.go.kr.evil.invalid/moct/awp/aba01/AWPABA01F04",
                         "https://evil.invalid/?next=https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                         "http://www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                         "https://user@www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                         "https://www.eais.go.kr:444/moct/awp/aba01/AWPABA01F04",
                         "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F02",
                         "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04/extra",
                         "https://www.eais.go.kr/moct/awp/aba01/%41WPABA01F04",
                         "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04#other"]
        for address in addresses {
            var words = business; words[0].text = address
            XCTAssertThrowsError(try ProfileFormFiller.validate(words, target: target), address)
        }
        var pageURL = business; pageURL[0].y = 0.55
        var noName = business; noName.remove(at: 1)
        var wrongRow = business; wrongRow[1].y = 0.55
        let duplicate = business + [word("사업자등록번호", 0.47, 0.55, 0.12)]
        for words in [pageURL, noName, wrongRow, duplicate] {
            let filler = ProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("unproven form must not click") },
                                           key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") },
                                           inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
            XCTAssertThrowsError(try filler.fill(businessProfile, target: target))
        }
    }

    func testBusinessSegmentsRequireTwoSeparatorsAndRejectOtherBoxes() throws {
        for segment in 1...3 {
            XCTAssertNoThrow(try ProfileFormFiller.validate(business, target: businessTarget(segment)))
            for other in 1...3 where other != segment {
                var target = businessTarget(other)
                target = .init(field: target.field, x: target.x, y: target.y, form: .eaisBusiness, segment: segment)
                XCTAssertThrowsError(try ProfileFormFiller.validate(business, target: target))
            }
        }
        var missing = business; missing.remove(at: 3)
        var merged = business; merged[3].text = "--"
        var offRow = business; offRow[3].y = 0.53
        let extra = business + [word("-", 0.95, 0.364, 0.008)]
        for words in [missing, merged, offRow, extra] {
            XCTAssertThrowsError(try ProfileFormFiller.validate(words, target: businessTarget(1)))
        }
        XCTAssertThrowsError(try ProfileFormFiller.validate(business, target: .init(field: .businessRegistrationNumber,
                            x: 0.67, y: 0.374, form: .eaisBusiness)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(business, target: .init(field: .businessRegistrationNumber,
                            x: 0.25, y: 0.374, form: .eaisBusiness, segment: 1)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(business, target: .init(field: .businessName,
                            x: 0.80, y: 0.374, form: .eaisBusiness)))
        XCTAssertThrowsError(try ProfileFormFiller.validate(business, target: .init(field: .businessName,
                            x: 0.25, y: 0.6, form: .eaisBusiness)))
    }

    func testBusinessIgnoresGovernmentIDExplanationButRejectsCredentialDialogs() throws {
        let target = businessTarget(1)
        XCTAssertNoThrow(try ProfileFormFiller.validate(business, target: target))
        for label in ["비밀번호", "인증서 비밀번호", "인증번호", "인증서 선택", "공동인증서선택", "Password", "OTP"] {
            XCTAssertThrowsError(try ProfileFormFiller.validate(business + [word(label, 0.6, 0.6, 0.12)], target: target))
        }
        XCTAssertThrowsError(try ProfileFormFiller.validate(business + [word("주민등록번호", 0.6, 0.364, 0.12)], target: target))
    }

    func testBusinessTypesOnlyRequestedLocalFieldAndNeverReturnsItsValue() throws {
        let cases: [(ProfileFormFiller.Target, String)] = [
            (.init(field: .businessName, x: 0.25, y: 0.374, form: .eaisBusiness), "합성사업장"),
            (businessTarget(1), "123"), (businessTarget(2), "45"), (businessTarget(3), "67891")
        ]
        for (target, expected) in cases {
            let observed = word(expected, target.x - 0.025, target.y - 0.01, 0.05)
            var frames = [business, business, business + [observed]]
            var clicks = 0, keys: [String] = [], typed: [String] = [], digits: [String] = []
            let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                                           key: { keys.append($0) }, type: { typed.append($0) }, typeDigits: { digits.append($0) },
                                           inputFocus: { _ in true }, settle: {})
            let result = try filler.fill(businessProfile, target: target)
            XCTAssertEqual(clicks, 1)
            if target.field == .businessRegistrationNumber {
                XCTAssertTrue(keys.isEmpty); XCTAssertTrue(typed.isEmpty); XCTAssertEqual(digits, [expected])
                if (target.segment ?? 0) > 1 {
                    XCTAssertFalse(result.contains("\"verified\":true"))
                    XCTAssertTrue(result.contains("\"value_verified\":false"))
                    XCTAssertTrue(result.contains("\"requires_site_verification\":true"))
                } else { XCTAssertTrue(result.contains("\"verified\":true")) }
            } else { XCTAssertEqual(keys, ["ctrl+a"]); XCTAssertEqual(typed, [expected]); XCTAssertTrue(digits.isEmpty) }
            XCTAssertFalse(result.contains(expected))
        }
    }

    func testBusinessVerificationCannotUseSameDigitsFromAnotherSegment() throws {
        let target = businessTarget(1)
        let wrongPlace = business + [word("123", 0.78, 0.364, 0.04)]
        var frames = [wrongPlace, wrongPlace, wrongPlace]
        var typed = 0, clicked = 0
        let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicked += 1 },
                                       key: { _ in XCTFail("business number must not use modifier keys") }, type: { _ in XCTFail("must not paste") },
                                       typeDigits: { _ in typed += 1 }, inputFocus: { _ in true }, settle: {})
        XCTAssertThrowsError(try filler.fill(businessProfile, target: target))
        XCTAssertEqual(typed, 1); XCTAssertEqual(clicked, 1)
        let correct = business + [word("123", 0.64, 0.364, 0.04)]
        let already = ProfileFormFiller(screen: { correct }, click: { _, _ in XCTFail("already filled must not click") },
                                       key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not type") },
                                       inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
        XCTAssertTrue(try already.fill(businessProfile, target: target).contains("\"already_filled\":true"))
    }

    func testBusinessStopsOnMissingFocusOrNavigationAndDoesNotSubmitConsent() throws {
        let target = businessTarget(1)
        let noFocus = ProfileFormFiller(screen: { self.business }, click: { _, _ in }, key: { _ in XCTFail("must not key") },
                                       type: { _ in XCTFail("must not type") }, inputFocus: { _ in false }, settle: {})
        XCTAssertThrowsError(try noFocus.fill(businessProfile, target: target))
        var next = business; next[0].text = "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F05"
        var frames = [business, next]
        let moved = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in }, key: { _ in XCTFail("must not key") },
                                     type: { _ in XCTFail("must not type") }, inputFocus: { _ in XCTFail("must not inspect focus"); return false }, settle: {})
        XCTAssertThrowsError(try moved.fill(businessProfile, target: target))
    }

    func testMaskedBusinessFieldsNeedPositiveEmptyEvidenceAndNeverPretendToVerifyValue() throws {
        for segment in [2, 3] {
            let target = businessTarget(segment)
            let withoutEvidence = business.filter { !($0.w == 0 && $0.h == 0) }
            let existing = withoutEvidence + [word(segment == 2 ? "••" : "•••••", target.x - 0.02, 0.364, 0.04)]
            let filler = ProfileFormFiller(screen: { existing }, click: { _, _ in XCTFail("unknown existing content must not click") },
                                           key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not paste") },
                                           typeDigits: { _ in XCTFail("must not overwrite masked value") }, inputFocus: { _ in false }, settle: {})
            let result = try filler.fill(businessProfile, target: target)
            XCTAssertTrue(result.contains("\"input_attempted\":false"))
            XCTAssertTrue(result.contains("\"value_verified\":false"))
            XCTAssertTrue(result.contains("\"requires_site_verification\":true"))
            XCTAssertFalse(result.contains("\"verified\":true"))
        }
    }

    func testBusinessNumericFilterAlertHasSpecificFailureAndNeverTypes() throws {
        let modal = business + [word("알림", 0.48, 0.46), word("숫자만 입력 가능합니다", 0.40, 0.53, 0.30)]
        let filler = ProfileFormFiller(screen: { modal }, click: { _, _ in XCTFail("modal must not receive clicks") },
                                       key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not paste") },
                                       typeDigits: { _ in XCTFail("must not type digits") }, inputFocus: { _ in false }, settle: {})
        XCTAssertThrowsError(try filler.fill(businessProfile, target: businessTarget(1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("숫자만 입력 가능합니다"))
        }
    }

    func testBusinessDelayedContentAfterClickStopsBeforePrivateDigitDriver() throws {
        let changed = business.filter { !($0.w == 0 && $0.h == 0) } + [word("••", 0.78, 0.364, 0.04)]
        var frames = [business, changed]
        let filler = ProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in },
                                       key: { _ in XCTFail("must not key") }, type: { _ in XCTFail("must not paste") },
                                       typeDigits: { _ in XCTFail("late content must not be overwritten") },
                                       inputFocus: { _ in XCTFail("must stop before focus driver"); return false }, settle: {})
        XCTAssertThrowsError(try filler.fill(businessProfile, target: businessTarget(2)))
    }

    func testBusinessNumberRowAcceptsMergedCompanyAnchorWithoutInventingLabelBounds() throws {
        var merged = business
        merged[1].text = "사업자명 합성사업장"; merged[1].w = 0.1642
        for segment in 1...3 { XCTAssertNoThrow(try ProfileFormFiller.validate(merged, target: businessTarget(segment))) }
        for invalid in ["사업자명칭 합성사업장", "이전 사업자명 합성사업장", "사업자명합성사업장", "사업자명\n다른행"] {
            var changed = merged; changed[1].text = invalid
            XCTAssertThrowsError(try ProfileFormFiller.validate(changed, target: businessTarget(2)))
        }
        var overlapping = merged; overlapping[1].w = 0.45
        XCTAssertThrowsError(try ProfileFormFiller.validate(overlapping, target: businessTarget(2)))
        let duplicate = merged + [word("사업자명", 0.052, 0.55, 0.076)]
        XCTAssertThrowsError(try ProfileFormFiller.validate(duplicate, target: businessTarget(2)))
    }

}
