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
/// 계좌 그룹. 기본 렌즈("내 것 전부")는 모든 계좌; 사람이 만든 그룹은 계좌의 부분집합이고 계좌는 그룹 하나에만 속한다(LensStore).
struct Lens: Hashable, Identifiable, Codable {
    /// 늘 있는 가계부(개인) 바닥의 이름. 상자가 아니라 바닥이라 저장되는 렌즈가 아니다(아이패드도 같은 이름을 쓴다).
    static let home = "가계부"
    var name: String
    var inside: Set<String>
    var x: Int? = nil, y: Int? = nil          // 판 위의 자리(격자 단위); 없으면 페이지가 차례로 놓는다. 렌즈는 늘 가계부 안 용도 그룹; 사업자는 렌즈가 아니라 계좌의 사실(Rules.businessApps)
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
    var lenses: [Lens] = []                             // 사람이 만든 계좌 그룹(가계부·사업…); 타임라인은 그룹 하나를 골라 본다
    var nodes: [String: [Int]] = [:]                    // 그룹 밖 계좌 노드의 판 위 자리 [x, y](격자 단위)
}


/// Days are local (KST) midnights.
enum KST {
    static var today: Date { Calendar.current.startOfDay(for: Date()) }
    static func day(_ d: Date, _ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d)! }
    /// "2026-09-03"
    static func ymd(_ d: Date) -> String { String(TS.string(d).prefix(10)) }
}
