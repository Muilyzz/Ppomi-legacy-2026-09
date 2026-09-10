import Foundation

@MainActor
final class RuntimeEventMonitor {
    private let queue = DispatchQueue(label: "Ppomi.RuntimeEventMonitor", qos: .utility)
    private let pollInterval: TimeInterval
    private let onUpdate: ([RuntimeEvent]) -> Void
    private let onError: ((Bool) -> Void)?
    private var timer: DispatchSourceTimer?
    private var ledgerPath: String?
    private var generation = 0
    private var unavailable = false

    init(pollInterval: TimeInterval = 0.4, onUpdate: @escaping ([RuntimeEvent]) -> Void,
         onError: ((Bool) -> Void)? = nil) {
        self.pollInterval = max(0.01, pollInterval)
        self.onUpdate = onUpdate
        self.onError = onError
    }

    func start(ledgerPath: String) {
        let path = URL(fileURLWithPath: (ledgerPath as NSString).expandingTildeInPath).standardizedFileURL.path
        guard self.ledgerPath != path else { return }
        stop()
        self.ledgerPath = path
        let session = generation
        let reader = RuntimeEventChangeReader(ledgerPath: path)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(40))
        source.setEventHandler { [weak self] in
            do {
                let events = try reader.poll()
                Task { @MainActor [weak self] in self?.receive(events, unavailable: false, generation: session) }
            } catch {
                Task { @MainActor [weak self] in self?.receive(nil, unavailable: true, generation: session) }
            }
        }
        source.setCancelHandler { reader.close() }
        timer = source
        source.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        ledgerPath = nil
    }

    deinit { timer?.cancel() }

    private func receive(_ events: [RuntimeEvent]?, unavailable: Bool, generation: Int) {
        guard generation == self.generation, ledgerPath != nil else { return }
        if self.unavailable != unavailable {
            self.unavailable = unavailable
            onError?(unavailable)
        }
        if let events { onUpdate(events) }
    }
}

/// One queue owns this persistent read-only handle and its data_version baseline.
final class RuntimeEventChangeReader {
    private struct FileIdentity: Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64

        static func read(path: String) throws -> Self? {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard let device = attributes[.systemNumber] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber else { throw RuntimeEventStore.Error.invalidStore }
                return Self(path: path, device: device.uint64Value, inode: inode.uint64Value)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return nil
            }
        }
    }

    private let ledgerPath: String
    private var store: RuntimeEventStore?
    private var identity: FileIdentity?
    private var dataVersion: Int?
    private var previous: [RuntimeEvent]?

    init(ledgerPath: String) { self.ledgerPath = ledgerPath }

    /// Release the SQLite handle on its owner queue even when the UI stops or deinitializes the monitor.
    func close() {
        store = nil
        identity = nil
        dataVersion = nil
    }

    func poll() throws -> [RuntimeEvent]? {
        do { return try readChange() }
        catch {
            store = nil
            identity = nil
            dataVersion = nil
            throw error
        }
    }

    private func readChange() throws -> [RuntimeEvent]? {
        let path = RuntimeEventStore.path(for: ledgerPath)
        let currentIdentity = try FileIdentity.read(path: path)
        if identity != currentIdentity {
            store = nil
            dataVersion = nil
            identity = currentIdentity
        }
        guard currentIdentity != nil else {
            if previous == nil { previous = []; return [] }
            return nil
        }
        if store == nil { store = try RuntimeEventStore(ledgerPath: ledgerPath, writable: false) }
        guard let store, let version = try store.dataVersion() else { throw RuntimeEventStore.Error.invalidStore }
        guard dataVersion != version else { return nil }
        let events = try store.recent()
        guard try FileIdentity.read(path: path) == currentIdentity else { throw RuntimeEventStore.Error.invalidStore }
        dataVersion = version
        guard previous != events else { return nil }
        previous = events
        return events
    }
}
