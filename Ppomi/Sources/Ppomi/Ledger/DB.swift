// data/ledger.db: the reads the views need and the writes the collector makes. Schema as am.py created it (SCHEMA + the
// ALTERs it retries on every open), so a db either side wrote is the same db.
import Foundation
import SQLite3

final class DB {
    private final class WeakAccess {
        weak var lock: NSRecursiveLock?
        init(_ lock: NSRecursiveLock) { self.lock = lock }
    }
    private static let registryLock = NSLock()
    private static var fileLocks: [String: WeakAccess] = [:]

    private static func accessForFile(_ path: String) -> NSRecursiveLock {
        let key = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let lock = fileLocks[key]?.lock { return lock }
        fileLocks = fileLocks.filter { $0.value.lock != nil }
        let lock = NSRecursiveLock()
        fileLocks[key] = WeakAccess(lock)
        return lock
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case open(path: String, message: String), query(String)
        var description: String {
            switch self { case .open(let p, let m): return "\(p): \(m)"; case .query(let m): return "sqlite: \(m)" }
        }
    }
    private var db: OpaquePointer?
    private let access: NSRecursiveLock

    static let schema = """
    CREATE TABLE IF NOT EXISTS transactions(
      id INTEGER PRIMARY KEY, ts TEXT NOT NULL, kind TEXT NOT NULL,
      amount INTEGER NOT NULL, merchant TEXT, card TEXT, cumulative INTEGER,
      source TEXT, msg_rowid INTEGER UNIQUE, raw TEXT);
    CREATE TABLE IF NOT EXISTS snapshots(
      id INTEGER PRIMARY KEY, ts TEXT NOT NULL, app TEXT NOT NULL, account TEXT, balance INTEGER NOT NULL, shot TEXT);
    CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS later(
      id INTEGER PRIMARY KEY, ts TEXT NOT NULL, who TEXT NOT NULL, topic TEXT, tags TEXT, done_ts TEXT);
    CREATE TABLE IF NOT EXISTS holdings(id INTEGER PRIMARY KEY, ts TEXT, app TEXT, account TEXT, symbol TEXT, name TEXT,
      country TEXT, currency TEXT, quantity REAL, last_price REAL, avg_price REAL, market_value_krw INTEGER, pnl_krw INTEGER, pnl_rate REAL);
    """

    /// Read-only by default. Writable connections initialize the ledger schema unless a separate store opts out.
    init(path: String, writable: Bool = false, initializeLedgerSchema: Bool = true) throws {
        access = Self.accessForFile(path)
        access.lock()
        defer { access.unlock() }
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        if writable { try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
            throw Error.open(path: path, message: message)
        }
        if writable {
            // A monitor holds a brief read snapshot. Let writes wait for it without changing readers' fail-fast policy.
            sqlite3_busy_timeout(db, 1_000)
            if initializeLedgerSchema {
                try run(Self.schema)
                for ddl in ["ALTER TABLE transactions ADD COLUMN status TEXT DEFAULT 'pending'",   // SMS rows are provisional
                            "ALTER TABLE transactions ADD COLUMN uid TEXT",                          // app-screen rows: natural key
                            "CREATE UNIQUE INDEX IF NOT EXISTS ux_tx_uid ON transactions(uid)"] { try? run(ddl) }
            }
        }
    }
    deinit {
        access.lock()
        sqlite3_close(db)
        access.unlock()
    }

    /// Hold the file's process-local lock across a compound operation, including nested DB calls.
    func withLockedAccess<T>(_ body: () throws -> T) rethrows -> T {
        access.lock()
        defer { access.unlock() }
        return try body()
    }

    /// Keep one committed snapshot and its process-local lock across every table read.
    /// macOS SQLite 3.51 can report IOERR_LOCK/EBADF when same-process read-only and writable handles overlap.
    /// File-scoped serialization preserves read-only/journal policy; external writers use SQLite's busy timeout.
    func withReadTransaction<T>(_ body: (DB) throws -> T) throws -> T {
        try withLockedAccess {
            try run("BEGIN DEFERRED TRANSACTION")
            do {
                let value = try body(self)
                try run("COMMIT")
                return value
            } catch {
                try? run("ROLLBACK")
                throw error
            }
        }
    }

    // ---------------------------------------------------------------- reads
    /// Every balance snapshot, in the order report.py reads them (ts, id).
    func snapshots() throws -> [(app: String, account: String, balance: Int, ts: Date)] {
        try query("SELECT app, account, balance, ts FROM snapshots ORDER BY ts, id") { s in
            guard let ts = TS.parse(text(s, 3) ?? "") else { return nil }         // malformed ts: no observation
            return (app: text(s, 0) ?? "", account: text(s, 1) ?? "", balance: int(s, 2) ?? 0, ts: ts)
        }
    }

