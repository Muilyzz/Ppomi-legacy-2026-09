// Reading the ledger: report.timeline_data() (how the series and the journal are built) and the queries its JS runs on
// them (valueAt, sheet, total, flows, observed). The stored fields are in Model.swift.
import Foundation

extension Ledger {
    /// Every observation of every account as a step function, plus the journal with its accounts named by balance-sheet
    /// label: enough to state the balance sheet at any instant and the flows of any range.
    static func load(dbPath: String, me: String) throws -> Ledger {
        let db = try DB(path: dbPath)
        return try load(db: db, me: me)
    }

    /// A monitor can reuse its read-only connection and hold one read transaction across both tables.
    static func load(db: DB, me: String) throws -> Ledger {
        let snaps = try db.snapshots(), txs = try db.transactions()
        return load(snapshots: snaps, transactions: txs, me: me)
    }

    /// Both the source adapter and the server reader use exactly the same accounting rules.
    static func load(snapshots snaps: [(app: String, account: String, balance: Int, ts: Date)],
                     transactions txs: [Transaction], me: String) -> Ledger {
        var app: [String: String] = [:], labels: [String] = []          // label → app, in first-seen order (Python dict order)
        var series: [String: [Observation]] = [:]
        for s in snaps {
            let lab = Rules.normLabel(s.account)
            if app[lab] == nil { app[lab] = s.app; labels.append(lab) }
            series[lab, default: []].append(Observation(ts: s.ts, value: s.balance, how: .snapshot))
        }
        // Each app's transaction chain attaches to the snapshot label its pattern matches, else to the journal's own name.
        var sheetLabel: [String: String] = [:]                          // journal name → balance-sheet label
        for (a, rule) in Rules.account.sorted(by: { $0.key < $1.key }) {
            let lab = labels.first { app[$0] == a && Rules.search(rule.pattern, $0) } ?? rule.name
            if app[lab] == nil { app[lab] = a; labels.append(lab) }
            sheetLabel[rule.name] = lab
            for t in Rules.chainOrder(txs.filter { $0.app == a && $0.cumulative != nil }) {
                series[lab, default: []].append(Observation(ts: t.ts, value: t.cumulative ?? 0, how: .chain))
            }
        }
        for (lab, v) in series { series[lab] = v.sorted { $0.ts < $1.ts } }   // stable: snapshots first, then chain rows in chain order (Python sorts the ts string the same way)
        let lines = Rules.journal(txs, me: me).map {
            JournalLine(id: $0.id, ts: $0.ts, memo: $0.memo, dr: sheetLabel[$0.dr] ?? $0.dr, cr: sheetLabel[$0.cr] ?? $0.cr,
                        amount: $0.amount, rev: $0.rev, inferred: $0.inferred, uid: $0.uid)
        }
        return Ledger(accounts: app.map { Account(id: $0.key, app: $0.value, title: Rules.title($0.value)) }.sorted { ($0.app, $0.id) < ($1.app, $1.id) },
                      series: series, lines: lines,
                      defaultLens: Lens(name: LegacyAccountingRules.bundled.defaultLensName,
                                        inside: Set(labels).union(LegacyAccountingRules.bundled.defaultInside)))
    }

    /// The account's last observation at or before t.
    func value(of account: String, at t: Date) -> Observation? { series[account]?.last { $0.ts <= t } }

    func sheet(at t: Date) -> [(account: Account, obs: Observation?)] { accounts.map { ($0, value(of: $0.id, at: t)) } }

    /// Assets at t over the accounts observed by then; `unknown` counts the accounts with no observation yet.
    func total(at t: Date) -> (sum: Int, unknown: Int) {
        var sum = 0, unknown = 0
        for (_, obs) in sheet(at: t) { if let o = obs { sum += o.value } else { unknown += 1 } }
        return (sum, unknown)
    }

    /// The journal lines with ts in [lower, upper), read under the lens. `lines` carries every line in range, .none included.
    func flows(in range: Range<Date>, lens: Lens) -> Flows {
        var f = Flows()
        for l in lines where range.contains(l.ts) {
            let k = Rules.classify(l, inside: lens.inside)
            switch k {
            case .income: f.income += l.amount
            case .conversion: f.spend += l.amount; f.byCapital[l.dr, default: 0] += l.amount
            case .reversal: f.spend -= l.amount; f.byCapital[l.cr, default: 0] -= l.amount
            case .transfer: f.transfer += l.amount
            case .none: break
            }
            f.lines.append((l, k))
        }
        return f
    }

    /// Observed change of the assets between the range's ends: only accounts observed at both ends count.
    func observedChange(in range: Range<Date>) -> (sum: Int, n: Int) {
        var sum = 0, n = 0
        for a in accounts {
            if let v1 = value(of: a.id, at: range.lowerBound), let v2 = value(of: a.id, at: range.upperBound) { sum += v2.value - v1.value; n += 1 }
        }
        return (sum, n)
    }
}
