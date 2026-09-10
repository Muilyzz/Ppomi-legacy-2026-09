import Foundation

/// Watches committed ledger values without doing SQLite or filesystem work on the UI thread.
@MainActor
final class LedgerMonitor {
    private struct Configuration: Equatable {
        let path: String
        let me: String
    }

    private let queue = DispatchQueue(label: "Ppomi.LedgerMonitor", qos: .utility)
    private let pollInterval: TimeInterval
    private let onUpdate: (Ledger) -> Void
    private let onError: ((String?) -> Void)?
    private var timer: DispatchSourceTimer?
    private var configuration: Configuration?
    private var generation = 0
    private var lastError: String?

    init(pollInterval: TimeInterval = 1, onUpdate: @escaping (Ledger) -> Void,
         onError: ((String?) -> Void)? = nil) {
        self.pollInterval = max(0.01, pollInterval)
        self.onUpdate = onUpdate
        self.onError = onError
    }

    func start(dbPath: String, me: String) {
        let path = URL(fileURLWithPath: (dbPath as NSString).expandingTildeInPath).standardizedFileURL.path
        let next = Configuration(path: path, me: me)
        guard configuration != next else { return }
        stop()
        configuration = next
        let session = generation
        let reader = LedgerChangeReader(dbPath: path, me: me)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            do {
                let ledger = try reader.poll()
                Task { @MainActor [weak self] in self?.receive(ledger, error: nil, generation: session) }
            } catch {
                let message = String(describing: error)
                Task { @MainActor [weak self] in self?.receive(nil, error: message, generation: session) }
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        configuration = nil
    }

    deinit { timer?.cancel() }

    private func receive(_ ledger: Ledger?, error: String?, generation: Int) {
        guard self.generation == generation, configuration != nil else { return }
        if lastError != error {
            lastError = error
            onError?(error)
        }
        if let ledger { onUpdate(ledger) }
    }
}

/// Owned by one serial queue. data_version must be compared on the same persistent connection.
final class LedgerChangeReader {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(path: String) throws {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw DB.Error.open(path: path, message: "파일 식별자를 읽을 수 없음")
            }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
        }
    }

    private let dbPath: String
    private let me: String
    private var database: DB?
    private var identity: FileIdentity?
    private var dataVersion: Int?
    private var previous: Ledger?

    init(dbPath: String, me: String) {
        self.dbPath = dbPath
        self.me = me
    }

    /// Returns the first valid snapshot, then only actual ledger changes. Failed reads retain the last good value.
    func poll() throws -> Ledger? {
        do {
            return try readChange()
        } catch {
            // A missing/replaced/temporarily locked database is retried on the next tick, never as an empty ledger.
            database = nil
            identity = nil
            dataVersion = nil
            throw error
        }
    }

    private func readChange() throws -> Ledger? {
        let currentIdentity = try FileIdentity(path: dbPath)
        if identity != currentIdentity {
            database = nil
            dataVersion = nil
            identity = currentIdentity
        }
        if database == nil { database = try DB(path: dbPath) }
        guard let database, let version = try database.scalar("PRAGMA data_version") as? Int else {
            throw DB.Error.query("장부 변경 버전을 읽을 수 없음")
        }
        guard dataVersion != version else { return nil }

        let ledger = try database.withReadTransaction { snapshot in
            try Ledger.load(db: snapshot, me: me)
        }
        guard try FileIdentity(path: dbPath) == currentIdentity else {
            throw DB.Error.query("읽는 동안 장부 파일이 교체됨")
        }
        dataVersion = version
        if let previous, previous.accounts == ledger.accounts, previous.series == ledger.series,
           previous.lines == ledger.lines, previous.defaultLens == ledger.defaultLens {
            return nil
        }
        previous = ledger
        return ledger
    }
}
