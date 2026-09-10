// 은행정보 수집: 폰(KB스타기업뱅킹 계좌 화면)을 비공개로 한 번 읽어(임시 캡처 → OCR 단어, 파일은 바로 삭제) 예금주명·계좌번호를
// 키체인 은행정보(bank_profiles)에 저장한다. 값은 에이전트·대화·발자국·OCR 장부 어디에도 돌아가지 않는다: 응답은 등록 여부와 끝 네 자리뿐.
// 그 뒤 profile_fill(kb_id_lookup) 이 같은 키체인 값을 Windows 팝업에 넣는다.
import Foundation

enum BankProfileCapture {
    struct Found: Equatable { var customerName: String?; var accountNumber: String? }
    struct Failure: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

    /// KB 계좌번호 표기: 6-2-6(14자리) · 4-2-6 · 3-2-4-3 · 붙여 쓴 12~14자리
    static let accountPattern = #"(?<!\d)(?:\d{6}-\d{2}-\d{6}|\d{4}-\d{2}-\d{6}|\d{3}-\d{2}-\d{4}-\d{3}|\d{12,14})(?!\d)"#
    /// 화면의 UI 낱말: 예금주 후보에서 뺀다
    static let uiWords: Set<String> = ["계좌조회", "계좌", "계좌번호", "잔액", "출금가능금액", "출금가능", "입출금", "예금", "통장", "이체", "전체계좌", "기업", "은행",
                                       "국민은행", "KB국민은행", "예금주", "계좌명", "별명", "상세", "조회", "거래내역", "입금", "출금", "원", "정상", "신규", "메뉴", "홈"]

    static func find(_ words: [OCR.Word]) throws -> Found {
        let re = try NSRegularExpression(pattern: accountPattern)
        var accounts: [(String, OCR.Word)] = []
        for w in words {
            let t = w.text
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                let s = String(t[Range(m.range, in: t)!]).replacingOccurrences(of: "-", with: "")
                if !accounts.contains(where: { $0.0 == s }) { accounts.append((s, w)) }
            }
        }
        guard !accounts.isEmpty else { throw Failure("화면에서 계좌번호를 찾지 못했다. 계좌조회의 계좌 상세(계좌번호가 보이는 화면)를 연 뒤 다시 부른다.") }
        guard accounts.count == 1, let (number, anchor) = accounts.first else {
            throw Failure("계좌번호가 \(accounts.count)개 보인다. 쓸 계좌 하나의 상세 화면으로 들어간 뒤 다시 부른다.")
        }
        func clean(_ t: String) -> String { t.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ":：·|")) }
        func nameLike(_ t: String) -> Bool {
            let c = clean(t)
            return (2...20).contains(c.count) && !c.contains(where: \.isNumber) && !uiWords.contains(c.replacingOccurrences(of: " ", with: "")) &&
                c.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == " " || "()·".unicodeScalars.contains($0) }
        }
        let cy = { (w: OCR.Word) in w.y + w.h / 2 }
        var name: String? = nil
        // 1. "예금주" 라벨 바로 뒤(같은 줄) 또는 라벨 낱말 안("예금주 홍길동")
        for w in words {
            let c = clean(w.text)
            if c.hasPrefix("예금주") {
                let rest = clean(String(c.dropFirst("예금주".count)))
                if nameLike(rest) { name = rest; break }
                if let next = words.filter({ $0.x > w.x + w.w && abs(cy($0) - cy(w)) < max(w.h, 0.012) && nameLike($0.text) }).min(by: { $0.x < $1.x }) { name = clean(next.text); break }
            }
        }
        // 2. 없으면 계좌번호와 같은 줄 또는 바로 윗줄의 이름꼴 낱말 하나(둘 이상이면 모른다고 한다)
        if name == nil {
            let near = words.filter { $0.text != anchor.text && nameLike($0.text) && cy($0) <= cy(anchor) + anchor.h && cy(anchor) - cy($0) < anchor.h * 3.2 }
            if near.count == 1 { name = clean(near[0].text) }
        }
        return Found(customerName: name, accountNumber: number)
    }

    /// One private read of the current iPhone screen → keychain. Existing values are replaced only by what was found.
    static func capture(profileID: String, bankID: String, store: IdentityProfileStore, screen: () throws -> [OCR.Word] = { try Phone.privateScreen(windows: false) }) throws -> String {
        guard bankID == "kb" else { throw Failure("bank_id 는 kb 만 지원한다.") }
        let found = try find(try screen())
        var values: [String: String] = [:]
        if let n = found.accountNumber { values["account_number"] = n }
        if let c = found.customerName { values["customer_name"] = c }
        let saved = try store.updateBankProfile(id: profileID, bankID: bankID, values: values)
        let bank = saved.bankProfiles?[bankID]
        let tail = bank?.accountNumber.map { String($0.filter(\.isNumber).suffix(4)) } ?? ""
        let result: [String: Any] = ["bank_id": bankID, "profile_id": saved.id,
                                     "registered": ["customer_name": bank?.customerName != nil, "account_number": bank?.accountNumber != nil],
                                     "account_tail": tail,
                                     "notice": found.customerName == nil
                                        ? "계좌번호는 저장했고 예금주명은 화면에서 확정하지 못했다. request_bank_profile 카드로 고객명만 받거나 예금주가 보이는 화면에서 다시 부른다."
                                        : "예금주명과 계좌번호를 은행정보에 저장했다. 원문은 돌려주지 않는다. 이어서 profile_fill(kb_id_lookup) 로 입력한다."]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
