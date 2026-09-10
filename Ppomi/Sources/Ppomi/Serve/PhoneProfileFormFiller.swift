import Foundation
import CoreGraphics
import ImageIO

/// A local-only adapter for the observed KB enterprise-certificate information screen on iPhone.
/// Values never enter ordinary screenshots, tool arguments, logs, the clipboard, or model responses.
struct PhoneProfileFormFiller {
    enum Form: String { case kbEnterpriseCertificateInfo = "kb_enterprise_certificate_info", kbEnterprisePhoneIdentity = "kb_enterprise_phone_identity" }
    enum Field: String { case businessRegistrationNumber = "business_registration_number", phone, name }
    struct Target {
        let field: Field
        let x, y: Double
        let form: Form
        let segment: Int?
        init(field: Field, x: Double, y: Double, form: Form = .kbEnterpriseCertificateInfo, segment: Int? = nil) {
            self.field = field; self.x = x; self.y = y; self.form = form; self.segment = segment
        }
        var slot: Int { field == .phone ? 4 : segment ?? 0 }
    }
    var screen: () throws -> [OCR.Word] = { try Phone.privateScreen(windows: false, enrich: PhoneKBGeometry.enrich) }
    var click: (Double, Double) throws -> Void = { try Phone.tap($0, $1) }
    var typeDigits: (String) throws -> Void = {
        try Phone.run(["type-phone-digits-private"], windows: false, stdin: Data($0.utf8))
    }
    /// 두벌식 key letters for a Hangul name, typed through the Korean input source.
    var typeKeys: (String) throws -> Void = {
        try Phone.run(["type-phone-keys-private"], windows: false, stdin: Data($0.utf8))
    }
    var settle: () -> Void = { Thread.sleep(forTimeInterval: 0.4) }

