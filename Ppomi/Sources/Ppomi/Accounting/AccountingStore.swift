import Foundation

/// Private immutable journals. Each import validates the resulting archive and commits atomically.
final class AccountingStore {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ppomi/Private/accounting.sqlite").path
    }
    let path: String
    private let db: DB

    init(path: String = AccountingStore.defaultPath) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        db = try DB(path: path, writable: true)
        try db.withLockedAccess {
            try db.run("""
                PRAGMA busy_timeout = 5000;
                CREATE TABLE IF NOT EXISTS accounting_books(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS accounting_accounts(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS accounting_entries(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                """)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func snapshot() throws -> AccountingArchive {
        try transaction(readOnly: true) {
            let archive = try readArchive()
            try AccountingEngine.validate(archive)
            return archive
        }
    }

    /// The returned count includes newly inserted books, accounts and entries. Identical IDs are safe retries.
    @discardableResult func importArchive(_ archive: AccountingArchive) throws -> Int {
        guard archive.formatVersion == 1 else { throw AccountingError.validation("지원하지 않는 회계 자료 버전입니다.") }
        guard archive.entries.allSatisfy({ $0.occurredAt.timeIntervalSince1970.isFinite && $0.recordedAt.timeIntervalSince1970.isFinite }) else {
            throw AccountingError.validation("분개의 발생·기록 시각이 유효하지 않습니다.")
        }
        // Millisecond date canonicalization makes retries equal to their persisted representation.
        let incoming = try LifeJSON.decoder().decode(AccountingArchive.self, from: LifeJSON.encoder().encode(archive))
        return try transaction {
            let old = try readArchive()
            let books = try merge(old.books, incoming.books, id: \.id)
            let accounts = try merge(old.accounts, incoming.accounts, id: \.id)
            let entries = try merge(old.entries, incoming.entries, id: \.id)
            let combined = AccountingArchive(books: books.all, accounts: accounts.all, entries: entries.all)
            try AccountingEngine.validate(combined)
            for value in books.inserted { try insert(value, id: value.id, table: "accounting_books") }
            for value in accounts.inserted { try insert(value, id: value.id, table: "accounting_accounts") }
            for value in entries.inserted { try insert(value, id: value.id, table: "accounting_entries") }
            return books.inserted.count + accounts.inserted.count + entries.inserted.count
        }
    }

    private func readArchive() throws -> AccountingArchive {
        try AccountingArchive(books: rows("accounting_books"), accounts: rows("accounting_accounts"), entries: rows("accounting_entries"))
    }

    private func rows<T: Decodable>(_ table: String) throws -> [T] {
        try db.rows("SELECT payload FROM \(table) ORDER BY id", limit: Int.max).map { row in
            guard let value = row.first as? String else { throw AccountingError.database("회계 저장소의 자료 형식이 잘못됐습니다.") }
            return try LifeJSON.decoder().decode(T.self, from: Data(value.utf8))
        }
    }

    private func insert<T: Encodable>(_ value: T, id: String, table: String) throws {
        let payload = String(decoding: try LifeJSON.encoder().encode(value), as: UTF8.self)
        try db.exec("INSERT INTO \(table)(id,payload) VALUES(?,?)", [id, payload])
    }

    private func merge<T: Equatable>(_ old: [T], _ incoming: [T], id: KeyPath<T, String>) throws -> (all: [T], inserted: [T]) {
        var indexed: [String: T] = [:]
        for value in old {
            guard indexed[value[keyPath: id]] == nil else { throw AccountingError.database("저장된 회계 ID가 중복됐습니다.") }
            indexed[value[keyPath: id]] = value
        }
        var seen: Set<String> = [], inserted: [T] = []
        for value in incoming {
            let key = value[keyPath: id]
            guard seen.insert(key).inserted else { throw AccountingError.validation("가져오는 회계 ID가 중복됐습니다: \(key)") }
            if let previous = indexed[key] {
                guard value == previous else { throw AccountingError.conflict("같은 회계 ID의 내용을 덮어쓸 수 없습니다: \(key)") }
            } else {
                indexed[key] = value; inserted.append(value)
            }
        }
        return (old + inserted, inserted)
    }

    private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
        try db.withLockedAccess {
            try db.run(readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
            do { let result = try body(); try db.run("COMMIT"); return result }
            catch { try? db.run("ROLLBACK"); throw error }
        }
    }
}