    /// Transaction rows read off the app screens (source 'app:APP'), in the order report.py reads them (ts, id).
    func transactions() throws -> [Transaction] {
        try query("SELECT id, ts, kind, amount, merchant, card, cumulative, source, uid FROM transactions WHERE source LIKE 'app:%' ORDER BY ts, id") { s in
            guard let ts = TS.parse(text(s, 1) ?? ""), let kind = Transaction.Kind(rawValue: text(s, 2) ?? "") else { return nil }
            return Transaction(id: int(s, 0) ?? 0, ts: ts, kind: kind, amount: int(s, 3) ?? 0, merchant: text(s, 4) ?? "", tag: text(s, 5) ?? "",
                               cumulative: int(s, 6), app: String((text(s, 7) ?? "").dropFirst("app:".count)), uid: text(s, 8) ?? "")
        }
    }

    func state(_ key: String) throws -> String? {
        try query("SELECT value FROM state WHERE key = ?", [key]) { text($0, 0) }.first
    }

    // ---------------------------------------------------------------- writes (the collector)
    func setState(_ key: String, _ value: String) throws { try exec("INSERT OR REPLACE INTO state VALUES(?, ?)", [key, value]) }

    func insertSnapshot(ts: String, app: String, account: String, balance: Int, shot: String) throws {
        try exec("INSERT INTO snapshots(ts,app,account,balance,shot) VALUES(?,?,?,?,?)", [ts, app, account, balance, shot])
    }

    /// A screen-read transaction; false when its uid is already there.
    @discardableResult
    func insertTransaction(_ t: OCR.Tx, app: String) throws -> Bool {
        try exec("""
            INSERT OR IGNORE INTO transactions(ts,kind,amount,merchant,card,cumulative,source,uid,status)
            VALUES(?,?,?,?,?,?,?,?,'confirmed')
            """, [t.ts, t.kind, t.amount, t.merchant, t.card, t.cumulative, "app:\(app)", t.uid]) > 0
    }

    func insertHolding(ts: String, account: String, _ h: Toss.Holding) throws {
        try exec("""
            INSERT INTO holdings(ts,app,account,symbol,name,country,currency,quantity,last_price,avg_price,market_value_krw,pnl_krw,pnl_rate)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [ts, "TOSSINVEST", account, h.symbol, h.name, h.country, h.currency, h.quantity, h.lastPrice, h.avgPrice, h.marketValueKRW, h.pnlKRW, h.pnlRate])
    }

    /// Any SELECT as (column names, rows); values are Int, Double, String or nil. 50 rows at most: this feeds messages.
    func table(_ sql: String, _ params: [Any?] = [], limit: Int = 50) throws -> (cols: [String], rows: [[Any?]]) {
        access.lock()
        defer { access.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        let cols = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [[Any?]] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append((0..<n).map { i -> Any? in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
                case SQLITE_NULL: return nil
                default: return text(stmt, i)
                }
            })
            if rows.count >= limit { break }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw Error.query(String(cString: sqlite3_errmsg(db))) }   // e.g. READONLY, BUSY: not an empty table
        return (cols, rows)
    }
    func rows(_ sql: String, _ params: [Any?] = [], limit: Int = 50) throws -> [[Any?]] { try table(sql, params, limit: limit).rows }
    /// First column of the first row, or nil.
    func scalar(_ sql: String, _ params: [Any?] = []) throws -> Any? { try rows(sql, params, limit: 1).first?.first ?? nil }

    // ---------------------------------------------------------------- plumbing
    /// Statements without parameters (schema).
    func run(_ sql: String) throws {
        access.lock()
        defer { access.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "?"; sqlite3_free(err); throw Error.query(m)
        }
    }

    /// One parameterised statement; returns the rows it changed.
    @discardableResult
    func exec(_ sql: String, _ params: [Any?]) throws -> Int {
        access.lock()
        defer { access.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.query(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    /// Run one statement, mapping each row; a row the mapper rejects (nil) is left out.
    private func query<T>(_ sql: String, _ params: [Any?] = [], _ row: (OpaquePointer) -> T?) throws -> [T] {
        access.lock()
        defer { access.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let v = row(stmt) { out.append(v) }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw Error.query(String(cString: sqlite3_errmsg(db))) }
        return out
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Error.query(String(cString: sqlite3_errmsg(db))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, n)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            default: sqlite3_bind_text(stmt, n, "\(p!)", -1, transient)
            }
        }
        return stmt
    }
}

// Column readers; nil for SQL NULL.
private func text(_ s: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
private func int(_ s: OpaquePointer, _ i: Int32) -> Int? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i)) }
