import Foundation
import Darwin

extension SharedLedgerArchive {
    static func capture(path: String, me: String) throws -> Self {
        let db = try DB(path: path)
        try db.run("BEGIN DEFERRED TRANSACTION")
        defer { try? db.run("ROLLBACK") }
        var tables: [String: Any] = [:]
        for table in ["snapshots", "transactions"] {
            let result = try db.table("SELECT * FROM \(table) ORDER BY id", limit: Int.max)
            tables[table] = ["columns": result.cols, "rows": result.rows.map { $0.map { $0 ?? NSNull() } }]
        }
        var archive = Self(snapshots: try db.snapshots().map { Snapshot(app: $0.app, account: $0.account, balance: $0.balance, ts: $0.ts) },
                    transactions: try db.transactions(), me: me,
                    originalTables: try JSONSerialization.data(withJSONObject: tables, options: [.sortedKeys]),
                    lenses: LensStore.load(dbPath: path), nodes: LensStore.nodes(dbPath: path))
        archive.timelinePresentation = try JSONSerialization.data(withJSONObject: LedgerPage.timelineData(archive.ledger()), options: [.sortedKeys])
        return archive
    }
}

struct SharedHealthArchive: Codable { var archive: LifeArchive; var selfID: String }

enum SharedRecordsSource {
    private static let lock = NSRecursiveLock()
    private static var evidenceCache: (signature: String, data: Data)?

    static func decode<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        try LifeJSON.decoder().decode(type, from: SharedRecordVault.shared.read(name, refresh: false).data)
    }
    static func accounting() throws -> AccountingArchive {
        guard SharedRecordVault.enabled else { return try AccountingStore().snapshot() }
        let value = try decode(AccountingArchive.self, name: "accounting")
        try AccountingEngine.validate(value)
        return value
    }
    static func spatial(path: String = SpatialStore.defaultPath) throws -> SpatialArchive {
        guard SharedRecordVault.enabled, path == SpatialStore.defaultPath else { return try SpatialStore(path: path).snapshot() }
        let value = try SpatialStore.decode(SharedRecordVault.shared.read("spatial", refresh: false).data)
        if SpatialAccountingLinks.hasLinks(value) { try SpatialAccountingLinks.validate(spatial: value, accounting: accounting()) }
        return value
    }
    static func evidence(path: String) throws -> String {
        guard SharedRecordVault.enabled else { return Evidence.html(dbPath: path) }
        guard let html = String(data: try SharedRecordVault.shared.read("evidence", refresh: false).data, encoding: .utf8) else { throw SharedRecordError.invalid }
        return html
    }

    /// Only this explicit source adapter publishes. Presentation reads cannot seed or overwrite the server.
    @discardableResult static func publish(_ name: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let directory = SharedRecordVault.defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("source.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SharedRecordError.unavailable }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SharedRecordError.unavailable }; defer { flock(fd, LOCK_UN) }
        let config = try SharedRecordVault.loadKey()
        guard config.sourcePath == URL(fileURLWithPath: AppSettings.dbPath).standardizedFileURL.path else { throw SharedRecordError.sourceChanged }
        return try SharedRecordVault.shared.publish(name, data: capture(name))
    }
    static func publishIfEnabled(_ name: String) throws {
        if SharedRecordVault.enabled { try publish(name) }
    }
    static func capture(_ name: String) throws -> Data {
        switch name {
        case "ledger": return try LifeJSON.encoder().encode(SharedLedgerArchive.capture(path: AppSettings.dbPath, me: AppSettings.me))
        case "accounting": return try LifeJSON.encoder().encode(AccountingStore().snapshot())
        case "spatial": return try SpatialStore.encode(SpatialStore().snapshot())
        case "health":
            let store = try LifeStore(), selfID = try store.ensureSelfEntity().id
            let archive = try LifeJSON.decoder().decode(LifeArchive.self, from: store.exportJSON())
            return try LifeJSON.encoder().encode(SharedHealthArchive(archive: archive, selfID: selfID))
        case "playbooks": return try LifeJSON.encoder().encode(SharedPlaybooksArchive.capture())
        case "evidence":
            let signature = try evidenceSignature()
            if let cache = evidenceCache, cache.signature == signature { return cache.data }
            let data = Data(Evidence.html(dbPath: AppSettings.dbPath).utf8)
            // Do not confirm a preview assembled while its source collection was changing.
            guard signature == (try evidenceSignature()) else { throw SharedRecordError.unavailable }
            evidenceCache = (signature, data)
            return data
        default: throw SharedRecordError.invalid
        }
    }
    private static func evidenceSignature() throws -> String {
        let dir = URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().appendingPathComponent("shots")
        var parts = [SharedRecordCrypto.hash(try capture("ledger")), SharedRecordCrypto.hash(Data(Web.page("evidence").utf8))]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        if let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) {
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: Set(keys))
                if values.isRegularFile == true { parts.append("\(file.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)") }
            }
        }
        return SharedRecordCrypto.hash(Data(parts.sorted().joined(separator: "\n").utf8))
    }

    /// Called by the signed app CLI. The feature is enabled only after every dataset has been read back.
    static func migrate() throws {
        _ = try SharedRecordVault.prepareKey()
        for name in SharedRecordVault.names {
            let version = try publish(name)
            let value = try SharedRecordVault.shared.read(name)
            guard version == value.version else { throw SharedRecordError.conflict }
            print("\(name): server v\(version), verified")
        }
        UserDefaults.standard.set(true, forKey: "sharedRecordsEnabled.v1")
    }

    /// Independent read with an empty cache proves the data came from Supabase.
    /// Diagnostic output contains dataset names, revisions and equality only.
    static func verifyRemote() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-record-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = SharedRecordVault(directory: directory)
        for name in SharedRecordVault.names {
            let value = try vault.read(name)
            guard value.data == (try capture(name)) else { throw SharedRecordError.conflict }
            if name == "ledger" {
                let restored = try LifeJSON.decoder().decode(SharedLedgerArchive.self, from: value.data).ledger()
                let original = try Ledger.load(dbPath: AppSettings.dbPath, me: AppSettings.me)
                let left = try JSONSerialization.data(withJSONObject: Timeline.data(restored), options: .sortedKeys)
                let right = try JSONSerialization.data(withJSONObject: Timeline.data(original), options: .sortedKeys)
                guard left == right else { throw SharedRecordError.invalid }
            }
            print("\(name): server v\(value.version), empty-cache read matches source")
        }
    }
}

