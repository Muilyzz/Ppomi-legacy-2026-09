import Foundation

/// Records execution phases only. Arguments, results, screen contents and user text never enter this API.
final class RuntimeRecorder {
    private final class Call {
        let id = UUID()
        let tool: String
        var terminal: RuntimeEvent.Kind?
        init(tool: String) { self.tool = tool }
    }

    private let contextKey = "ppomi.runtime." + UUID().uuidString
    private let writeLock = NSRecursiveLock()
    private let write: (RuntimeEvent) throws -> Void

    init(emit: @escaping (RuntimeEvent) throws -> Void) { write = emit }

    convenience init(ledgerPath: String) {
        var store: RuntimeEventStore?
        self.init { event in
            if store == nil { store = try RuntimeEventStore(ledgerPath: ledgerPath) }
            try store?.append(event)
        }
    }

    /// Resolve a legacy Tools caller's ledger lazily; constructing Tools does not open the runtime store.
    convenience init(ledgerDB: DB) {
        var store: RuntimeEventStore?
        self.init { event in
            if store == nil {
                let databases = try ledgerDB.rows("PRAGMA database_list")
                guard let path = databases.first(where: { $0[1] as? String == "main" })?[2] as? String,
                      !path.isEmpty else { return }
                store = try RuntimeEventStore(ledgerPath: path)
            }
            try store?.append(event)
        }
    }

    /// Tools and MCP calls are synchronous. Nested wrappers on the same thread share one call identity.
    func withCall<T>(_ tool: String, _ body: () throws -> T) rethrows -> T {
        if currentCall != nil { return try body() }
        guard RuntimeEvent.allowedTools.contains(tool) else { return try body() }
        let call = Call(tool: tool)
        Thread.current.threadDictionary[contextKey] = call
        defer { Thread.current.threadDictionary.removeObject(forKey: contextKey) }
        emit(.started)
        do {
            let result = try body()
            if call.terminal == nil { emit(.returned) }
            return result
        } catch {
            emit(.failed)
            throw error
        }
    }

    func emit(_ kind: RuntimeEvent.Kind, method: RuntimeEvent.Method = .tool, step: Int? = nil) {
        guard let call = currentCall else { return }
        let terminal = kind == .blocked || kind == .failed || kind == .handedOff
        if terminal {
            guard call.terminal == nil else { return }
            call.terminal = kind
        }
        let event = RuntimeEvent(callID: call.id, tool: call.tool, kind: kind, method: method,
                                 step: step.flatMap { $0 >= 0 ? $0 : nil })
        writeLock.lock()
        defer { writeLock.unlock() }
        try? write(event) // Diagnostics must never change the original tool's result or error.
    }

    private var currentCall: Call? { Thread.current.threadDictionary[contextKey] as? Call }
}
