import Foundation

/// The observed KB enterprise ID-lookup popup, not the certificate issuance page behind it.
/// OCR establishes the exact origin and individual-business rows; the private focus check must
/// independently prove the requested point is inside a focused input before any text is sent.
enum KBIdentityFormGeometry {
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func centerY(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
    private static func failure() -> ProfileTools.Failure {
        .init(message: "KB 개인사업자 ID 조회의 정확한 주소·입력 행·위치를 확인하지 못했습니다. 개인정보를 입력하지 않았습니다.")
    }

    private static func address(_ word: OCR.Word) -> Bool {
        var text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The isolated 'a ' is the observed Edge lock glyph, not arbitrary prose before a nested URL.
        if text.hasPrefix("a ") { text.removeFirst(2) }
        // Edge elides the opaque cc value; OCR may cut it right after a lone '%'. Drop an incomplete escape and whatever follows it.
        text = text.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2}).*$", with: "", options: .regularExpression)
        guard !text.contains(where: \.isWhitespace),
              let url = URLComponents(string: text), url.scheme == "https", url.host == "obiz.kbstar.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.percentEncodedPath == "/quics", url.fragment == nil,
              let items = url.queryItems, let raw = url.percentEncodedQuery else { return false }
        let pages = items.filter { $0.name == "page" }
        guard pages.count == 1, pages[0].value == "C019750",
              raw.split(separator: "&").filter({ $0 == "page=C019750" }).count == 1,
              items.allSatisfy({ ["page", "QSL", "cc"].contains($0.name) }),
              Set(items.map(\.name)).count == items.count,
              items.filter({ $0.name == "QSL" }).allSatisfy({ $0.value == "F" }) else { return false }
        // Edge can elide the trailing opaque cc value. It is never used to identify the form.
        return true
    }

    static func region(_ words: [OCR.Word], target: ProfileFormFiller.Target) throws -> CGRect {
        guard target.form == .kbIDLookup, target.bankID == "kb", target.form.supports(target.field),
              target.segment == nil, target.x.isFinite, target.y.isFinite else { throw failure() }
        let titles = words.filter { compact($0.text) == "ID조회" }
        guard titles.count == 1, let title = titles.first,
              title.h >= 0.012, title.h <= 0.05, title.y > 0.15, title.y < 0.45 else { throw failure() }
        let chrome = words.filter {
            $0.y >= 0.03 && $0.y < 0.34 && $0.y + $0.h < title.y &&
                title.y - ($0.y + $0.h) < title.h * 3 && abs($0.x - title.x) < title.h * 2 &&
                $0.text.contains("https://")
        }
        guard chrome.count == 1, let bar = chrome.first, address(bar), bar.w > title.h * 12 else { throw failure() }
        let panel = CGRect(x: bar.x - title.h / 2, y: title.y,
                           width: bar.w + title.h, height: 1 - title.y)
        func inside(_ word: OCR.Word) -> Bool {
            word.w > 0 && word.h > 0 && panel.contains(CGPoint(x: word.x + word.w / 2, y: centerY(word)))
        }
        func row(_ text: String) -> OCR.Word? {
            let matches = words.filter {
                inside($0) && compact($0.text) == text && $0.y > title.y + title.h * 8 &&
                    $0.x >= title.x - title.h / 2 && $0.x <= title.x + title.h * 2
            }
            return matches.count == 1 ? matches.first : nil
        }
        guard let selection = row("조회구분"), let name = row("고객명"), let birth = row("생년월일"),
              let account = row("출금계좌번호"), let password = row("출금계좌비밀번호") else { throw failure() }
        let labels = [selection, name, birth, account, password]
        let h = labels.map(\.h).max() ?? 0
        guard h > 0,
              labels.allSatisfy({ abs($0.x - name.x) < h / 2 }),
              centerY(name) - centerY(selection) > h * 2, centerY(name) - centerY(selection) < h * 5,
              centerY(birth) - centerY(name) > h * 2, centerY(birth) - centerY(name) < h * 5,
              centerY(account) - centerY(birth) > h * 1.5, centerY(account) - centerY(birth) < h * 4,
              centerY(password) - centerY(account) > h * 1.25, centerY(password) - centerY(account) < h * 3 else { throw failure() }
        let options = words.filter {
            inside($0) && compact($0.text).contains("개인사업자") &&
                abs(centerY($0) - centerY(selection)) < h && $0.x > selection.x + selection.w + h
        }
        let exampleTexts = ["예:1981년2월1일일경우810201", "예:1981년2월1일인경우810201"]
        let examples = words.filter { w in   // the help icon in front of the example may be read as "i", "i)" or "(i)"
            let t = compact(w.text)
            return inside(w) && exampleTexts.contains(where: { t == $0 || t == "i" + $0 || t == "i)" + $0 || t == "(i)" + $0 }) &&
                centerY(w) > centerY(birth) && centerY(w) < centerY(account) && w.x > birth.x + birth.w + h
        }
        let confirmations = words.filter {
            inside($0) && compact($0.text) == "확인" && centerY($0) > centerY(password) + h &&
                centerY($0) < centerY(password) + h * 5 && $0.x > password.x + password.w
        }
        let protectedLabels: Set<String> = ["사업자등록번호", "법인등록번호", "주민등록번호", "주민번호", "비밀번호",
                                             "인증번호", "인증서암호", "인증서비밀번호", "보안카드", "보안키패드", "otp", "pin", "password", "passcode"]
        guard options.count == 1, let option = options.first, examples.count == 1, confirmations.count == 1,
              !words.contains(where: {
                  inside($0) && protectedLabels.contains(compact($0.text).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":：*")))
              }),
              words.filter({ inside($0) && compact($0.text) == "출금계좌비밀번호" }).count == 1 else { throw failure() }
        let selected: OCR.Word
        switch target.field {
        case .bankCustomerName: selected = name
        case .birthDate: selected = birth
        case .bankAccountNumber: selected = account
        default: throw failure()
        }
        // Name and birthday labels are centered over a cell containing an input and a help line.
        // Their actual input sits above the label midpoint; the account row has no help line.
        let rowY = centerY(selected) - (target.field == .bankAccountNumber ? 0 : h * 0.7)
        // The input column starts right of the label column. OCR may split the option row so that "개인사업자" alone sits
        // mid-row; its position says nothing about where the inputs begin, so the bounds come from the labels only.
        let left = password.x + password.w + h * 1.25
        let right = min(panel.maxX - h * 2, left + h * (target.field == .bankAccountNumber ? 13 : 9))
        let region = CGRect(x: left, y: rowY - h * 0.75, width: right - left, height: h * 1.5)
        guard left < right, region.contains(CGPoint(x: target.x, y: target.y)) else { throw failure() }
        return region
    }
}
