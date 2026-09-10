import Foundation

/// Evidence for an observed membership-type navigation screen, never for enrollment or payment.
/// This is evaluated against the fresh Windows capture used by the click; callers cannot assert a role or approval.
enum SignupNavigation {
    static func eaisMemberType(for target: OCR.Word, in words: [OCR.Word]) -> String? {
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func cx(_ word: OCR.Word) -> Double { word.x + word.w / 2 }
        func cy(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
        func valid(_ word: OCR.Word) -> Bool {
            [word.x, word.y, word.w, word.h].allSatisfy(\.isFinite) &&
                word.x >= 0 && word.y >= 0 && word.w > 0 && word.h > 0 &&
                word.x + word.w <= 1 && word.y + word.h <= 1
        }
        func unique(_ label: String, below minimumY: Double = 0, terminalPeriod: Bool = false) -> OCR.Word? {
            let matches = words.filter {
                let text = compact($0.text)
                return $0.y > minimumY && (text == label || (terminalPeriod && text == label + "."))
            }
            return matches.count == 1 && matches.allSatisfy(valid) ? matches.first : nil
        }
        guard compact(target.text) == "가입하기", valid(target), words.filter({ $0 == target }).count == 1,
              let heading = unique("건축행정시스템", below: 0.25),
              let welcome = unique("세움터에오신것을환영합니다", below: 0.25, terminalPeriod: true),
              let personal = unique("일반회원"), let business = unique("사업자회원"),
              let personLabel = unique("개인사용자"), let businessLabel = unique("사업자(개인및법인)"),
              heading.y > 0.25, heading.y + heading.h < welcome.y,
              welcome.y + welcome.h < min(personLabel.y, businessLabel.y) else { return nil }

        // An exact URL in browser chrome is required. A body URL, lookalike host, nested URL, or later signup step is not evidence.
        let addresses = words.filter { word in
            valid(word) && word.y >= 0.03 && word.y < 0.25 && word.y + word.h < heading.y &&
                word.text.trimmingCharacters(in: .whitespacesAndNewlines).contains("://")
        }
        guard addresses.count == 1, let address = addresses.first else { return nil }
        var addressText = address.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Edge's lock glyph was observed as an isolated "a" joined to the URL by Vision.
        // Accept only that exact observed prefix; arbitrary leading text and nested URLs still fail.
        if addressText.hasPrefix("a https://") { addressText.removeFirst(2) }
        guard let url = URLComponents(string: addressText),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "www.eais.go.kr",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.percentEncodedPath == "/moct/awp/aba01/AWPABA01F01", url.query == nil, url.fragment == nil else { return nil }

        // The two observed cards establish both the current stage and the selected button's column.
        guard abs(cy(personLabel) - cy(businessLabel)) <= max(personLabel.h, businessLabel.h),
              abs(cy(personal) - cy(business)) <= max(personal.h, business.h),
              cx(business) - cx(personal) > max(0.10, 4 * max(personal.h, business.h)),
              personLabel.y + personLabel.h < personal.y, businessLabel.y + businessLabel.h < business.y,
              personal.y - personLabel.y < 0.12, business.y - businessLabel.y < 0.12,
              abs(cx(personLabel) - cx(personal)) <= max(0.04, personLabel.w / 2),
              abs(cx(businessLabel) - cx(business)) <= max(0.04, businessLabel.w / 2) else { return nil }

        // Later forms and explicit financial/finalization controls remain protected even if stale card text is still visible.
        let forbidden = "결제|구매|주문|송금|이체|입금|충전|구독|비밀번호|아이디|약관동의|전체동의|개인정보수집|가입완료|최종가입|회원정보입력|사업자등록번호"
        guard !words.contains(where: { $0.y >= heading.y && compact($0.text).range(of: forbidden, options: .regularExpression) != nil }) else { return nil }
        let buttons = words.filter { compact($0.text) == "가입하기" }
        guard buttons.count == 2, buttons.allSatisfy(valid),
              abs(cy(buttons[0]) - cy(buttons[1])) <= max(buttons[0].h, buttons[1].h) else { return nil }
        func button(below title: OCR.Word) -> OCR.Word? {
            let matches = buttons.filter {
                $0.y > title.y + title.h && $0.y - title.y < 0.18 &&
                    abs(cx($0) - cx(title)) <= max(0.04, title.w / 2)
            }
            return matches.count == 1 ? matches.first : nil
        }
        guard let personalButton = button(below: personal), let businessButton = button(below: business),
              personalButton != businessButton else { return nil }
        if target == personalButton { return "일반회원" }
        if target == businessButton { return "사업자회원" }
        return nil
    }
}
