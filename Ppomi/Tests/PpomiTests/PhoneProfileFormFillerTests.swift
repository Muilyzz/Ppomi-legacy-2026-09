import XCTest
import CoreGraphics
import ImageIO
@testable import Ppomi

final class PhoneProfileFormFillerTests: XCTestCase {
    private func word(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.02) -> OCR.Word {
        .init(x: x, y: y, w: w, h: h, text: text)
    }
    private var base: [OCR.Word] {
        [word("KB국민인증서(기업)", 0.0819, 0.1476, 0.3233, 0.0194),
         word("인증서 정보를 입력해주세요.", 0.0819, 0.2194, 0.4612, 0.0252),
         word("사업자등록번호", 0.0862, 0.2699, 0.2026, 0.0175),
         word("3자리", 0.0862, 0.2971, 0.0991, 0.0233),
         word("- 2자리", 0.2888, 0.3010, 0.1466, 0.0194),
         word("- 5자리", 0.5431, 0.3010, 0.1466, 0.0194),
         word("휴대폰 번호", 0.0859, 0.3607, 0.1557, 0.0184),
         word("010", 0.0862, 0.3922, 0.0733, 0.0175),
         word("• 입력하신 휴대폰 번호로 SMS 인증번호를 전송합니다.", 0.0862, 0.4311, 0.6810, 0.0194),
         word("~ 정보 저장하기", 0.0860, 0.4792, 0.2633, 0.0222),
         word("인증서 발급하기 >", 0.6595, 0.5340, 0.2586, 0.0175),
         word("다음", 0.4612, 0.9146, 0.0690, 0.0175)]
    }
    private var regions: [Int: CGRect] {
        [1: CGRect(x: 0.0862, y: 0.290, width: 0.191, height: 0.038),
         2: CGRect(x: 0.341, y: 0.290, width: 0.191, height: 0.038),
         3: CGRect(x: 0.594, y: 0.290, width: 0.319, height: 0.038),
         4: CGRect(x: 0.399, y: 0.380, width: 0.514, height: 0.038)]
    }
    private var profile: IdentityProfile { .init(phone: "01012345678", businessRegistrationNumber: "0012345678") }
    private func target(_ slot: Int) -> PhoneProfileFormFiller.Target {
        let r = regions[slot]!
        return .init(field: slot == 4 ? .phone : .businessRegistrationNumber, x: r.midX, y: r.midY, segment: slot == 4 ? nil : slot)
    }
    private func frame(empty: Set<Int> = [1, 2, 3, 4], focus: Int? = nil, words: [OCR.Word]? = nil) -> [OCR.Word] {
        (words ?? base) + (1...4).flatMap { PhoneKBGeometry.evidence(slot: $0, region: regions[$0]!, empty: empty.contains($0), focused: focus == $0) }
    }
    private func neverTypes(_ words: [OCR.Word], target: PhoneProfileFormFiller.Target? = nil) {
        let filler = PhoneProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("must not click") },
                                            typeDigits: { _ in XCTFail("must not type") }, settle: {})
        XCTAssertThrowsError(try filler.fill(profile, target: target ?? self.target(1)))
    }

    func testRequestOnlyAcceptsTheObservedPhoneFormAndSegmentedBusinessFields() throws {
        for segment in 1...3 {
            let value = try PhoneProfileFormFiller.request(["form": "kb_enterprise_certificate_info", "field": "business_registration_number", "segment": segment, "x": 0.17, "y": 0.31])
            XCTAssertEqual(value.segment, segment)
        }
        XCTAssertNil(try PhoneProfileFormFiller.request(["form": "kb_enterprise_certificate_info", "field": "phone", "x": 0.5, "y": 0.4]).segment)
        let invalid: [[String: Any]] = [
            ["form": "kb_id_lookup", "field": "phone", "x": 0.5, "y": 0.4],
            ["form": "kb_enterprise_certificate_info", "field": "password", "x": 0.5, "y": 0.4],
            ["form": "kb_enterprise_certificate_info", "field": "business_registration_number", "x": 0.17, "y": 0.31],
            ["form": "kb_enterprise_certificate_info", "field": "business_registration_number", "segment": true, "x": 0.17, "y": 0.31],
            ["form": "kb_enterprise_certificate_info", "field": "business_registration_number", "segment": 1.5, "x": 0.17, "y": 0.31],
            ["form": "kb_enterprise_certificate_info", "field": "phone", "segment": 1, "x": 0.5, "y": 0.4],
            ["form": "kb_enterprise_certificate_info", "field": "phone", "x": true, "y": 0.4],
            ["form": "kb_enterprise_certificate_info", "field": "phone", "x": Double.nan, "y": 0.4],
            ["form": "kb_enterprise_certificate_info", "field": "phone", "x": 0.5, "y": 0.4, "bank_id": "kb"]]
        for args in invalid { XCTAssertThrowsError(try PhoneProfileFormFiller.request(args)) }
    }

    func testRejectsOtherCertificatesMissingRowsProtectedInputsAndWrongCoordinates() throws {
        for text in ["KB국민인증서(기업)", "인증서 정보를 입력해주세요.", "사업자등록번호", "휴대폰 번호", "010", "다음",
                     "• 입력하신 휴대폰 번호로 SMS 인증번호를 전송합니다.", "인증서 발급하기 >"] {
            neverTypes(frame(words: base.filter { $0.text != text }))
        }
        neverTypes(frame(words: base.map { var w = $0; if w.text == "KB국민인증서(기업)" { w.text = "KB국민인증서(개인)" }; return w }))
        for label in ["비밀번호", "인증 번호:", "주민등록번호", "OTP", "PIN", "password", "보안키패드"] {
            neverTypes(frame(words: base + [word(label, 0.4, 0.6, 0.15)]))
        }
        for point in [(0.29, 0.309), (0.44, 0.309), (0.15, 0.4), (0.6, 0.92), (0.15, 0.49)] {
            neverTypes(frame(), target: .init(field: .businessRegistrationNumber, x: point.0, y: point.1, segment: 1))
        }
        for slot in 1...4 { XCTAssertNoThrow(try PhoneProfileFormFiller.validate(frame(), target: target(slot))) }
    }

    func testTypesOnlySavedSegmentsAndEightPhoneDigitsWithoutReturningValuesOrSubmitting() throws {
        for (slot, value) in [(1, "001"), (2, "23"), (3, "45678"), (4, "12345678")] {
            var afterWords = base
            let r = regions[slot]!
            afterWords.append(word(value, r.minX + 0.01, r.minY + 0.004, min(r.width - 0.02, 0.13), 0.022))
            var frames = [frame(), frame(focus: slot), frame(empty: Set(1...4).subtracting([slot]), words: afterWords)]
            var clicks = 0, inputs: [String] = []
            let filler = PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                                                typeDigits: { inputs.append($0) }, settle: {})
            let response = try filler.fill(profile, target: target(slot))
            XCTAssertEqual(clicks, 1); XCTAssertEqual(inputs, [value]); XCTAssertTrue(response.contains("\"verified\":true"))
            XCTAssertFalse(response.contains(value)); XCTAssertFalse(response.contains("01012345678")); XCTAssertFalse(response.contains("0012345678"))
        }
    }

    func testFilledMaskedOrAmbiguousFieldsAreNotOverwrittenAndUnknownResultsDoNotRetry() throws {
        neverTypes(frame(empty: [2, 3, 4]))
        neverTypes(frame(empty: [2, 3, 4], words: base + [word("•••", 0.09, 0.3, 0.06)]))
        var count = 0
        let noFocus = PhoneProfileFormFiller(screen: { self.frame() }, click: { _, _ in count += 1 },
                                             typeDigits: { _ in XCTFail("missing cursor must stop input") }, settle: {})
        XCTAssertThrowsError(try noFocus.fill(profile, target: target(1))); XCTAssertEqual(count, 1)
        var frames = [frame(), frame(empty: [2, 3, 4], focus: 1)], inputs = 0
        let delayed = PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in },
                                             typeDigits: { _ in inputs += 1 }, settle: {})
        XCTAssertThrowsError(try delayed.fill(profile, target: target(1))); XCTAssertEqual(inputs, 0)
        frames = [frame(), frame(focus: 1), frame(empty: [2, 3, 4])]
        let uncertain = PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in },
                                               typeDigits: { _ in inputs += 1 }, settle: {})
        XCTAssertThrowsError(try uncertain.fill(profile, target: target(1))); XCTAssertEqual(inputs, 1)
    }

    func testNavigationMovedFormAndCompetingCursorStopAfterClick() {
        var moved = frame()
        for i in moved.indices { moved[i].y += 0.04 }
        let competing = frame(focus: 1) + PhoneKBGeometry.evidence(slot: 2, region: regions[2]!, empty: true, focused: true).filter { $0.text.contains("_focus__") }
        for second in [[], moved, competing] {
            var frames = [frame(), second], clicks = 0
            let filler = PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                                                typeDigits: { _ in XCTFail("must not type") }, settle: {})
            XCTAssertThrowsError(try filler.fill(profile, target: target(1))); XCTAssertEqual(clicks, 1)
        }
    }

    func testAlreadyFilledValueMustBelongToRequestedSlotAndMissingProfileStopsBeforeCapture() throws {
        let r = regions[1]!, good = frame(empty: [2, 3, 4], words: base + [word("001", r.minX + 0.01, 0.296, 0.06, 0.022)])
        let filler = PhoneProfileFormFiller(screen: { good }, click: { _, _ in XCTFail("must not refill") },
                                            typeDigits: { _ in XCTFail("must not type") }, settle: {})
        XCTAssertTrue(try filler.fill(profile, target: target(1)).contains("already_filled"))
        let missing = PhoneProfileFormFiller(screen: { XCTFail("must not capture missing value"); return [] }, settle: {})
        XCTAssertThrowsError(try missing.fill(IdentityProfile(), target: target(1)))
        XCTAssertThrowsError(try missing.fill(IdentityProfile(), target: target(4)))
    }

    private var nameBase: [OCR.Word] {
        [word("< KB국민인증서(기업) 발급 =", 0.09, 0.15, 0.42, 0.019),
         word("휴대폰 본인인증", 0.086, 0.215, 0.33, 0.026),
         word("이름을 입력해주세요.", 0.086, 0.27, 0.32, 0.02),
         word("이름", 0.086, 0.322, 0.05, 0.014),
         word("이름", 0.086, 0.35, 0.065, 0.02),
         word("다음", 0.46, 0.915, 0.069, 0.0175)]
    }
    private var nameTarget: PhoneProfileFormFiller.Target { .init(field: .name, x: 0.5, y: 0.36, form: .kbEnterprisePhoneIdentity) }

    func testNameScreenTypesHangulKeysOnlyIntoTheEmptyNameRow() throws {
        let profile = IdentityProfile(name: "김영희")
        let typed = nameBase.filter { !($0.text == "이름" && $0.h > 0.015) } + [word("김영희", 0.086, 0.35, 0.12, 0.022)]
        let caret = nameBase.map { w -> OCR.Word in var w = w; if w.text == "이름" && w.h > 0.015 { w.text = "ㅏ름" }; return w }
        var frames = [caret, typed], clicks = 0, keys: [String] = []
        let filler = PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in clicks += 1 },
                                            typeDigits: { _ in XCTFail("digits path must not run") }, typeKeys: { keys.append($0) }, settle: {})
        let response = try filler.fill(profile, target: nameTarget)
        XCTAssertEqual(clicks, 1); XCTAssertEqual(keys, ["rladudgml"])
        XCTAssertTrue(response.contains("\"verified\":true")); XCTAssertFalse(response.contains("김영희"))
        XCTAssertTrue(try PhoneProfileFormFiller(screen: { typed }, click: { _, _ in XCTFail() }, typeKeys: { _ in XCTFail() }, settle: {})
            .fill(profile, target: nameTarget).contains("already_filled"))
        let caretAfter = typed.map { w -> OCR.Word in var w = w; if w.text == "김영희" { w.text = "김영흭" }; return w }
        frames = [caret, caretAfter]
        XCTAssertTrue(try PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in }, typeKeys: { _ in }, settle: {})
            .fill(profile, target: nameTarget).contains("\"verified\":true"))
        // Wrong screen, protected input, wrong row, non-Hangul name, unverified result: never type or never succeed.
        for words in [nameBase.filter { $0.text != "휴대폰 본인인증" }, nameBase + [word("주민등록번호", 0.086, 0.42, 0.15)],
                      nameBase.filter { !($0.text == "이름" && $0.h > 0.015) } + [word("홍길동", 0.086, 0.35, 0.12, 0.022)]] {
            let never = PhoneProfileFormFiller(screen: { words }, click: { _, _ in XCTFail("must not click") }, typeKeys: { _ in XCTFail("must not type") }, settle: {})
            XCTAssertThrowsError(try never.fill(profile, target: nameTarget))
        }
        XCTAssertThrowsError(try PhoneProfileFormFiller(screen: { self.nameBase }, click: { _, _ in XCTFail() }, typeKeys: { _ in XCTFail() }, settle: {})
            .fill(profile, target: .init(field: .name, x: 0.5, y: 0.6, form: .kbEnterprisePhoneIdentity)))
        XCTAssertThrowsError(try PhoneProfileFormFiller(screen: { XCTFail("latin name stops before capture"); return [] }, settle: {})
            .fill(IdentityProfile(name: "Kim Younghee"), target: nameTarget))
        frames = [nameBase, nameBase]; var typedOnce = 0
        XCTAssertThrowsError(try PhoneProfileFormFiller(screen: { frames.removeFirst() }, click: { _, _ in }, typeKeys: { _ in typedOnce += 1 }, settle: {})
            .fill(profile, target: nameTarget)); XCTAssertEqual(typedOnce, 1)
        XCTAssertThrowsError(try PhoneProfileFormFiller.request(["form": "kb_enterprise_certificate_info", "field": "name", "x": 0.5, "y": 0.36]))
        XCTAssertThrowsError(try PhoneProfileFormFiller.request(["form": "kb_enterprise_phone_identity", "field": "phone", "x": 0.5, "y": 0.36]))
        XCTAssertEqual(try PhoneProfileFormFiller.request(["form": "kb_enterprise_phone_identity", "field": "name", "x": 0.5, "y": 0.36]).form, .kbEnterprisePhoneIdentity)
    }

    private func syntheticImage(caretSlot: Int? = nil, inkSlot: Int? = nil, missingLine: Int? = nil) throws -> URL {
        let width = 500, height = 1000
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func fill(_ rect: CGRect, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX * Double(width), y: (1 - rect.maxY) * Double(height),
                                width: rect.width * Double(width), height: rect.height * Double(height)))
        }
        let underlineRects = [CGRect(x: 0.086, y: 0.329, width: 0.192, height: 0.002),
                              CGRect(x: 0.342, y: 0.329, width: 0.190, height: 0.002),
                              CGRect(x: 0.594, y: 0.329, width: 0.320, height: 0.002),
                              CGRect(x: 0.086, y: 0.420, width: 0.294, height: 0.002),
                              CGRect(x: 0.400, y: 0.420, width: 0.514, height: 0.002)]
        for (index, rect) in underlineRects.enumerated() where index + 1 != missingLine { fill(rect, CGColor(gray: 0.80, alpha: 1)) }
        for slot in 1...3 {
            let rect = regions[slot]!
            fill(CGRect(x: rect.minX + 0.008, y: 0.305, width: 0.06, height: 0.01), CGColor(gray: 0.6, alpha: 1))
        }
        if let caretSlot {
            let rect = regions[caretSlot]!
            fill(CGRect(x: rect.minX + 0.003, y: rect.minY + 0.005, width: 0.004, height: 0.025), CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1))
        }
        if let inkSlot {
            let rect = regions[inkSlot]!
            fill(CGRect(x: rect.maxX - 0.03, y: rect.minY + 0.01, width: 0.02, height: 0.015), CGColor(gray: 0, alpha: 1))
        }
        let image = try XCTUnwrap(context.makeImage())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-kb-phone-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }

    func testPixelEvidenceRequiresRealUnderlinesEmptyContentsAndNarrowBlueCaret() throws {
        let blank = try syntheticImage(), focused = try syntheticImage(caretSlot: 1), ink = try syntheticImage(caretSlot: 1, inkSlot: 1), missing = try syntheticImage(missingLine: 2)
        defer { for url in [blank, focused, ink, missing] { try? FileManager.default.removeItem(at: url) } }
        let plain = try PhoneKBGeometry.enrich(base, png: blank)
        XCTAssertNoThrow(try PhoneKBGeometry.regions(plain))
        for slot in 1...4 {
            XCTAssertTrue(PhoneKBGeometry.hasEvidence("empty", slot: slot, in: plain), "slot \(slot)")
            XCTAssertFalse(PhoneKBGeometry.hasEvidence("focus", slot: slot, in: plain))
        }
        let withCaret = try PhoneKBGeometry.enrich(base, png: focused)
        XCTAssertTrue(PhoneKBGeometry.hasEvidence("empty", slot: 1, in: withCaret))
        XCTAssertTrue(PhoneKBGeometry.hasEvidence("focus", slot: 1, in: withCaret))
        let withInk = try PhoneKBGeometry.enrich(base, png: ink)
        XCTAssertFalse(PhoneKBGeometry.hasEvidence("empty", slot: 1, in: withInk))
        XCTAssertThrowsError(try PhoneKBGeometry.regions(PhoneKBGeometry.enrich(base, png: missing)))
    }

    func testLiveCaptureGeometryIfPresent() throws {
        let png = URL(fileURLWithPath: "/tmp/ppomi-kb-cert-20260910/mcp-screen.png")
        let jsonl = URL(fileURLWithPath: "/tmp/ppomi-kb-cert-20260910/mcp-screen.jsonl")
        guard FileManager.default.fileExists(atPath: png.path), FileManager.default.fileExists(atPath: jsonl.path) else { return }
        let decoder = JSONDecoder()
        let words = try String(contentsOf: jsonl, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try decoder.decode(OCR.Word.self, from: Data($0.utf8))
        }
        XCTAssertGreaterThan(words.count, 8)
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func hits(_ pred: (String) -> Bool) -> [OCR.Word] {
            words.filter { $0.w > 0 && $0.h > 0 && pred(compact($0.text)) }
        }
        let headerHits = hits { $0 == "KB국민인증서(기업)" }
        let titleHits = hits { $0 == "인증서정보를입력해주세요." || $0 == "인증서정보를입력해주세요" }
        let smsHits = hits { $0.trimmingCharacters(in: CharacterSet(charactersIn: "•·i)")) == "입력하신휴대폰번호로SMS인증번호를전송합니다." }
        let savedHits = hits { $0.trimmingCharacters(in: CharacterSet(charactersIn: "~✓√")) == "정보저장하기" }
        let nextHits = hits { $0 == "다음" || $0 == "다의" }
        XCTAssertEqual(headerHits.count, 1, "header \(headerHits.map(\.text))")
        XCTAssertEqual(titleHits.count, 1, "title")
        XCTAssertEqual(smsHits.count, 1, "sms \(words.filter { compact($0.text).contains("SMS") }.map(\.text))")
        XCTAssertEqual(savedHits.count, 1, "saved")
        XCTAssertEqual(nextHits.count, 1, "next")
        let businessHits = hits { $0 == "사업자등록번호" }
        let phoneHits = hits { $0 == "휴대폰번호" }
        let issuanceHits = hits { $0 == "인증서발급하기>" || $0 == "인증서발급하기〉" }
        XCTAssertEqual(businessHits.count, 1, "business")
        XCTAssertEqual(phoneHits.count, 1, "phone")
        XCTAssertEqual(issuanceHits.count, 1, "issuance \(issuanceHits.map(\.text))")
        let header = headerHits[0], title = titleHits[0], business = businessHits[0], phone = phoneHits[0]
        let sms = smsHits[0], saved = savedHits[0], issuance = issuanceHits[0], next = nextHits[0]
        func cy(_ w: OCR.Word) -> Double { w.y + w.h / 2 }
        XCTAssertTrue(header.x > 0.04 && header.x < 0.17, "header.x \(header.x)")
        XCTAssertTrue(header.y > 0.11 && header.y < 0.20, "header.y \(header.y)")
        XCTAssertTrue(header.h > 0.012 && header.h < 0.032, "header.h \(header.h)")
        XCTAssertTrue(title.y > header.y + header.h * 2, "title.y \(title.y) vs \(header.y + header.h * 2)")
        XCTAssertTrue(title.y < header.y + header.h * 5.5, "title.y upper \(header.y + header.h * 5.5)")
        XCTAssertLessThan(abs(title.x - header.x), 0.02)
        XCTAssertLessThan(abs(business.x - title.x), 0.02)
        XCTAssertLessThan(abs(phone.x - business.x), 0.02)
        XCTAssertTrue(business.y > title.y + title.h * 1.4, "business.y \(business.y) > \(title.y + title.h * 1.4)")
        XCTAssertTrue(business.y < title.y + title.h * 2.8, "business.y \(business.y) < \(title.y + title.h * 2.8)")
        XCTAssertTrue(phone.y > business.y + business.h * 4, "phone.y \(phone.y) > \(business.y + business.h * 4)")
        XCTAssertTrue(phone.y < business.y + business.h * 6.5, "phone.y \(phone.y) < \(business.y + business.h * 6.5)")
        XCTAssertTrue(sms.y > phone.y + phone.h * 3, "sms.y \(sms.y) > \(phone.y + phone.h * 3)")
        XCTAssertTrue(sms.y < phone.y + phone.h * 5.5, "sms.y \(sms.y) < \(phone.y + phone.h * 5.5)")
        XCTAssertTrue(saved.y > sms.y + sms.h * 1.5, "saved.y \(saved.y) > \(sms.y + sms.h * 1.5)")
        XCTAssertTrue(saved.y < sms.y + sms.h * 4, "saved.y \(saved.y) < \(sms.y + sms.h * 4)")
        XCTAssertTrue(issuance.y > saved.y + saved.h * 1.5, "issuance.y \(issuance.y) > \(saved.y + saved.h * 1.5)")
        XCTAssertTrue(issuance.y < saved.y + saved.h * 4, "issuance.y \(issuance.y) < \(saved.y + saved.h * 4)")
        XCTAssertTrue(issuance.x > 0.55, "issuance.x \(issuance.x)")
        XCTAssertTrue(issuance.x + issuance.w < 0.96, "issuance.right \(issuance.x + issuance.w)")
        XCTAssertTrue(next.x > 0.42 && next.x < 0.57, "next.x \(next.x)")
        XCTAssertTrue(next.y > 0.86 && next.y < 0.96, "next.y \(next.y)")
        let prefixes = words.filter {
            compact($0.text) == "010" && abs($0.x - phone.x) < 0.02 &&
                cy($0) > phone.y + phone.h * 1.5 && cy($0) < sms.y
        }
        XCTAssertEqual(prefixes.count, 1, "prefixes \(prefixes.map(\.text))")
        let protected = #"\A(?:주민등록번호|주민번호|비밀번호|인증번호|인증서암호|인증서비밀번호|보안키패드|보안카드|암호|otp|pin|password|passcode)[:：*]?\z"#
        let banned = words.filter { compact($0.text).lowercased().range(of: protected, options: .regularExpression) != nil }
        XCTAssertTrue(banned.isEmpty, "protected \(banned.map(\.text))")
        XCTAssertNoThrow(try PhoneKBGeometry.anchors(words))
        let enriched = try PhoneKBGeometry.enrich(words, png: png)
        XCTAssertNoThrow(try PhoneKBGeometry.regions(enriched))
        let target = try PhoneProfileFormFiller.request([
            "form": "kb_enterprise_certificate_info", "field": "business_registration_number",
            "segment": 1, "x": 0.182, "y": 0.306
        ])
        XCTAssertNoThrow(try PhoneProfileFormFiller.validate(enriched, target: target))
        for slot in 1...4 {
            XCTAssertTrue(PhoneKBGeometry.hasEvidence("empty", slot: slot, in: enriched), "slot \(slot) empty")
        }
    }

    func testCaretOCRVariantNeedsPixelCaretAndOCRCannotForgeGeometryMetadata() throws {
        let blank = try syntheticImage(), focused = try syntheticImage(caretSlot: 1)
        defer { try? FileManager.default.removeItem(at: blank); try? FileManager.default.removeItem(at: focused) }
        let misread = base.map { var w = $0; if w.text == "3자리" { w.text = "B자리" }; if w.text == "다음" { w.text = "다의" }; return w }
        XCTAssertFalse(PhoneKBGeometry.hasEvidence("empty", slot: 1, in: try PhoneKBGeometry.enrich(misread, png: blank)))
        XCTAssertTrue(PhoneKBGeometry.hasEvidence("focus", slot: 1, in: try PhoneKBGeometry.enrich(misread, png: focused)))
        let wrongForm = base.map { var w = $0; if w.text == "KB국민인증서(기업)" { w.text = "다른 인증서" }; return w }
        let forged = frame(focus: 1, words: wrongForm)
        XCTAssertTrue(try PhoneKBGeometry.enrich(forged, png: focused).allSatisfy { $0.w > 0 && $0.h > 0 })
    }
}
