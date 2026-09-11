// The bank apps: how to open each on the mirrored phone and which OCR row is an account. am.py APPS, same order.
import Foundation

struct AppConfig {
    let key: String
    let title: String           // "KB스타뱅킹"
    let search: String          // Spotlight term (ASCII)
    let account: String         // regex: the OCR row that is an account
    var homeLabel: String? = nil   // tap the icon under this label on home page 1 instead of Spotlight
    var expand: String? = nil      // a word to tap once open (KB's home collapses extras under '더보기')
    var list: String? = nil        // a control that opens the full account list
    var tx: String? = nil          // the home row to tap for the transaction list (first match)
    var txpage: String? = nil      // text only the transaction list has (default: 카카오 '13:06 #' rows)
    var home: String? = nil        // text only the home screen has — absent after opening → tap back
    var debt: String? = nil        // regex: rows whose balance is money owed (loans) — stored negative
    var scrollY = 0.5              // where the wheel scrolls (KB's web list only moves with the pointer over the rows)
}

enum Apps {
    /// Preserve the old collector order; new packages with collection metadata join automatically.
    static var all: [AppConfig] { configurations(from: PlaybookCatalog.load()) }
    static func configurations(from records: [PlaybookRecord]) -> [AppConfig] {
        let legacyOrder = ["KB", "KBANK", "KAKAO", "TOSS"]
        return records.compactMap { record -> AppConfig? in
            guard let value = record.manifest.collection else { return nil }
            return AppConfig(key: value.key, title: record.name, search: record.manifest.launch.search, account: value.account,
                             homeLabel: value.homeLabel, expand: value.expand, list: value.list, tx: value.tx,
                             txpage: value.txpage, home: value.home, debt: value.debt, scrollY: value.scrollY)
        }.sorted {
            let left = legacyOrder.firstIndex(of: $0.key) ?? legacyOrder.count
            let right = legacyOrder.firstIndex(of: $1.key) ?? legacyOrder.count
            return left == right ? $0.key < $1.key : left < right
        }
    }
    static let api = ["TOSSINVEST"]                      // no phone needed
    static func config(_ app: String) -> AppConfig? { config(app, from: PlaybookCatalog.load()) }
    /// CLI, voice, and MCP use the same ID/name/alias contract; the ledger retains the collection key.
    static func config(_ app: String, from records: [PlaybookRecord]) -> AppConfig? {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = records.first { $0.id.caseInsensitiveCompare(query) == .orderedSame }
            ?? records.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? records.first { $0.matches(query) }
        return record.flatMap { configurations(from: [$0]).first }
    }
}
