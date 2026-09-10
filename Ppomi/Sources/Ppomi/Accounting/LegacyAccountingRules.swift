import Foundation

/// Compatibility data for the collector's label-based journal. New activities are accounts and rules in data,
/// not branches in the accounting engine. These labels never determine a book's measurement unit.
struct LegacyAccountingRules: Decodable {
    struct AccountMapping: Decodable { let pattern: String; let name: String }
    struct CapitalRule: Decodable { let pattern: String; let capital: String }
    struct Predicate: Decodable {
        enum Field: String, Decodable { case merchant, tag }
        let field: Field
        let contains: String?
        let ownName: Bool?

        func matches(_ row: Transaction, me: String) -> Bool {
            let value = field == .merchant ? row.merchant : row.tag
            let needle = ownName == true ? me : (contains ?? "")
            return !needle.isEmpty && value.range(of: needle, options: .literal) != nil
        }
    }
    struct Target: Decodable {
        enum Source: String, Decodable { case sourceAccount, category, named }
        let source: Source
        let name: String?

        func resolve(account: String, category: String) -> String {
            switch source {
            case .sourceAccount: return account
            case .category: return category
            case .named: return name! // Required and checked by decode(data:) before rules are exposed.
            }
        }
    }
    struct InferredLine: Decodable { let memo: String; let debit: Target; let credit: Target }
    struct JournalRule: Decodable {
        let kinds: [String]
        let any: [Predicate]?
        let memo: String
        let debit: Target
        let credit: Target
        let reversal: Bool?
        let inferred: InferredLine?

        func matches(_ row: Transaction, me: String) -> Bool {
            kinds.contains(row.kind.rawValue) && (any == nil || any!.contains { $0.matches(row, me: me) })
        }
    }

    let formatVersion: Int
    let accounts: [String: AccountMapping]
    let titles: [String: String]
    let capitals: [CapitalRule]
    let defaultCapital: String
    let spendingRules: [CapitalRule]
    let spendingCategories: [String]
    let defaultSpendingCategory: String
    let outsideClasses: [String]
    let defaultLensName: String
    let defaultInside: [String]
    let accountKinds: [String: AccountingAccount.Kind]
    let journalRules: [JournalRule]

