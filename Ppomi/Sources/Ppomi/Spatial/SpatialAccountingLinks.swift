import Foundation

/// The cross-domain boundary validates references only. It never creates accounts, assets, or postings.
enum SpatialAccountingLinks {
    static func hasLinks(_ archive: SpatialArchive) -> Bool {
        archive.assets.contains { $0.usages.contains { !$0.accountLinks.isEmpty } }
    }

    static func validate(spatial: SpatialArchive, accounting: AccountingArchive) throws {
        try SpatialGeometry.validate(spatial)
        guard hasLinks(spatial) else { return }
        try AccountingEngine.validate(accounting)
        let books = Dictionary(uniqueKeysWithValues: accounting.books.map { ($0.id, $0) })
        let accounts = Dictionary(uniqueKeysWithValues: accounting.accounts.map { ($0.id, $0) })
        // Each archive validates its own scopes. Across archives, only actual links establish a
        // relationship; an unrelated business ID is not an implicit global registry entry.
        for asset in spatial.assets {
            for usage in asset.usages {
                for link in usage.accountLinks {
                    guard usage.scope.kind != .unclassified,
                          let book = books[link.bookID], book.effectiveScope == usage.scope else {
                        throw SpatialError.invalid("사용 구분과 연결 장부의 개인·사업·기록 주체 범위가 다릅니다: \(link.bookID)")
                    }
                    guard let account = accounts[link.accountID], account.bookID == link.bookID, account.kind == .asset else {
                        throw SpatialError.invalid("공간 사용은 해당 장부에 등록된 자산 계정에만 연결할 수 있습니다: \(link.accountID)")
                    }
                }
            }
        }
    }
}
