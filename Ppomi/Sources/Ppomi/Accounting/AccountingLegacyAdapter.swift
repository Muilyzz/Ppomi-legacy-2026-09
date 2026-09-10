import Foundation

/// An explicit, read-only conversion of collected monetary journal lines. No migration or write occurs here.
/// Legacy account labels cannot distinguish equal labels across institutions; namespacing isolates databases,
/// but cannot recover identity or ownership that the source never recorded.
enum AccountingLegacyAdapter {
    static func archive(ledger: Ledger, namespace: String) throws -> AccountingArchive {
        try archive(ledger: ledger, namespace: namespace, rules: LegacyAccountingRules.loadBundled())
    }

    /// Separate data injection keeps custom category policies testable without changing the generic adapter.
    static func archive(ledger: Ledger, namespace: String, rules: LegacyAccountingRules) throws -> AccountingArchive {
        guard !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LegacyAccountingRules.ConfigurationError(message: "가져오는 원본 장부의 namespace가 필요합니다.")
        }
        let bookID = "legacy:" + namespace
        let book = AccountingBook(id: bookID, name: "기존 수집 장부 · 소유 미확인", ownerID: bookID,
                                  kind: .financial,
                                  unit: AccountingUnit(id: "KRW", name: "대한민국 원", symbol: "원", dimension: .currency, scale: 0))
        let lines = ledger.lines.filter { !$0.inferred }
        let financialLabels = ledger.defaultLens.inside.union(ledger.accounts.map(\.id))
        let labels = Set(ledger.accounts.map(\.id)).union(lines.flatMap { [$0.dr, $0.cr] }).sorted()
        func accountID(_ label: String) -> String { bookID + ":account:" + encoded(label) }

        let accounts = labels.map { label in
            // Account kinds are data, not meaning guessed from a word. An unmapped source financial account
            // is an asset under the source boundary; an unmapped outside label is conservatively an expense.
            // Even the source's transfer boundary does not verify legal ownership: the entire book is marked so.
            AccountingAccount(id: accountID(label), bookID: bookID, name: label,
                              kind: rules.accountKinds[label] ?? (financialLabels.contains(label) ? .asset : .expense))
        }
        let entries = lines.map { line in
            let recordID = line.uid.isEmpty ? line.id : line.uid
            // No content-based deduplication: equal-looking transactions with distinct source IDs stay distinct.
            // The source has no collection timestamp on JournalLine, so use its event timestamp deterministically.
            return AccountingEntry(id: bookID + ":entry:" + encoded(line.id),
                                   eventID: bookID + ":event:" + encoded(recordID), bookID: bookID,
                                   occurredAt: line.ts, recordedAt: line.ts, memo: line.memo,
                                   source: "legacy-ledger", sourceRecordID: line.id,
                                   postings: [AccountingPosting(accountID: accountID(line.dr), side: .debit, amount: line.amount),
                                              AccountingPosting(accountID: accountID(line.cr), side: .credit, amount: line.amount)],
                                   layer: .recorded)
        }
        let archive = AccountingArchive(books: [book], accounts: accounts, entries: entries)
        try AccountingEngine.validate(archive)
        return archive
    }

    /// Reversible UTF-8 encoding avoids punctuation/whitespace normalization collisions and randomized Swift hashes.
    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