    static func request(_ args: [String: Any]) throws -> Target {
        try ProfileTools.validateKeys(args, allowed: ["profile_id", "form", "field", "segment", "x", "y"])
        guard let rawForm = args["form"] as? String, let form = Form(rawValue: rawForm),
              let rawField = args["field"] as? String, let field = Field(rawValue: rawField),
              (field == .name) == (form == .kbEnterprisePhoneIdentity),
              let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              (0...1).contains(x.doubleValue), (0...1).contains(y.doubleValue) else { throw failure() }
        let segment: Int?
        if field == .businessRegistrationNumber {
            guard let value = args["segment"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue == Double(value.intValue), (1...3).contains(value.intValue) else {
                throw ProfileTools.Failure(message: "사업자등록번호의 세 칸은 segment 1·2·3으로 각각 지정해야 합니다.")
            }
            segment = value.intValue
        } else {
            guard args["segment"] == nil else { throw failure() }
            segment = nil
        }
        return Target(field: field, x: x.doubleValue, y: y.doubleValue, form: form, segment: segment)
    }

    fileprivate static func failure() -> ProfileTools.Failure {
        .init(message: "KB국민인증서(기업) 정보 화면의 입력 항목과 위치를 확인하지 못했습니다. 개인정보를 입력하지 않았습니다.")
    }

    static func validate(_ words: [OCR.Word], target: Target) throws {
        guard target.x.isFinite, target.y.isFinite, (0...1).contains(target.x), (0...1).contains(target.y),
              target.field == .phone ? target.segment == nil : (target.segment.map { (1...3).contains($0) } ?? false) else { throw failure() }
        _ = try PhoneKBGeometry.anchors(words)
        let regions = try PhoneKBGeometry.regions(words)
        guard let region = regions[target.slot], region.insetBy(dx: 0.005, dy: 0.002).contains(CGPoint(x: target.x, y: target.y)) else { throw failure() }
    }

    static func validateFocus(_ words: [OCR.Word], target: Target) throws {
        try validate(words, target: target)
        guard PhoneKBGeometry.hasEvidence("empty", slot: target.slot, in: words),
              PhoneKBGeometry.hasEvidence("focus", slot: target.slot, in: words),
              (1...4).filter({ PhoneKBGeometry.hasEvidence("focus", slot: $0, in: words) }).count == 1 else {
            throw ProfileTools.Failure(message: "해당 빈 입력칸의 파란 커서를 확인하지 못해 번호를 보내지 않았습니다. 자동 재입력하지 않습니다.")
        }
    }

    private static func value(_ profile: IdentityProfile, target: Target) throws -> String {
        let profile = try profile.validated()
        let value: String?
        switch target.field {
        case .businessRegistrationNumber:
            guard let segment = target.segment, (1...3).contains(segment) else { throw failure() }
            let spans = [0..<3, 3..<5, 5..<10]
            value = profile.businessRegistrationNumber.map { String(Array($0)[spans[segment - 1]]) }
        case .phone: value = profile.phone.map { String($0.dropFirst(3)) }
        case .name: value = profile.name
        }
        guard let value, !value.isEmpty else {
            throw ProfileTools.Failure(message: "이 프로필에 필요한 항목이 등록되어 있지 않습니다. 기본정보를 등록한 뒤 이어가세요.")
        }
        return value
    }

    private static func containsValue(_ value: String, words: [OCR.Word], target: Target) -> Bool {
        guard let regions = try? PhoneKBGeometry.regions(words), let region = regions[target.slot] else { return false }
        let matches = words.filter { word in
            guard word.w > 0, word.h > 0, word.y >= region.minY - 0.003,
                  word.y + word.h <= region.maxY + 0.003, word.x + word.w <= region.maxX + 0.003 else { return false }
            let text = word.text.filter { !$0.isWhitespace }
            if text == value { return word.x >= region.minX - 0.003 }
            // OCR may join a known separator and its following value, as it did with '- 2자리'.
            if target.field == .businessRegistrationNumber, let segment = target.segment, segment > 1,
               text == "-" + value, let previous = regions[segment - 1] {
                return word.x > previous.maxX && word.x < region.minX && word.x + word.w > region.minX
            }
            return false
        }
        return matches.count == 1
    }

    func fill(_ profile: IdentityProfile, target: Target) throws -> String {
        if target.form == .kbEnterprisePhoneIdentity { return try fillName(profile, target: target) }
        let value = try Self.value(profile, target: target)
        let before = try screen()
        try Self.validate(before, target: target)
        if Self.containsValue(value, words: before, target: target) {
            return try ProfileTools.json(["field": target.field.rawValue, "verified": true, "already_filled": true])
        }
        guard PhoneKBGeometry.hasEvidence("empty", slot: target.slot, in: before) else {
            throw ProfileTools.Failure(message: "입력칸의 빈 상태를 확인하지 못했습니다. 기존 값이나 마스킹된 내용을 덮어쓰지 않고 멈췄습니다.")
        }
        try click(target.x, target.y)
        settle()
        let focused = try screen()
        try Self.validateFocus(focused, target: target)
        // This driver sends only digit key events to an already-empty, focused iPhone field.
        try typeDigits(value)
        settle()
        let after = try screen()
        try Self.validate(after, target: target)
        guard Self.containsValue(value, words: after, target: target) else {
            throw ProfileTools.Failure(message: "번호 입력은 시도했지만 정확한 결과를 확인하지 못했습니다. 자동 재입력하지 말고 현재 인증 단계에서 확인해야 합니다.")
        }
        return try ProfileTools.json(["field": target.field.rawValue, "verified": true,
                                      "notice": "요청한 기본정보 칸만 입력했습니다. 다음·인증 요청·정보 저장 선택은 변경하지 않았습니다."])
    }

    // MARK: - 휴대폰 본인인증 name screen (single field)

    /// The one name row on the observed "휴대폰 본인인증" screen; nil unless every anchor is present exactly once.
    /// ponytail: OCR-only evidence (placeholder present / name present) — no underline or caret pixels; add PhoneKBGeometry-style
    /// pixel checks if a mistyped name ever shows up outside this row.
    static func nameRow(_ words: [OCR.Word]) throws -> CGRect {
        let compact = { (t: String) in t.filter { !$0.isWhitespace } }
        let visible = words.filter { $0.w > 0 && $0.h > 0 }
        func unique(_ test: (String) -> Bool) -> OCR.Word? {
            let matches = visible.filter { test(compact($0.text)) }
            return matches.count == 1 ? matches.first : nil
        }
        let protected = #"\A(?:주민등록번호|주민번호|비밀번호|인증번호|인증서암호|인증서비밀번호|보안키패드|보안카드|암호|otp|pin|password|passcode)[:：*]?\z"#
        guard let header = unique({ $0.contains("KB국민인증서(기업)발급") }),
              let title = unique({ $0 == "휴대폰본인인증" }),
              let prompt = unique({ $0 == "이름을입력해주세요." || $0 == "이름을입력해주세요" }),
              // The bottom "다음" button is replaced by the keyboard bar once the field has focus, so it is not an anchor.
              header.y > 0.11, header.y < 0.20, title.y > header.y + header.h, title.y < header.y + header.h * 5,
              prompt.y > title.y + title.h, prompt.y < title.y + title.h * 5, abs(prompt.x - title.x) < 0.02,
              !visible.contains(where: { compact($0.text).lowercased().range(of: protected, options: .regularExpression) != nil })
        else { throw failure() }
        // The small "이름" label sits right under the prompt; the field row (placeholder or typed name) is the row below it.
        let labels = visible.filter { compact($0.text) == "이름" && abs($0.x - prompt.x) < 0.02 && $0.y > prompt.y + prompt.h && $0.y < prompt.y + prompt.h * 4 }
        guard labels.count >= 1, let label = labels.min(by: { $0.y < $1.y }), label.h < prompt.h else { throw failure() }
        return CGRect(x: 0.06, y: label.y + label.h * 0.9, width: 0.86, height: label.h * 3.2)
    }

    private static func rowWords(_ words: [OCR.Word], _ row: CGRect) -> [OCR.Word] {
        words.filter { $0.w > 0 && $0.h > 0 && row.contains(CGPoint(x: $0.x + $0.w / 2, y: $0.y + $0.h / 2)) }
    }
    /// The blue caret in front of the grey placeholder makes OCR read "이름" as "ㅏ름" or "|이름".
    private static let placeholders: Set<String> = ["이름", "ㅏ름", "|이름", "l이름", "I이름", "1이름"]

    private func fillName(_ profile: IdentityProfile, target: Target) throws -> String {
        let name = try Self.value(profile, target: target)
        let keys = Phone.keys(for: name)
        guard keys.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
            throw ProfileTools.Failure(message: "한글 이름만 자동 입력할 수 있습니다. 이 이름은 당사자가 직접 입력해야 합니다.")
        }
        let compact = { (t: String) in t.filter { !$0.isWhitespace } }
        let before = try screen()
        let row = try Self.nameRow(before)
        guard row.contains(CGPoint(x: target.x, y: target.y)) else { throw Self.failure() }
        let rowBefore = Self.rowWords(before, row).map { compact($0.text) }
        if rowBefore == [compact(name)] {
            return try ProfileTools.json(["field": target.field.rawValue, "verified": true, "already_filled": true])
        }
        guard rowBefore.count == 1, Self.placeholders.contains(rowBefore[0]) else {
            throw ProfileTools.Failure(message: "입력칸의 빈 상태를 확인하지 못했습니다. 기존 값을 덮어쓰지 않고 멈췄습니다.")
        }
        try click(target.x, target.y)
        settle()
        try typeKeys(keys)
        settle()
        let after = try screen()
        let rowAfter = Self.rowWords(after, try Self.nameRow(after)).map { compact($0.text) }
        // The caret after the last syllable can change how OCR reads it ("석|" → "섹"); the leading syllables must match exactly.
        let expected = compact(name)
        guard rowAfter.count == 1, rowAfter[0].count == expected.count, rowAfter[0].dropLast() == expected.dropLast() else {
            throw ProfileTools.Failure(message: "이름 입력은 시도했지만 정확한 결과를 확인하지 못했습니다. 자동 재입력하지 말고 현재 화면에서 확인해야 합니다.")
        }
        return try ProfileTools.json(["field": target.field.rawValue, "verified": true,
                                      "notice": "이름 칸만 입력했습니다. 다음·인증 요청은 변경하지 않았습니다."])
    }
}