    struct ConfigurationError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "기존 장부 분개 규칙 오류: \(message)" }
    }

    /// The old Rules API is nonthrowing. A broken bundled configuration is a packaging/programming error:
    /// stop explicitly instead of silently replacing categories or dropping financial records.
    static let bundled: LegacyAccountingRules = {
        do { return try loadBundled() }
        catch { preconditionFailure(error.localizedDescription) }
    }()

    static func loadBundled() throws -> LegacyAccountingRules {
        guard let url = AppResources.bundle.url(forResource: "legacy-rules", withExtension: "json", subdirectory: "AccountingData") else {
            throw ConfigurationError(message: "AccountingData/legacy-rules.json 리소스가 없습니다.")
        }
        return try decode(data: Data(contentsOf: url))
    }

    static func decode(data: Data) throws -> LegacyAccountingRules {
        let rules = try JSONDecoder().decode(Self.self, from: data)
        try rules.validate()
        return rules
    }

    private func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ConfigurationError(message: message) }
        }
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func target(_ value: Target) throws {
            if value.source == .named {
                try require(value.name.map(nonempty) == true, "named 계정에는 이름이 필요합니다.")
                try require(value.name.flatMap { accountKinds[$0] } != nil, "명명된 계정에는 accountKinds 분류가 필요합니다.")
            } else {
                try require(value.name == nil, "동적 계정에는 고정 이름을 지정할 수 없습니다.")
            }
        }
        try require(formatVersion == 1, "지원하지 않는 규칙 버전입니다.")
        try require(nonempty(defaultCapital) && nonempty(defaultLensName), "기본 분류와 경계 이름이 필요합니다.")
        try require(accountKinds[defaultCapital] != nil, "기본 분류에는 accountKinds 분류가 필요합니다.")
        try require(!spendingCategories.isEmpty && spendingCategories.allSatisfy(nonempty), "지출 분류에는 빈 이름을 사용할 수 없습니다.")
        try require(Set(spendingCategories).count == spendingCategories.count, "지출 분류 이름은 중복될 수 없습니다.")
        try require(spendingCategories.contains(defaultSpendingCategory), "기본 지출 분류는 허용된 분류 중 하나여야 합니다.")
        for value in spendingRules {
            try require(spendingCategories.contains(value.capital), "지출 규칙은 허용된 분류를 사용해야 합니다.")
            try require(!value.pattern.isEmpty, "지출 규칙에는 패턴이 필요합니다.")
            _ = try NSRegularExpression(pattern: value.pattern)
        }
        for (key, value) in accounts {
            try require(nonempty(key) && nonempty(value.name), "수집 계정 키와 이름이 필요합니다.")
            _ = try NSRegularExpression(pattern: value.pattern)
        }
        for value in capitals {
            try require(nonempty(value.capital) && !value.pattern.isEmpty, "분류 이름과 패턴이 필요합니다.")
            try require(accountKinds[value.capital] != nil, "분류 계정에는 accountKinds 분류가 필요합니다.")
            _ = try NSRegularExpression(pattern: value.pattern)
        }
        for (name, _) in accountKinds { try require(nonempty(name), "빈 계정 이름은 허용되지 않습니다.") }
        for name in defaultInside + outsideClasses {
            try require(accountKinds[name] != nil, "경계에 지정된 계정에는 accountKinds 분류가 필요합니다.")
        }
        var fallbackKinds = Set<String>()
        for rule in journalRules {
            try require(!rule.kinds.isEmpty, "분개 규칙의 거래 종류가 필요합니다.")
            for kind in rule.kinds {
                try require(Transaction.Kind(rawValue: kind) != nil, "알 수 없는 거래 종류: \(kind)")
                try require(!fallbackKinds.contains(kind), "기본 규칙 이후의 규칙은 실행되지 않습니다: \(kind)")
            }
            if let predicates = rule.any {
                try require(!predicates.isEmpty, "빈 조건 목록은 허용되지 않습니다.")
                for predicate in predicates {
                    try require((predicate.ownName == true) != (predicate.contains != nil), "조건에는 ownName 또는 contains 중 하나가 필요합니다.")
                    if let literal = predicate.contains { try require(!literal.isEmpty, "빈 contains 조건은 허용되지 않습니다.") }
                }
            } else { fallbackKinds.formUnion(rule.kinds) }
            try target(rule.debit); try target(rule.credit)
            if let inferred = rule.inferred { try target(inferred.debit); try target(inferred.credit) }
        }
        // Enumerating the source format's transaction kinds is compatibility validation, not activity-specific policy.
        let sourceKinds: [Transaction.Kind] = [.approval, .cancel, .deposit, .withdrawal]
        try require(sourceKinds.allSatisfy { fallbackKinds.contains($0.rawValue) }, "모든 거래 종류에는 조건 없는 기본 규칙이 필요합니다.")
    }

    /// Merchant categorization retains the collector's first-match behavior. A missing match has an explicit
    /// configured fallback. Inferred memo lines use case-sensitive matching, as the legacy collector did.
    func category(of merchant: String, caseInsensitive: Bool = true) -> String? {
        capitals.first { rule in
            let expression = try! NSRegularExpression(pattern: rule.pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            return expression.firstMatch(in: merchant, range: NSRange(merchant.startIndex..., in: merchant)) != nil
        }?.capital
    }

    func journal(_ rows: [Transaction], me: String) -> [JournalLine] {
        var lines: [JournalLine] = []
        for row in rows {
            guard let rule = journalRules.first(where: { $0.matches(row, me: me) }) else {
                preconditionFailure("Validated legacy rules do not cover transaction kind \(row.kind.rawValue).")
            }
            let account = accounts[row.app]?.name ?? row.app
            let category = self.category(of: row.merchant) ?? defaultCapital
            func add(memo: String, debit: Target, credit: Target, category: String, index: Int, reversal: Bool = false, inferred: Bool = false) {
                let rendered = render(memo, tag: row.tag, merchant: row.merchant)
                lines.append(JournalLine(id: "\(row.uid)#\(index)", ts: row.ts, memo: rendered,
                                         dr: debit.resolve(account: account, category: category),
                                         cr: credit.resolve(account: account, category: category), amount: row.amount,
                                         rev: reversal, inferred: inferred, uid: row.uid))
            }
            add(memo: rule.memo, debit: rule.debit, credit: rule.credit, category: category, index: 0, reversal: rule.reversal ?? false)
            if let inferred = rule.inferred, let matched = self.category(of: row.merchant, caseInsensitive: false) {
                add(memo: inferred.memo, debit: inferred.debit, credit: inferred.credit, category: matched, index: 1, inferred: true)
            }
        }
        return lines
    }

    /// Expand template tokens once. A source value containing token-shaped text remains literal evidence.
    private func render(_ template: String, tag: String, merchant: String) -> String {
        var result = "", cursor = template.startIndex
        while cursor < template.endIndex {
            let remaining = cursor..<template.endIndex
            let matches = ["{tag}", "{merchant}"].compactMap { template.range(of: $0, range: remaining) }
            guard let next = matches.min(by: { $0.lowerBound < $1.lowerBound }) else {
                result += template[cursor...]
                break
            }
            result += template[cursor..<next.lowerBound]
            result += template[next] == "{tag}" ? tag : merchant
            cursor = next.upperBound
        }
        return result
    }
}
