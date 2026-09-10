import Foundation

/// Deliberately bounded form adapters. Identity stays inside the local app, including verification OCR.
/// The agent supplies an observed field location; this adapter validates the site, form and row before using it.
struct ProfileFormFiller {
    enum Form: String {
        case eaisPASS = "eais_pass", eaisBusiness = "eais_business", kbIDLookup = "kb_id_lookup", kbCertificate = "kb_certificate_identity"

        func supports(_ field: Field) -> Bool {
            switch self {
            case .eaisPASS: return [.name, .birthDate, .phone, .carrier].contains(field)
            case .eaisBusiness: return [.businessName, .businessRegistrationNumber].contains(field)
            case .kbIDLookup: return [.bankCustomerName, .birthDate, .bankAccountNumber].contains(field)
            case .kbCertificate: return field == .businessRegistrationNumber   // KB 기업 인증서 발급 1단계의 사업자등록번호 세 칸만
            }
        }
    }
    enum Field: String, CaseIterable {
        case name, birthDate = "birth_date", phone, carrier
        case businessName = "business_name", businessRegistrationNumber = "business_registration_number"
        case bankCustomerName = "bank_customer_name", bankAccountNumber = "bank_account_number"
        var isBusiness: Bool { self == .businessName || self == .businessRegistrationNumber }
    }
    struct Target {
        let field: Field
        let x: Double
        let y: Double
        let form: Form
        let segment: Int?
        let bankID: String?
        init(field: Field, x: Double, y: Double, form: Form = .eaisPASS, segment: Int? = nil, bankID: String? = nil) {
            self.field = field; self.x = x; self.y = y; self.form = form; self.segment = segment; self.bankID = bankID
        }
    }
    var screen: () throws -> [OCR.Word] = { try Desk.privateScreen(enrich: BusinessFormGeometry.enrich) }
    var click: (Double, Double) throws -> Void = { try Desk.click($0, $1) }
    var key: (String) throws -> Void = { try Desk.key($0) }
    var type: (String) throws -> Void = { try Desk.typePrivate($0) }
    var typeDigits: (String) throws -> Void = { try Desk.typeDigitsPrivate($0) }
    var inputFocus: (Target) throws -> Bool = { target in
        try Desk.privateInputFocus(x: target.x, y: target.y,
                                   enrich: target.form == .eaisBusiness || target.form == .kbCertificate ? BusinessFormGeometry.enrich : nil,
                                   focusMinimums: target.form == .kbCertificate ? (0.025, 0.02) : (0.05, 0.025)) { words in
            let region = ProfileFormFiller.region(words, target: target)
            do {
                try ProfileFormFiller.validate(words, target: target)
                try ProfileFormFiller.requireEmptyBusinessNumber(words, target: target)
                if let region { ProfileFormFiller.onRegion?(region, true) }
            } catch {
                // The rejected box (or the requested point when no box was found) is worth showing; the words are not.
                ProfileFormFiller.onRegion?(region ?? CGRect(x: target.x - 0.05, y: target.y - 0.015, width: 0.1, height: 0.03), false)
                throw error
            }
        }
    }
    /// Geometry only (0~1), for a host that draws over the controlled window; nil when the form has no box finder.
    static var onRegion: ((CGRect, Bool) -> Void)?
    static func region(_ words: [OCR.Word], target: Target) -> CGRect? {
        switch target.form {
        case .eaisBusiness: return try? businessRegion(words, target: target)
        case .kbIDLookup: return try? KBIdentityFormGeometry.region(words, target: target)
        case .kbCertificate: return try? KBCertificateFormGeometry.region(words, target: target)
        case .eaisPASS: return nil
        }
    }
    var settle: () -> Void = { Thread.sleep(forTimeInterval: 0.6) }