/// Positive underline, empty-content and blue-caret evidence, computed only while a private PNG is alive.
/// All injected metadata has zero area, which ordinary OCR words cannot impersonate.
enum PhoneKBGeometry {
    private static let prefix = "__ppomi_kb_phone_"
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func centerY(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
    struct Anchors {
        let header, title, business, phone, sms, next: OCR.Word
    }

    static func anchors(_ words: [OCR.Word]) throws -> Anchors {
        let visible = words.filter { $0.w > 0 && $0.h > 0 }
        func unique(_ test: (String) -> Bool) -> OCR.Word? {
            let matches = visible.filter { test(compact($0.text)) }
            return matches.count == 1 ? matches.first : nil
        }
        guard let header = unique({ $0 == "KB국민인증서(기업)" }),
              let title = unique({ $0 == "인증서정보를입력해주세요." || $0 == "인증서정보를입력해주세요" }),
              let business = unique({ $0 == "사업자등록번호" }), let phone = unique({ $0 == "휴대폰번호" }),
              let sms = unique({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "•·i)")) == "입력하신휴대폰번호로SMS인증번호를전송합니다." }),
              let saved = unique({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "~✓√")) == "정보저장하기" }),
              let issuance = unique({ $0 == "인증서발급하기>" || $0 == "인증서발급하기〉" }),
              let next = unique({ $0 == "다음" || $0 == "다의" }) else { throw PhoneProfileFormFiller.failure() }
        guard header.x > 0.04, header.x < 0.17, header.y > 0.11, header.y < 0.20,
              header.h > 0.012, header.h < 0.032,
              title.y > header.y + header.h * 2, title.y < header.y + header.h * 5.5,
              abs(title.x - header.x) < 0.02, abs(business.x - title.x) < 0.02, abs(phone.x - business.x) < 0.02,
              business.y > title.y + title.h * 1.4, business.y < title.y + title.h * 2.8,
              phone.y > business.y + business.h * 4, phone.y < business.y + business.h * 6.5,
              sms.y > phone.y + phone.h * 3, sms.y < phone.y + phone.h * 5.5,
              saved.y > sms.y + sms.h * 1.5, saved.y < sms.y + sms.h * 4,
              issuance.y > saved.y + saved.h * 1.5, issuance.y < saved.y + saved.h * 4,
              issuance.x > 0.55, issuance.x + issuance.w < 0.96,
              next.x > 0.42, next.x < 0.57, next.y > 0.86, next.y < 0.96 else { throw PhoneProfileFormFiller.failure() }
        let prefixes = visible.filter {
            compact($0.text) == "010" && abs($0.x - phone.x) < 0.02 &&
                centerY($0) > phone.y + phone.h * 1.5 && centerY($0) < sms.y
        }
        let protected = #"\A(?:주민등록번호|주민번호|비밀번호|인증번호|인증서암호|인증서비밀번호|보안키패드|보안카드|암호|otp|pin|password|passcode)[:：*]?\z"#
        guard prefixes.count == 1,
              !visible.contains(where: { compact($0.text).lowercased().range(of: protected, options: .regularExpression) != nil }) else {
            throw PhoneProfileFormFiller.failure()
        }
        return Anchors(header: header, title: title, business: business, phone: phone, sms: sms, next: next)
    }

    static func evidence(slot: Int, region: CGRect, empty: Bool, focused: Bool) -> [OCR.Word] {
        var result = [marker("start", slot: slot, point: CGPoint(x: region.minX, y: region.minY)),
                      marker("end", slot: slot, point: CGPoint(x: region.maxX, y: region.maxY))]
        let center = CGPoint(x: region.midX, y: region.midY)
        if empty { result.append(marker("empty", slot: slot, point: center)) }
        if focused { result.append(marker("focus", slot: slot, point: center)) }
        return result
    }

    private static func marker(_ kind: String, slot: Int, point: CGPoint) -> OCR.Word {
        .init(x: point.x, y: point.y, w: 0, h: 0, text: "\(prefix)\(slot)_\(kind)__")
    }

    private static func one(_ kind: String, slot: Int, in words: [OCR.Word]) -> OCR.Word? {
        let matches = words.filter { $0.w == 0 && $0.h == 0 && $0.text == "\(prefix)\(slot)_\(kind)__" }
        return matches.count == 1 ? matches.first : nil
    }

    static func hasEvidence(_ kind: String, slot: Int, in words: [OCR.Word]) -> Bool {
        guard let value = one(kind, slot: slot, in: words),
              let region = try? regions(words)[slot] else { return false }
        return abs(value.x - region.midX) < 0.002 && abs(value.y - region.midY) < 0.002
    }

    static func regions(_ words: [OCR.Word]) throws -> [Int: CGRect] {
        let anchor = try anchors(words)
        var result: [Int: CGRect] = [:]
        for slot in 1...4 {
            guard let start = one("start", slot: slot, in: words), let end = one("end", slot: slot, in: words),
                  [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
                  start.x > 0.04, end.x < 0.96, start.x < end.x, start.y < end.y,
                  end.y - start.y > 0.022, end.y - start.y < 0.055 else { throw PhoneProfileFormFiller.failure() }
            result[slot] = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
        }
        let a = result[1]!, b = result[2]!, c = result[3]!, phone = result[4]!
        guard abs(a.minX - anchor.business.x) < 0.02,
              a.width > 0.14, a.width < 0.25, abs(a.width - b.width) < 0.035,
              c.width > a.width * 1.3, c.width < a.width * 2,
              b.minX - a.maxX > 0.035, b.minX - a.maxX < 0.09,
              c.minX - b.maxX > 0.035, c.minX - b.maxX < 0.09,
              abs(a.minY - b.minY) < 0.005, abs(a.minY - c.minY) < 0.005,
              a.minY > anchor.business.y + anchor.business.h, a.maxY < anchor.phone.y,
              phone.minX > 0.35, phone.minX < 0.46, phone.width > 0.43, phone.width < 0.58,
              phone.minY > anchor.phone.y + anchor.phone.h - 0.003, phone.maxY < anchor.sms.y else { throw PhoneProfileFormFiller.failure() }
        return result
    }

    private struct Line {
        var left, right, top, bottom: Int
        var width: Int { right - left + 1 }
    }
    private struct Plane {
        let width, height: Int
        let rgba: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
        }
        func neutral(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return min(r, min(g, b)) >= 55 && max(r, max(g, b)) <= 230 && max(r, max(g, b)) - min(r, min(g, b)) <= 30
        }
        func blue(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return b >= 165 && b - r >= 55 && b - g >= 20
        }
        func white(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return min(r, min(g, b)) >= 235
        }
    }

    static func enrich(_ words: [OCR.Word], png: URL) throws -> [OCR.Word] {
        // Remove even malformed lookalike metadata before deriving new evidence from pixels.
        let clean = words.filter { !$0.text.hasPrefix(prefix) }
        guard let anchor = try? anchors(clean), let plane = read(png) else { return clean }
        let businessLines = lines(plane, from: anchor.business.y + anchor.business.h * 2,
                                  to: anchor.phone.y - anchor.phone.h * 0.35, minWidth: 0.14, maxWidth: 0.40)
        let phoneLines = lines(plane, from: anchor.phone.y + anchor.phone.h * 2,
                              to: anchor.sms.y, minWidth: 0.18, maxWidth: 0.60)
        guard businessLines.count == 3, phoneLines.count == 2 else { return clean }
        let lineGroups = [businessLines[0], businessLines[1], businessLines[2], phoneLines[1]]
        var regions: [Int: CGRect] = [:]
        for (index, line) in lineGroups.enumerated() {
            let height = index == 3 ? anchor.phone.h * 2.25 : anchor.business.h * 2.2
            regions[index + 1] = CGRect(x: Double(line.left) / Double(plane.width),
                                        y: Double(line.top) / Double(plane.height) - height,
                                        width: Double(line.width) / Double(plane.width), height: height - 0.002)
        }
        let firstPhone = phoneLines[0], secondPhone = phoneLines[1]
        guard abs(firstPhone.top - secondPhone.top) <= 3,
              Double(firstPhone.left) / Double(plane.width) > 0.05,
              Double(firstPhone.right) / Double(plane.width) < 0.40,
              secondPhone.left - firstPhone.right > Int(Double(plane.width) * 0.01) else { return clean }
        var result = clean
        for slot in 1...4 { result += evidence(slot: slot, region: regions[slot]!, empty: false, focused: false) }
        guard (try? self.regions(result)) != nil else { return clean }
        for slot in 1...4 {
            let region = regions[slot]!
            let state = content(plane, region: region, slot: slot, words: clean)
            let center = CGPoint(x: region.midX, y: region.midY)
            if state.empty { result.append(marker("empty", slot: slot, point: center)) }
            if state.focus { result.append(marker("focus", slot: slot, point: center)) }
        }
        return result
    }

    private static func lines(_ p: Plane, from: Double, to: Double, minWidth: Double, maxWidth: Double) -> [Line] {
        let minimum = Int(Double(p.width) * minWidth), maximum = Int(Double(p.width) * maxWidth)
        let start = max(1, Int(from * Double(p.height))), end = min(p.height - 2, Int(to * Double(p.height)))
        guard start < end else { return [] }
        var result: [Line] = []
        for y in start...end {
            var x = Int(Double(p.width) * 0.05)
            let limit = Int(Double(p.width) * 0.95)
            while x < limit {
                guard p.neutral(x, y) else { x += 1; continue }
                let left = x
                while x < limit && p.neutral(x, y) { x += 1 }
                let right = x - 1, width = right - left + 1
                guard width >= minimum, width <= maximum else { continue }
                if let i = result.firstIndex(where: {
                    let shorter = min($0.width, width), longer = max($0.width, width)
                    let overlap = min($0.right, right) - max($0.left, left) + 1
                    return y - $0.bottom <= 2 && Double(shorter) / Double(longer) >= 0.90 &&
                        Double(overlap) / Double(shorter) >= 0.95 &&
                        abs($0.left - left) <= max(3, shorter / 12) && abs($0.right - right) <= max(3, shorter / 12)
                }) {
                    // Antialiasing shortens the outer row of the same underline; keep its full observed extent.
                    result[i].left = min(result[i].left, left); result[i].right = max(result[i].right, right)
                    result[i].bottom = y
                } else { result.append(Line(left: left, right: right, top: y, bottom: y)) }
            }
        }
        return result.filter { $0.bottom - $0.top <= 4 }.sorted { $0.left < $1.left }
    }

    private static func content(_ p: Plane, region: CGRect, slot: Int, words: [OCR.Word]) -> (empty: Bool, focus: Bool) {
        let expected = slot == 1 ? ["3자리", "B자리"] : slot == 2 ? ["2자리", "-2자리"] : ["5자리", "-5자리"]
        let placeholders = slot == 4 ? [] : words.filter {
            $0.w > 0 && expected.contains(compact($0.text)) &&
                centerY($0) >= region.minY && centerY($0) <= region.maxY &&
                $0.x + $0.w > region.minX && $0.x + $0.w < region.maxX + 0.015
        }
        if slot != 4 && placeholders.count != 1 { return (false, false) }
        let placeholder = placeholders.first.map {
            CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h).insetBy(dx: -0.005, dy: -0.003)
        }
        let left = max(0, Int(ceil(region.minX * Double(p.width)))), right = min(p.width - 1, Int(floor(region.maxX * Double(p.width))) - 1)
        let top = max(0, Int(ceil(region.minY * Double(p.height)))), bottom = min(p.height - 1, Int(floor(region.maxY * Double(p.height))))
        guard left < right, top < bottom else { return (false, false) }
        var blue: [(Int, Int)] = [], unknownInk = false
        for y in top...bottom { for x in left...right {
            if p.blue(x, y) { blue.append((x, y)); continue }
            let point = CGPoint(x: Double(x) / Double(p.width), y: Double(y) / Double(p.height))
            if !p.white(x, y), placeholder?.contains(point) != true { unknownInk = true }
        } }
        var focused = false
        if let minX = blue.map({ $0.0 }).min(), let maxX = blue.map({ $0.0 }).max(),
           let minY = blue.map({ $0.1 }).min(), let maxY = blue.map({ $0.1 }).max() {
            let width = maxX - minX + 1, height = maxY - minY + 1
            focused = width <= max(3, (bottom - top) / 7) && height >= (bottom - top) / 2 &&
                height <= bottom - top + 1 && minX - left <= max(5, (bottom - top) / 4) &&
                Double(blue.count) / Double(width * height) >= 0.65
        }
        // The B자리 OCR variant is accepted only when a real blue caret explains the added stroke.
        let caretExplainsPlaceholder = placeholders.first.map { compact($0.text) != "B자리" || focused } ?? true
        return (!unknownInk && (blue.isEmpty || focused) && caretExplainsPlaceholder, focused && !unknownInk)
    }

    private static func read(_ url: URL) -> Plane? {
        guard url.isFileURL, let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= 20_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width >= 160, image.height >= 300,
              image.width * image.height <= 16_777_216 else { return nil }
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let rendered = rgba.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return rendered ? Plane(width: image.width, height: image.height, rgba: rgba) : nil
    }
}
