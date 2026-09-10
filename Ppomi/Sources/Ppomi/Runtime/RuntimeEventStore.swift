import Foundation

/// A separate, bounded database: observing tools never changes the financial ledger's data_version.
final class RuntimeEventStore {
    enum Error: Swift.Error { case invalidEvent, readOnly, invalidStore }
    static let retentionLimit = 500

    static func path(for ledgerPath: String) -> String {
        URL(fileURLWithPath: (ledgerPath as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path + ".runtime.sqlite"
    }

    let path: String
    private let writable: Bool
    private let database: DB?

    init(ledgerPath: String, writable: Bool = true) throws {
        path = Self.path(for: ledgerPath)
        self.writable = writable
        if !writable && !FileManager.default.fileExists(atPath: path) {
            database = nil
            return
        }
        let db = try DB(path: path, writable: writable, initializeLedgerSchema: false)
        database = db
        if writable {
            // Store Date's native reference-epoch Double. Converting through Unix seconds loses submicrosecond bits.
            try db.run("""
                CREATE TABLE IF NOT EXISTS runtime_events(
                  seq INTEGER PRIMARY KEY AUTOINCREMENT,
                  id TEXT NOT NULL UNIQUE, call_id TEXT NOT NULL, timestamp REAL NOT NULL,
                  tool TEXT NOT NULL, kind TEXT NOT NULL, method TEXT NOT NULL, step INTEGER);
                """)
        }
    }

    func append(_ event: RuntimeEvent) throws {
        guard Self.isValid(event) else { throw Error.invalidEvent }
        guard writable, let database else { throw Error.readOnly }
        // Keep append + retention atomic across processes; DB also serializes same-process handles by file.
        try database.withLockedAccess {
            try database.run("BEGIN IMMEDIATE TRANSACTION")
            do {
                try database.exec("""
                    INSERT OR IGNORE INTO runtime_events(id,call_id,timestamp,tool,kind,method,step)
                    VALUES(?,?,?,?,?,?,?)
                    """, [event.id.uuidString, event.callID.uuidString, event.timestamp.timeIntervalSinceReferenceDate,
                            event.tool, event.kind.rawValue, event.method.rawValue, event.step])
                try database.exec("""
                    DELETE FROM runtime_events WHERE seq NOT IN
                    (SELECT seq FROM runtime_events ORDER BY seq DESC LIMIT ?)
                    """, [Self.retentionLimit])
                try database.run("COMMIT")
            } catch {
                try? database.run("ROLLBACK")
                throw error
            }
        }
    }

    /// Last N observations in insertion order, including when timestamps tie or clocks move backwards.
    func recent(limit: Int = 120) throws -> [RuntimeEvent] {
        guard let database, limit > 0 else { return [] }
        let count = min(limit, Self.retentionLimit)
        let rows = try database.rows("""
            SELECT id,call_id,timestamp,tool,kind,method,step FROM
            (SELECT * FROM runtime_events ORDER BY seq DESC LIMIT ?) ORDER BY seq
            """, [count], limit: count)
        return try rows.map { row in
            guard let idText = row[0] as? String, let id = UUID(uuidString: idText),
                  let callText = row[1] as? String, let callID = UUID(uuidString: callText),
                  let seconds = (row[2] as? Double) ?? (row[2] as? Int).map(Double.init),
                  let tool = row[3] as? String, RuntimeEvent.allowedTools.contains(tool),
                  let kindText = row[4] as? String, let kind = RuntimeEvent.Kind(rawValue: kindText),
                  let methodText = row[5] as? String, let method = RuntimeEvent.Method(rawValue: methodText),
                  row[6] == nil || row[6] is Int else { throw Error.invalidStore }
            let event = RuntimeEvent(id: id, callID: callID, timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                                     tool: tool, kind: kind, method: method, step: row[6] as? Int)
            guard Self.isValid(event) else { throw Error.invalidStore }
            return event
        }
    }

    func dataVersion() throws -> Int? {
        guard let database else { return nil }
        guard let version = try database.scalar("PRAGMA data_version") as? Int else { throw Error.invalidStore }
        return version
    }

    private static func isValid(_ event: RuntimeEvent) -> Bool {
        RuntimeEvent.allowedTools.contains(event.tool) && event.timestamp.timeIntervalSinceReferenceDate.isFinite
            && (event.step == nil || event.step! >= 0)
    }
}