    static func request(_ a: [String: Any]) throws -> Target {
        try ProfileTools.validateKeys(a, allowed: ["profile_id", "form", "field", "segment", "bank_id", "x", "y"])
        guard let form = (a["form"] as? String).flatMap(Form.init(rawValue:)),
              let field = (a["field"] as? String).flatMap(Field.init(rawValue:)),
              form.supports(field),
              let x = a["x"] as? NSNumber, let y = a["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              (0...1).contains(x.doubleValue), (0...1).contains(y.doubleValue) else {
            throw ProfileTools.Failure(message: "지원하는 양식에 맞는 기본정보 필드와 최신 화면의 x·y 좌표가 필요합니다.")
        }
        let bankID: String?
        if form == .kbIDLookup {
            guard a["bank_id"] as? String == "kb" else {
                throw ProfileTools.Failure(message: "KB ID 조회는 bank_id를 kb로 지정해야 합니다.")
            }
            bankID = "kb"
        } else {
            guard a["bank_id"] == nil else {
                throw ProfileTools.Failure(message: "bank_id는 지원하는 은행 양식에만 지정할 수 있습니다.")
            }
            bankID = nil
        }
        let segment: Int?
        if field == .businessRegistrationNumber {
            guard let n = a["segment"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue == Double(n.intValue), (1...3).contains(n.intValue) else {
                throw ProfileTools.Failure(message: "사업자등록번호는 세 입력칸 중 segment 1·2·3을 지정해야 합니다.")
            }
            segment = n.intValue
        } else {
            guard a["segment"] == nil else { throw ProfileTools.Failure(message: "segment는 사업자등록번호 입력에만 지정할 수 있습니다.") }
            segment = nil
        }
        return Target(field: field, x: x.doubleValue, y: y.doubleValue, form: form, segment: segment, bankID: bankID)
    }

    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace }.lowercased() }
    private static func centerY(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
    private static let carriers = ["skt": "SKT", "kt": "KT", "lgu": "LGU+", "skt_mvno": "SKT알뜰폰", "kt_mvno": "KT알뜰폰", "lgu_mvno": "LGU+알뜰폰"]

    /// The selected method sits above the unique form title in the same right-hand panel.
    /// Provider-list labels sit beside or below the title and are not evidence of the selected method.
    private static func selectedPASSHeader(_ words: [OCR.Word]) -> OCR.Word? {
        let titles = words.filter { compact($0.text) == "본인인증정보입력" }
        guard titles.count == 1, let title = titles.first, title.x > 0.30 else { return nil }
        let headers = words.filter { header in
            guard compact(header.text) == "통신사pass", header.x > 0.30 else { return false }
            let textHeight = max(title.h, header.h)
            let gap = title.y - (header.y + header.h)
            return textHeight > 0 && gap > 0 && gap <= textHeight * 6 &&
                header.x >= title.x - textHeight && header.x < title.x + title.w &&
                header.x + header.w <= title.x + title.w + textHeight
        }
        return headers.count == 1 ? headers.first : nil
    }

    /// The PASS form's own panel, measured in its title's text height: the modal is a fixed-size box around that title.
    /// Page text outside it (the login page's "아이디와 비밀번호를 이용" showing beside the modal) says nothing about this form.
    private static func formTitle(_ words: [OCR.Word]) -> OCR.Word? {
        let titles = words.filter { compact($0.text) == "본인인증정보입력" }
        guard titles.count == 1, let title = titles.first, title.h > 0 else { return nil }
        return title
    }
    private static func formPanel(_ title: OCR.Word) -> CGRect {
        let h = title.h
        return CGRect(x: title.x - 2 * h, y: title.y - 8 * h, width: 16 * h, height: 32 * h)
    }

    /// Address-bar evidence is restricted to the browser chrome above the page: above the selected-method header, in the
    /// top third of the window (the chrome's share grows as the window shrinks). Page text mentioning the domain sits below.
    /// Protected-input words (비밀번호, 인증번호, …) block only when they sit inside the form panel itself.
    static func validate(_ words: [OCR.Word], target: Target) throws {
        guard target.x.isFinite, target.y.isFinite, (0...1).contains(target.x), (0...1).contains(target.y),
              target.form.supports(target.field),
              target.form == .kbIDLookup ? target.bankID == "kb" : target.bankID == nil,
              target.field == .businessRegistrationNumber ? (target.segment.map { (1...3).contains($0) } ?? false) : target.segment == nil else {
            throw ProfileTools.Failure(message: "양식·필드·입력칸 요청이 일치하지 않습니다. 개인정보를 입력하지 않았습니다.")
        }
        if target.form == .eaisBusiness { _ = try businessRegion(words, target: target); return }
        if target.form == .kbIDLookup { _ = try KBIdentityFormGeometry.region(words, target: target); return }
        if target.form == .kbCertificate { _ = try KBCertificateFormGeometry.region(words, target: target); return }
        let title = formTitle(words), panel = title.map(formPanel), header = selectedPASSHeader(words)
        guard let title, let header, words.contains(where: { word in
            guard word.y >= 0.03, word.y < 0.34, word.y + word.h <= header.y,
                  let start = word.text.range(of: "https://", options: .caseInsensitive)?.lowerBound,
                  let token = word.text[start...].split(whereSeparator: \.isWhitespace).first,
                  let url = URLComponents(string: String(token)) else { return false }
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.eais.go.kr" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
        }),
              let panel,
              !words.contains(where: { panel.contains(CGPoint(x: $0.x + $0.w / 2, y: centerY($0))) && compact($0.text).range(of: "비밀번호|인증번호|인증서암호|보안키패드|카드번호|주민등록번호|주민번호|password|passcode|\\b(?:otp|pin)\\b", options: .regularExpression) != nil }) else {
            throw ProfileTools.Failure(message: "세움터 주소와 통신사 PASS 기본정보 양식을 확인할 수 없습니다. 입력하지 않았습니다.")
        }
        let label = target.field == .name ? "이름" : target.field == .birthDate ? "생년월일" : "휴대폰번호"
        // Row labels share the title's left column; a browser tooltip repeating the label under the input does not.
        let labels = words.filter { compact($0.text) == label && abs($0.x - title.x) <= 2 * title.h && panel.contains(CGPoint(x: $0.x + $0.w / 2, y: centerY($0))) }
        guard labels.count == 1, let row = labels.first,
              abs(centerY(row) - target.y) <= max(0.022, row.h),
              target.x > row.x + row.w + 0.035, target.x < 0.94 else {
            throw ProfileTools.Failure(message: "입력 위치가 요청한 기본정보 항목과 맞지 않습니다. 최신 화면에서 입력칸을 다시 확인해 주세요.")
        }
        if target.field == .phone || target.field == .carrier {
            let prefixes = words.filter { compact($0.text) == "010" && abs(centerY($0) - centerY(row)) < 0.025 && $0.x > row.x + row.w }
            guard prefixes.count == 1, let prefix = prefixes.first,
                  target.field == .phone ? target.x > prefix.x + prefix.w + 0.018 : target.x < prefix.x - 0.015 else {
                throw ProfileTools.Failure(message: "휴대폰 번호의 010 영역과 통신사·뒷번호 입력칸을 구분할 수 없습니다.")
            }
        }
    }

    /// The observed EAIS business page places both labels on one row, followed by three registration-number boxes.
    /// Two visible separators establish the segment ordering; an absent/merged OCR separator is insufficient evidence.
    /// This adapter never guesses the intended box from the agent's segment number alone.
    private static func businessRegion(_ words: [OCR.Word], target: Target) throws -> CGRect {
        let names = words.filter { word in
            target.field == .businessRegistrationNumber ? BusinessFormGeometry.isBusinessNameAnchor(word) : compact(word.text) == "사업자명"
        }
        let numbers = words.filter { compact($0.text) == "사업자등록번호" }
        guard names.count == 1, numbers.count == 1, let name = names.first, let number = numbers.first,
              name.h > 0, number.h > 0, name.x >= 0, name.x < 0.35,
              number.x > name.x + name.w + name.h, number.x < 0.80,
              abs(centerY(name) - centerY(number)) <= max(name.h, number.h),
              name.y > 0.18, name.y < 0.70,
              words.contains(where: { word in
                  let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard word.y >= 0.03, word.y < 0.25, word.y + word.h < min(name.y, number.y),
                        let start = text.range(of: "https://", options: .caseInsensitive)?.lowerBound,
                        let token = text[start...].split(whereSeparator: \.isWhitespace).first,
                        let url = URLComponents(string: String(token)) else { return false }
                  return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.eais.go.kr" &&
                      url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
                      url.percentEncodedPath == "/moct/awp/aba01/AWPABA01F04" && url.fragment == nil
              }) else {
            throw ProfileTools.Failure(message: "세움터 사업자인증의 정확한 주소와 사업자명·등록번호 행을 확인할 수 없습니다. 입력하지 않았습니다.")
        }
        let rowY = centerY(number), height = max(name.h, number.h), tolerance = max(0.014, height)
        if words.contains(where: { compact($0.text) == "알림" }) &&
            words.contains(where: { compact($0.text).trimmingCharacters(in: CharacterSet(charactersIn: ".。")) == "숫자만입력가능합니다" }) {
            throw ProfileTools.Failure(message: "세움터의 ‘숫자만 입력 가능합니다’ 알림이 열려 있습니다. 알림을 닫고 입력칸을 다시 확인해야 합니다. 개인정보를 입력하지 않았습니다.")
        }
        // Short credential labels identify a different active dialog. The page's explanatory paragraph mentioning
        // 주민등록번호 below this row is not a credential input and must not reject a valid business form.
        let credentialLabel = #"^(?:비밀번호|인증서암호|인증서비밀번호|인증번호|암호|보안키패드|password|passcode|otp|pin|인증서선택|공동인증서선택)[:：*]?$"#
        guard !words.contains(where: { word in
            let text = compact(word.text)
            return text.range(of: credentialLabel, options: .regularExpression) != nil ||
                (abs(centerY(word) - rowY) <= tolerance * 2 &&
                 text.range(of: #"^(?:주민등록번호|주민번호|카드번호)[:：*]?$"#, options: .regularExpression) != nil)
        }) else {
            throw ProfileTools.Failure(message: "인증서·비밀번호 등 보호된 입력 화면이 보여 사업자 기본정보를 보내지 않았습니다.")
        }
        let row = target.field == .businessName ? name : number
        guard abs(centerY(row) - target.y) <= tolerance else {
            throw ProfileTools.Failure(message: "요청 좌표가 사업자 기본정보 행과 맞지 않습니다. 입력하지 않았습니다.")
        }
        let left: Double, right: Double
        if target.field == .businessName {
            left = name.x + name.w + height * 0.35
            right = number.x - height
        } else {
            let separators = words.filter { word in
                ["-", "−", "–", "—"].contains(compact(word.text)) && word.w > 0 && word.w <= height &&
                    word.x > number.x + number.w && abs(centerY(word) - rowY) <= tolerance
            }.sorted { $0.x < $1.x }
            guard separators.count == 2, let segment = target.segment, (1...3).contains(segment) else {
                throw ProfileTools.Failure(message: "사업자등록번호의 세 칸을 나누는 두 구분선을 확인하지 못했습니다. 번호를 입력하지 않았습니다.")
            }
            let first = separators[0], second = separators[1]
            let pitch = second.x - first.x
            guard pitch > height * 2, pitch < 0.30,
                  first.x - (number.x + number.w) > height,
                  second.x + second.w + height < 1 else {
                throw ProfileTools.Failure(message: "사업자등록번호 입력칸의 배열이 확인된 양식과 다릅니다. 번호를 입력하지 않았습니다.")
            }
            // The known form uses three equal-width boxes. Bound the outer slots by the observed separator pitch;
            // focus-outline evidence must still prove the point is inside the requested input before private typing.
            switch segment {
            case 1: left = max(number.x + number.w + height * 0.35, first.x - pitch + first.w); right = first.x - height * 0.20
            case 2: left = first.x + first.w + height * 0.20; right = second.x - height * 0.20
            default: left = second.x + second.w + height * 0.20; right = min(0.995, second.x + pitch)
            }
        }
        guard left < right, target.x > left, target.x < right else {
            throw ProfileTools.Failure(message: "요청한 사업자 필드·번호 구간과 실제 입력 위치가 다릅니다. 입력하지 않았습니다.")
        }
        return CGRect(x: left, y: centerY(row) - tolerance, width: right - left, height: tolerance * 2)
    }

    private static func value(_ profile: IdentityProfile, target: Target) throws -> String {
        let value: String?
        switch target.field {
        case .name: value = profile.name
        case .birthDate:
            let digits = profile.birthDate?.replacingOccurrences(of: "-", with: "")
            value = target.form == .kbIDLookup ? digits.map { String($0.suffix(6)) } : digits
        case .phone: value = profile.phone.map { String($0.dropFirst(3)) }
        case .carrier: value = profile.carrier.flatMap { carriers[$0] }
        case .businessName: value = profile.businessName
        case .bankCustomerName: value = target.bankID.flatMap { profile.bankProfiles?[$0]?.customerName }
        case .bankAccountNumber: value = target.bankID.flatMap { profile.bankProfiles?[$0]?.accountNumber }
        case .businessRegistrationNumber:
            guard let segment = target.segment, (1...3).contains(segment) else {
                throw ProfileTools.Failure(message: "사업자등록번호 입력 구간이 필요합니다.")
            }
            let number = profile.businessRegistrationNumber?.replacingOccurrences(of: "-", with: "")
            let ranges = [0..<3, 3..<5, 5..<10]
            value = number.flatMap { $0.count == 10 ? String(Array($0)[ranges[segment - 1]]) : nil }
        }
        guard let value, !value.isEmpty else { throw ProfileTools.Failure(message: "이 프로필에는 요청한 항목이 아직 없습니다. 대화에서 등록하거나 설정에서 추가해 주세요.") }
        return value
    }

    private static func containsValue(_ value: String, in words: [OCR.Word], target: Target) -> Bool {
        if target.form == .kbIDLookup {
            guard let region = try? KBIdentityFormGeometry.region(words, target: target) else { return false }
            // Spaces are significant in the saved bank customer name; do not substitute an inferred spelling.
            let matches = words.filter { word in
                word.text.trimmingCharacters(in: .whitespacesAndNewlines) == value && word.w > 0 &&
                    word.x >= region.minX && word.x + word.w <= region.maxX &&
                    region.contains(CGPoint(x: word.x + word.w / 2, y: centerY(word)))
            }
            return matches.count == 1
        }
        if target.form == .kbCertificate {   // 칸이 마스킹되지 않아 세 구간 모두 상자 안의 숫자로 확인한다. OCR 이 구분선과 붙여 읽을 수 있어("- 32") 숫자만 비교하고 가로 겹침으로 칸을 정한다
            guard let region = try? KBCertificateFormGeometry.region(words, target: target) else { return false }
            return words.filter { word in
                word.text.filter(\.isNumber) == value && word.w > 0 && word.x < region.maxX && word.x + word.w > region.minX &&
                    abs(centerY(word) - region.midY) < region.height
            }.count == 1
        }
        if target.form == .eaisBusiness {
            guard let region = try? businessRegion(words, target: target) else { return false }
            let matches = words.filter { word in
                compact(word.text) == compact(value) && word.w > 0 &&
                    word.x >= region.minX && word.x + word.w <= region.maxX &&
                    region.contains(CGPoint(x: word.x + word.w / 2, y: centerY(word)))
            }
            return matches.count == 1
        }
        return words.contains { abs(centerY($0) - target.y) < 0.027 && $0.x > 0.53 && compact($0.text) == compact(value) }
    }

    private static func requireEmptyBusinessNumber(_ words: [OCR.Word], target: Target) throws {
        if target.field == .businessRegistrationNumber,
           !BusinessFormGeometry.hasEmptyEvidence(words, segment: target.segment ?? 0, x: target.x, y: target.y) {
            throw ProfileTools.Failure(message: "번호 칸의 빈 상태를 다시 확인하지 못했습니다. 새 내용이나 마스킹된 값을 덮어쓰지 않고 멈췄습니다.")
        }
    }

    func fill(_ profile: IdentityProfile, target: Target) throws -> String {
        let value = try Self.value(profile.validated(), target: target)
        let before = try screen()
        do { try Self.validate(before, target: target) } catch {
            Self.onRegion?(Self.region(before, target: target) ?? CGRect(x: target.x - 0.05, y: target.y - 0.015, width: 0.1, height: 0.03), false)
            throw error
        }
        let maskedBusinessNumber = target.form == .eaisBusiness && target.field == .businessRegistrationNumber && (target.segment ?? 0) > 1
        if !maskedBusinessNumber && Self.containsValue(value, in: before, target: target) {
            return try ProfileTools.json(["field": target.field.rawValue, "verified": true, "already_filled": true])
        }
        if target.field == .businessRegistrationNumber,
           !BusinessFormGeometry.hasEmptyEvidence(before, segment: target.segment ?? 0, x: target.x, y: target.y) {
            return try ProfileTools.json(["field": target.field.rawValue, "segment": target.segment ?? 0,
                "input_attempted": false, "value_verified": false, "requires_site_verification": true,
                "existing_content_or_unknown": true,
                "notice": "번호 칸이 비어 있다는 화면 증거가 없어 재입력하지 않았습니다. 마스킹된 값은 원문과 비교할 수 없으므로 사이트에서 확인해야 합니다."])
        }
        try click(target.x, target.y)
        settle()
        let focused = try screen()
        try Self.validate(focused, target: target) // navigation, resize or a new authentication step stops the operation
        try Self.requireEmptyBusinessNumber(focused, target: target) // autocomplete or delayed updates must not be overwritten
        if target.field == .carrier {
            let choices = focused.filter { Self.compact($0.text) == Self.compact(value) && $0.x > 0.50 && $0.x < 0.82 && $0.y > target.y && $0.y < target.y + 0.32 }
            guard choices.count == 1, let choice = choices.first else {
                throw ProfileTools.Failure(message: "통신사 선택 메뉴를 확인하지 못했습니다. 선택을 반복하지 않고 멈췄습니다.")
            }
            try click(choice.x + choice.w / 2, choice.y + choice.h / 2)
        } else {
            guard try inputFocus(target) else {
                throw ProfileTools.Failure(message: "요청한 입력칸의 포커스 테두리를 확인하지 못해 개인정보를 보내지 않았습니다. 화면을 다시 확인해 주세요.")
            }
            if target.field == .businessRegistrationNumber {
                // EAIS rejects Control, A and V in its keydown filter. This private driver uses only
                // Home/Delete and digit key events; it does not paste or activate modifier shortcuts.
                try typeDigits(value)
            } else {
                try key("ctrl+a")
                try type(value)
            }
        }
        settle()
        let after = try screen()
        try Self.validate(after, target: target)
        if maskedBusinessNumber {
            return try ProfileTools.json(["field": target.field.rawValue, "segment": target.segment ?? 0,
                "input_attempted": true, "value_verified": false, "requires_site_verification": true,
                "notice": "저장된 번호 구간의 숫자키 입력을 보냈습니다. 이 칸은 마스킹되어 원문이나 정확한 입력 결과를 검증하지 못했습니다. 자동 재입력하지 말고 사이트 인증 결과로 확인해야 합니다."])
        }
        guard Self.containsValue(value, in: after, target: target) else {
            throw ProfileTools.Failure(message: "입력은 시도했지만 화면에서 결과를 확인하지 못했습니다. 자동으로 재입력하지 않았습니다.")
        }
        return try ProfileTools.json(["field": target.field.rawValue, "verified": true,
                                     "notice": target.form == .kbIDLookup
                                        ? "요청한 기본정보만 입력했습니다. 계좌 비밀번호 입력과 ID 조회 확인은 진행하지 않았습니다."
                                        : target.form == .kbCertificate
                                        ? "사업자등록번호 구간만 입력했습니다. 사용자 ID·주민등록번호·약관 동의·본인확인 요청은 진행하지 않았습니다."
                                        : "기본정보만 입력했습니다. 약관 동의·인증 요청·휴대폰 인증은 진행하지 않았습니다."])
    }
}
