// The ledger's vocabulary, shared by every part of the app. Ported from report.py / am.py; the Python stays the writer of
// data/ledger.db for now (collection), this app is the reader. Times are KST wall-clock as stored ("YYYY-MM-DD HH:MM").
import Foundation

/// An account as the balance sheet names it: the normalized snapshot label. `app` is the bank app key (KB, KAKAO, KBANK, TOSS).
struct Account: Hashable, Identifiable {
    let id: String          // label, e.g. "AI 관련 지출 통장"
    let app: String         // "KAKAO"
    var title: String       // "카카오뱅크"
}

/// One observation of an account's balance: a snapshot row, or a transaction's balance-after (the chain).
struct Observation: Hashable {
    enum How: String { case snapshot = "스냅샷", chain = "거래 사슬" }
    let ts: Date
    let value: Int
    let how: How
}

/// A transaction row as stored by am.py.
struct Transaction: Hashable, Identifiable, Codable {
    enum Kind: String, Codable { case approval, cancel, deposit, withdrawal }
    let id: Int
    let ts: Date
    let kind: Kind
    let amount: Int
    let merchant: String
    let tag: String         // "체크카드", "스마트출금", ...
    let cumulative: Int?    // balance after, when the list shows it
    let app: String         // "KAKAO" (from source "app:KAKAO")
    let uid: String
}

/// A journal line names both ends and nothing else; what it *is* (transfer, income, spend) depends on the lens at read time.
struct JournalLine: Hashable, Identifiable {
    let id: String          // uid + "#" + index within the transaction
    let ts: Date
    let memo: String
    let dr: String          // where money arrived (an account label, a capital, "현금(수중)", ...)
    let cr: String          // where money left
    let amount: Int
    let rev: Bool           // refund / cancellation
    let inferred: Bool      // a second line inferred from a memo ("경조사비" → 관계), outside the ledger proper
    let uid: String
}

enum Flow: String { case transfer, conversion, income, reversal, none }

/// A boundary: the accounts considered "mine" when reading. Everything else is outside.
struct Lens: Hashable, Identifiable {
    var name: String
    var inside: Set<String>
    var id: String { name }
}

/// What one range of time did, under a lens.
struct Flows {
    var income = 0, spend = 0, transfer = 0
    var byCapital: [String: Int] = [:]
    var lines: [(JournalLine, Flow)] = []
}

/// The stored strings are KST wall-clock without a zone; the app runs on a Mac set to KST, so parse as local time.
enum TS {
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    static func parse(_ s: String) -> Date? { formatter.date(from: String(s.prefix(16))) }
    static func string(_ d: Date) -> String { formatter.string(from: d) }
}

extension Int {
    /// "1,234,567원", "−1,234원"
    var won: String {
        let n = NumberFormatter(); n.numberStyle = .decimal
        return (self < 0 ? "−" : "") + (n.string(from: NSNumber(value: abs(self))) ?? "\(abs(self))") + "원"
    }
    var signedWon: String { (self > 0 ? "+" : "") + won }
}

/// The whole ledger as the app reads it. Stored fields live here so every file sees the same shape; the loading and the
/// queries are implemented in Ledger.swift (extension Ledger).
struct Ledger {
    var accounts: [Account] = []                        // balance-sheet order (by app, then label)
    var series: [String: [Observation]] = [:]           // account label → observations sorted by time (chain rows in chain order)
    var lines: [JournalLine] = []                       // the journal, account names already mapped to balance-sheet labels
    var defaultLens = Lens(name: "내 것 전부", inside: [])
}

/// Settings that are not secrets (UserDefaults). The API key lives in the Keychain (Keychain.swift).
enum AppSettings {
    private static let d = UserDefaults.standard
    static var dbPath: String {
        get { ProcessInfo.processInfo.environment["PPOMI_DB"] ?? d.string(forKey: "dbPath") ?? defaultDBPath }
        set { d.set(newValue, forKey: "dbPath") }
    }
    /// The repo's data/ledger.db (where am.py writes): walking up from the executable (.build/debug/Ppomi, dist/Ppomi.app), else the
    /// checkout this was built from (tests run from xctest). Neither — the app moved out of the repo — ~/Library/Application Support/
    /// Ppomi/data/ledger.db; shots/, playbooks/ and .env follow, relative to it.
    static var defaultDBPath: String {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {                                // .build/debug/Ppomi → repo root
            let cand = dir.appendingPathComponent("data/ledger.db").path
            if fm.fileExists(atPath: cand) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        let src = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { u, _ in u.deletingLastPathComponent() }.appendingPathComponent("data/ledger.db").path
        if fm.fileExists(atPath: src) { return src }
        let app = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ppomi/data")
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        return app.appendingPathComponent("ledger.db").path
    }
    /// Own name: deposits carrying it are transfers between own accounts. Until set in Settings, fall back to STYLE_ME from the
    /// environment or the repo's .env next to data/, which is what am.py uses — so the app reads the ledger the same way.
    static var me: String {
        get { d.string(forKey: "me").flatMap { $0.isEmpty ? nil : $0 } ?? env("STYLE_ME") ?? "" }
        set { d.set(newValue, forKey: "me") }
    }
    /// A key from the process environment, else the repo's .env next to data/ (what am.py reads): `export K=v # note` lines.
    static func env(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        let env = URL(fileURLWithPath: dbPath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
        for line in (try? String(contentsOf: env, encoding: .utf8))?.split(separator: "\n") ?? [] {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !l.hasPrefix("#"), l.hasPrefix(key + "=") else { continue }
            let v = l.dropFirst(key.count + 1).components(separatedBy: " #")[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
    static var baseURL: String { get { d.string(forKey: "baseURL") ?? "https://api.openai.com/v1" } set { d.set(newValue, forKey: "baseURL") } }
    static var model: String { get { d.string(forKey: "model") ?? "gpt-5-mini" } set { d.set(newValue, forKey: "model") } }
    /// Explicit fallback calls only; ordinary OCR captures never cause an API request.
    static var visionEnabled: Bool { get { d.bool(forKey: "visionEnabled") } set { d.set(newValue, forKey: "visionEnabled") } }
    static var visionModel: String { env("OPENAI_VISION_MODEL") ?? VisualInspector.defaultModel }
    /// Whole-UI size (glyphs, spacing, controls) for people who set their text very large; 1 = default, clamped 0.75–3.
    static var uiScale: Double {
        get { let v = d.double(forKey: "uiScale"); return v == 0 ? 1 : min(3, max(0.75, v)) }
        set { d.set(newValue, forKey: "uiScale") }
    }
}

/// Days are local (KST) midnights.
enum KST {
    static var today: Date { Calendar.current.startOfDay(for: Date()) }
    static func day(_ d: Date, _ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d)! }
    /// "2026-09-03"
    static func ymd(_ d: Date) -> String { String(TS.string(d).prefix(10)) }
}
