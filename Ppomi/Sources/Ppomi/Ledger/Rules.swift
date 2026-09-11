// Compatibility API for the collected ledger. Classification and app-specific mappings live in AccountingData;
// this file retains only generic ordering, normalization, and boundary operations.
import Foundation

enum Rules {
    static let account: [String: (pattern: String, name: String)] = LegacyAccountingRules.bundled.accounts.mapValues { ($0.pattern, $0.name) }
    static let capitals: [(pattern: String, capital: String)] = LegacyAccountingRules.bundled.capitals.map { ($0.pattern, $0.capital) }
    /// Capitals and outside sources: no lens contains them.
    static let neverInside = Set(LegacyAccountingRules.bundled.outsideClasses + capitals.map(\.capital))
    /// am.title(app): the app's Korean name.
    static let titles = LegacyAccountingRules.bundled.titles
    static func title(_ app: String) -> String { titles[app] ?? app }
    /// 사업자의 계좌는 사실로 정해진다: 기업뱅킹 앱(사업자로 로그인해야 보이는 계좌)에서 읽은 계좌. 사람이 끌어 넣어 정하는 게 아니다.
    static let businessApps: Set<String> = ["KBBIZ"]
    /// 개인 앱 안에서도 이름이 사업자라고 말하는 계좌: 신한 '사업자 보통예금', '<기시>'(기업시설자금)·'<기운>'(기업운전자금) 대출.
    static let businessLabel = re(#"사업자|^<기[시운]>"#)   // NSRegularExpression: this file is shared with the iPad target (no Re helper there)
    /// 증권 앱의 잔액은 예금이 아니라 투자자산(평가금액).
    static let investApps: Set<String> = ["SAMSUNG", "KAKAOPAY", "TOSSINVEST"]
    static func isBusiness(app: String, label: String) -> Bool {
        businessApps.contains(app) || businessLabel.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    static func capital(of merchant: String) -> String {
        LegacyAccountingRules.bundled.category(of: merchant) ?? LegacyAccountingRules.bundled.defaultCapital
    }

    /// OCR noise: leading digits, masked / last-4 account numbers, whitespace runs.
    static func normLabel(_ label: String) -> String {
        let a = leadingDigits.stringByReplacingMatches(in: label, range: NSRange(label.startIndex..., in: label), withTemplate: "")
        let b = maskedNumber.stringByReplacingMatches(in: a, range: NSRange(a.startIndex..., in: a), withTemplate: "")
        return b.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The chain in true order. Rows sharing a minute come out of the app newest-first, so their ids run backwards; within
    /// such a group take the permutation whose balances follow from the previous one, else leave the group as is.
    static func chainOrder(_ rows: [Transaction]) -> [Transaction] {
        func signed(_ r: Transaction) -> Int { r.kind == .deposit || r.kind == .cancel ? r.amount : -r.amount }
        func closes(_ p: [Transaction], from bal: Int) -> Bool {
            var b = bal
            for r in p { guard let c = r.cumulative, c == b + signed(r) else { return false }; b = c }
            return true
        }
        var out: [Transaction] = [], bal: Int? = nil, i = 0
        while i < rows.count {
            var j = i
            while j < rows.count, rows[j].ts == rows[i].ts { j += 1 }
            var g = Array(rows[i..<j])
            if let b = bal, g.count > 1 { g = permutations(g).first { closes($0, from: b) } ?? g }
            out += g; bal = g.last?.cumulative; i = j
        }
        return out
    }

    /// Double-entry lines from transaction rows. A line names both ends as concretely as the data allows and nothing else;
    /// what it is (transfer, income, spend) is decided at read time by classify(). Accounts are named the journal's way
    /// (account[app].name); Ledger.load maps them to balance-sheet labels. `me`: deposits carrying the own name are transfers.
    static func journal(_ rows: [Transaction], me: String) -> [JournalLine] {
        LegacyAccountingRules.bundled.journal(rows, me: me)
    }

    /// What a line is under a boundary: both ends inside = transfer; money leaving = conversion (spend); money arriving =
    /// income, or a reversal when it is a refund; neither end inside = none.
    static func classify(_ l: JournalLine, inside: Set<String>) -> Flow {
        let d = inside.contains(l.dr), c = inside.contains(l.cr)
        return d && c ? .transfer : c ? .conversion : d ? (l.rev ? .reversal : .income) : .none
    }

    /// Python `sub in s`: code-point substring. String.contains would also match canonically equivalent (NFD) text.
    static func has(_ s: String, _ sub: String) -> Bool { s.range(of: sub, options: .literal) != nil }

    /// re.search: does the pattern occur anywhere in s.
    static func search(_ pattern: String, _ s: String) -> Bool { (try? NSRegularExpression(pattern: pattern)).map { search($0, s) } ?? false }

    // MARK: - regex plumbing
    private static func re(_ p: String, ci: Bool = false) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : []) }
    private static func search(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    private static let leadingDigits = re(#"^\d+\s+"#), maskedNumber = re(#"\s*\(\*+\)|\s*…\d{4}"#)

    /// itertools.permutations order (by position), so the first closing permutation is the one Python picks.
    /// ponytail: n! eager; a minute holds a handful of rows, never enough to matter.
    private static func permutations<T>(_ a: [T]) -> [[T]] {
        if a.count <= 1 { return [a] }
        return a.indices.flatMap { i -> [[T]] in var rest = a; let x = rest.remove(at: i); return permutations(rest).map { [x] + $0 } }
    }
}