/// Refresh and source publication run outside the main thread. Only authenticated server values reach AppState.
final class SharedRecordsMonitor {
    struct Update {
        var ledger: Ledger?
        var versions: [String: Int64]
        var confirmedAt: Date?
        var error: String?
        var checking = false
        var status: String {
            if checking { return "Supabase 확인 중 · 마지막 서버 기록" }
            if error != nil { return "오프라인·반영 대기 · 마지막 서버 기록" }
            guard let version = versions["ledger"] else { return "Supabase · 서버 기록 확인 중" }
            return "Supabase · 서버 v\(version)"
        }
    }
    private let queue = DispatchQueue(label: "ppomi.shared-records", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let onUpdate: (Update) -> Void
    init(onUpdate: @escaping (Update) -> Void) { self.onUpdate = onUpdate }
    func start() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var update = Update(versions: [:], checking: true)
            for name in SharedRecordVault.names {
                guard let value = try? SharedRecordVault.shared.read(name, refresh: false) else { continue }
                update.versions[name] = value.version
                update.confirmedAt = min(update.confirmedAt ?? value.confirmedAt, value.confirmedAt)
                if name == "ledger" { update.ledger = try? LifeJSON.decoder().decode(SharedLedgerArchive.self, from: value.data).ledger() }
            }
            DispatchQueue.main.async { [onUpdate] in onUpdate(update) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer; timer.resume()
    }
    /// 지금 바로 한 바퀴. `only` 를 주면 그 기록만 올리고 받는다(사람이 방금 고친 것 = 장부 하나); 나머지 버전은 지난 값을 그대로 든다.
    func request(only names: [String]? = nil) { queue.async { [weak self] in self?.refresh(names ?? SharedRecordVault.names) } }
    deinit { timer?.cancel() }
    private var known: [String: Int64] = [:]           // 마지막으로 확인한 버전(큐 안에서만 만진다)
    private func refresh(_ names: [String] = SharedRecordVault.names) {
        var update = Update(versions: known)
        for name in names {
            do {
                try SharedRecordsSource.publish(name)
                _ = try SharedRecordVault.shared.read(name)
            } catch {
                update.error = (error as? SharedRecordError)?.errorDescription ?? "서버 반영 대기 · 원본은 보존되어 있습니다."
            }
            do {
                let value = try SharedRecordVault.shared.read(name, refresh: false)
                update.versions[name] = value.version
                update.confirmedAt = min(update.confirmedAt ?? value.confirmedAt, value.confirmedAt)
                if name == "ledger" { update.ledger = try LifeJSON.decoder().decode(SharedLedgerArchive.self, from: value.data).ledger() }
            } catch { update.error = "확인된 서버 기록을 읽지 못했습니다. 원본은 보존되어 있습니다." }
        }
        known = update.versions
        DispatchQueue.main.async { [onUpdate] in onUpdate(update) }
    }
}
