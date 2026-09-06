import Foundation
import CryptoKit

/// SQLite-backed private store. Mutations and imports are serialized and transactional.
final class LifeStore {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ppomi/Private/records.sqlite").path
    }
    let path: String
    private let db: DB
    private let lock = NSRecursiveLock()
    private let evidenceDirectory: URL

    init(path: String = LifeStore.defaultPath) throws {
        self.path = path
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        evidenceDirectory = folder.appendingPathComponent("record-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // createDirectory does not tighten permissions when the directory already exists.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        db = try DB(path: path, writable: true)
        try db.run("""
            PRAGMA foreign_keys = ON;
            PRAGMA busy_timeout = 5000;
            CREATE TABLE IF NOT EXISTS life_entities(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS life_records(id TEXT PRIMARY KEY, subject_id TEXT NOT NULL REFERENCES life_entities(id),
              occurred_at TEXT NOT NULL, source_name TEXT NOT NULL, source_record_id TEXT, payload TEXT NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS life_source_identity ON life_records(source_name, source_record_id)
              WHERE source_record_id IS NOT NULL;
            CREATE TABLE IF NOT EXISTS life_evidence(id TEXT PRIMARY KEY, payload TEXT NOT NULL, managed_name TEXT, source_reference TEXT);
            CREATE TABLE IF NOT EXISTS life_revisions(id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES life_records(id), payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS life_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func ensureSelfEntity() throws -> LifeEntity {
        try locked {
            if let id = try db.scalar("SELECT value FROM life_settings WHERE key='selfEntityID'") as? String,
               let entity = try entity(id: id) { return entity }
            return try transaction {
                if let id = try db.scalar("SELECT value FROM life_settings WHERE key='selfEntityID'") as? String,
                   let entity = try entity(id: id) { return entity }
                let person = LifeEntity(kind: .person, name: "나")
                try save(entity: person)
                try db.exec("INSERT INTO life_settings(key,value) VALUES('selfEntityID',?)", [person.id])
                return person
            }
        }
    }

    /// Opaque IDs for local source registries. Reference paths stay in private SQLite settings,
    /// never in entities or exported archives. A legacy reference is not proof of ownership.
    func sourceNamespace(for reference: String) throws -> String {
        try locked {
            guard !reference.isEmpty else { throw LifeError.validation("로컬 출처 참조가 필요합니다.") }
            let key = "sourceNamespace:" + reference
            if let value = try db.scalar("SELECT value FROM life_settings WHERE key=?", [key]) as? String { return value }
            return try transaction {
                if let value = try db.scalar("SELECT value FROM life_settings WHERE key=?", [key]) as? String { return value }
                let value = UUID().uuidString
                try db.exec("INSERT INTO life_settings(key,value) VALUES(?,?)", [key, value])
                return value
            }
        }
    }

    func entities() throws -> [LifeEntity] { try locked { try decodeRows("SELECT payload FROM life_entities ORDER BY id") } }
    func entity(id: String) throws -> LifeEntity? { try locked { try decodeRows("SELECT payload FROM life_entities WHERE id=?", [id]).first } }
    func allRecords() throws -> [LifeRecord] { try locked { try decodeRows("SELECT payload FROM life_records ORDER BY occurred_at DESC,id") } }
    func record(id: String) throws -> LifeRecord? { try locked { try decodeRows("SELECT payload FROM life_records WHERE id=?", [id]).first } }
    func evidence() throws -> [LifeEvidence] { try locked { try decodeRows("SELECT payload FROM life_evidence ORDER BY id") } }
    func revisions(recordID: String? = nil) throws -> [LifeRevision] {
        try locked {
            if let recordID { return try decodeRows("SELECT payload FROM life_revisions WHERE record_id=? ORDER BY rowid", [recordID]) }
            return try decodeRows("SELECT payload FROM life_revisions ORDER BY rowid")
        }
    }

    /// Names never act as identity keys: two accounts or organizations may have the same display name.
    func save(entity value: LifeEntity) throws {
        try locked {
            guard !value.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.id.count <= 500, value.name.count <= 500 else { throw LifeError.validation("대상의 ID와 이름이 필요합니다.") }
            if let existing = try entity(id: value.id) {
                guard existing == value else { throw LifeError.conflict("이미 존재하는 대상 ID의 정보가 다릅니다: \(value.id)") }
                return
            }
            try db.exec("INSERT INTO life_entities(id,payload) VALUES(?,?)", [value.id, try json(value)])
        }
    }

    @discardableResult func save(_ value: LifeRecord) throws -> LifeSaveResult {
        try locked { try saveUnlocked(value) }
    }

    private func saveUnlocked(_ value: LifeRecord) throws -> LifeSaveResult {
        let value: LifeRecord = try canonical(value)
        try validateReferences(value)
        if let existing = try record(id: value.id) {
            guard value.sameSourceFact(as: existing) else { throw LifeError.conflict("같은 기록 ID의 내용이 다릅니다. 수정 이력을 남겨 변경하세요.") }
            return .duplicate(existing.id)
        }
        if let sourceID = value.sourceRecordID,
           let existing: LifeRecord = try decodeRows("SELECT payload FROM life_records WHERE source_name=? AND source_record_id=?", [value.sourceName, sourceID]).first {
            guard value.sameSourceFact(as: existing) else { throw LifeError.conflict("같은 출처 기록의 내용이 다릅니다: \(value.sourceName) / \(sourceID)") }
            return .duplicate(existing.id)
        }
        try db.exec("INSERT INTO life_records(id,subject_id,occurred_at,source_name,source_record_id,payload) VALUES(?,?,?,?,?,?)",
                    [value.id, value.subjectID, LifeJSON.timestamp(value.occurredAt), value.sourceName, value.sourceRecordID, try json(value)])
        return .inserted(value.id)
    }

    /// Updating a fact always retains its previous contents. Source identity remains immutable.
    func revise(_ replacement: LifeRecord, reason: String, expectedPrevious: LifeRecord? = nil) throws {
        try locked { try transaction {
            let replacement: LifeRecord = try canonical(replacement)
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LifeError.validation("수정 이유를 적어 주세요.") }
            guard let old = try record(id: replacement.id) else { throw LifeError.missing("수정할 기록을 찾을 수 없습니다.") }
            if let expectedPrevious {
                let expected: LifeRecord = try canonical(expectedPrevious)
                guard old == expected else { throw LifeError.conflict("기록이 다른 작업에서 변경됐습니다. 최신 기록을 다시 열어 확인해 주세요.") }
            }
            guard old.subjectID == replacement.subjectID, old.sourceName == replacement.sourceName,
                  old.sourceRecordID == replacement.sourceRecordID, old.recordedAt == replacement.recordedAt else {
                throw LifeError.validation("기록의 대상·출처 ID·최초 수집 시각은 수정할 수 없습니다.")
            }
            try validateReferences(replacement)
            guard old != replacement else { return }
            let revision = LifeRevision(id: UUID().uuidString, recordID: old.id, replacedAt: Date(), reason: reason, previous: old)
            try db.exec("INSERT INTO life_revisions(id,record_id,payload) VALUES(?,?,?)", [revision.id, old.id, try json(revision)])
            try db.exec("UPDATE life_records SET occurred_at=?,payload=? WHERE id=?", [LifeJSON.timestamp(replacement.occurredAt), try json(replacement), replacement.id])
        } }
    }

    func markReviewed(id: String, expectedPrevious: LifeRecord? = nil) throws {
        try locked {
            guard var value = try record(id: id) else { throw LifeError.missing("확인할 기록을 찾을 수 없습니다.") }
            let expected = expectedPrevious ?? value
            value.review = .userConfirmed
            try revise(value, reason: "사용자가 기록 내용을 확인함", expectedPrevious: expected)
        }
    }

    /// Copies only a user-selected regular local file. Imported JSON cannot supply a readable path.
    func addEvidence(from source: URL) throws -> LifeEvidence {
        try locked {
            guard source.isFileURL else { throw LifeError.validation("로컬 증빙 파일만 첨부할 수 있습니다.") }
            let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resource.isRegularFile == true, let size = resource.fileSize, size <= 32 * 1024 * 1024 else {
                throw LifeError.validation("증빙은 32MB 이하의 일반 파일이어야 합니다.")
            }
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            guard bytes.count <= 32 * 1024 * 1024 else { throw LifeError.validation("증빙은 32MB 이하여야 합니다.") }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let value = LifeEvidence(id: UUID().uuidString, originalName: source.lastPathComponent, sha256: hash, recordedAt: Date())
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: evidenceDirectory.path)
            let safeExtensions = Set(["png", "jpg", "jpeg", "heic", "pdf", "wav", "m4a", "mp3", "json", "csv", "txt"])
            let ext = source.pathExtension.lowercased()
            let name = value.id + "." + (safeExtensions.contains(ext) ? ext : "data")
            let target = evidenceDirectory.appendingPathComponent(name)
            try bytes.write(to: target, options: .atomic)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try db.exec("INSERT INTO life_evidence(id,payload,managed_name,source_reference) VALUES(?,?,?,?)",
                            [value.id, try json(value), name, source.path])
            } catch { try? FileManager.default.removeItem(at: target); throw error }
            return value
        }
    }

    func managedEvidenceURL(id: String) throws -> URL? {
        try locked {
            guard let name = try db.scalar("SELECT managed_name FROM life_evidence WHERE id=?", [id]) as? String else { return nil }
            guard name == (name as NSString).lastPathComponent, !name.contains("..") else { throw LifeError.validation("유효하지 않은 증빙 경로입니다.") }
            let url = evidenceDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func exportJSON() throws -> Data {
        try locked { try transaction(readOnly: true) {
            try LifeJSON.encoder().encode(LifeArchive(entities: entities(), records: allRecords(), evidence: evidence(), revisions: revisions()))
        } }
    }

    /// All-or-nothing import; conflicts do not silently overwrite a user's verified record.
    func importJSON(_ data: Data) throws -> LifeImportResult {
        guard data.count <= 32 * 1024 * 1024 else { throw LifeError.validation("가져올 JSON은 32MB 이하여야 합니다.") }
        let archive = try LifeJSON.decoder().decode(LifeArchive.self, from: data)
        guard archive.formatVersion == 1 else { throw LifeError.validation("지원하지 않는 기록 형식 버전입니다.") }
        return try locked { try transaction {
            for entity in archive.entities { try save(entity: entity) }
            for evidence in archive.evidence {
                guard !evidence.id.isEmpty, evidence.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw LifeError.validation("증빙 ID 또는 SHA256이 잘못됐습니다.")
                }
                if let old: LifeEvidence = try decodeRows("SELECT payload FROM life_evidence WHERE id=?", [evidence.id]).first {
                    guard old == evidence else { throw LifeError.conflict("증빙 ID의 내용이 다릅니다.") }
                } else {
                    try db.exec("INSERT INTO life_evidence(id,payload) VALUES(?,?)", [evidence.id, try json(evidence)])
                }
            }
            var result = LifeImportResult()
            for record in archive.records {
                switch try saveUnlocked(record) {
                case .inserted: result.inserted += 1
                case .duplicate: result.duplicates += 1
                }
            }
            for revision in archive.revisions {
                guard revision.previous.id == revision.recordID, try record(id: revision.recordID) != nil,
                      !revision.id.isEmpty, !revision.reason.isEmpty else { throw LifeError.validation("수정 이력의 대상이 잘못됐습니다.") }
                try validateReferences(revision.previous)
                if let existing: LifeRevision = try decodeRows("SELECT payload FROM life_revisions WHERE id=?", [revision.id]).first {
                    guard existing == revision else { throw LifeError.conflict("수정 이력 ID가 중복됐습니다.") }
                } else {
                    try db.exec("INSERT INTO life_revisions(id,record_id,payload) VALUES(?,?,?)", [revision.id, revision.recordID, try json(revision)])
                }
            }
            return result
        } }
    }

    private func validateReferences(_ record: LifeRecord) throws {
        try record.validate()
        guard try entity(id: record.subjectID) != nil else { throw LifeError.missing("기록의 대상 ID가 등록되어 있지 않습니다.") }
        for id in record.evidenceIDs {
            guard try db.scalar("SELECT id FROM life_evidence WHERE id=?", [id]) != nil else {
                throw LifeError.missing("등록되지 않은 증빙 ID입니다: \(id)")
            }
        }
    }

    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func transaction<T>(readOnly: Bool = false, _ action: () throws -> T) throws -> T {
        try db.run(readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
        do { let result = try action(); try db.run("COMMIT"); return result }
        catch { try? db.run("ROLLBACK"); throw error }
    }
    private func canonical<T: Codable>(_ value: T) throws -> T { try LifeJSON.decoder().decode(T.self, from: LifeJSON.encoder().encode(value)) }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try LifeJSON.encoder().encode(value), as: UTF8.self) }
    private func decodeRows<T: Decodable>(_ sql: String, _ params: [Any?] = []) throws -> [T] {
        try db.rows(sql, params, limit: Int.max).map { row in
            guard let string = row.first as? String else { throw LifeError.database("기록 저장소의 형식이 잘못됐습니다.") }
            return try LifeJSON.decoder().decode(T.self, from: Data(string.utf8))
        }
    }
}
