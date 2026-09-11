import Darwin
import Foundation

/// Bounded JSONL framing: an oversized line is rejected once and discarded through its newline.
struct AgentExecutorLineDecoder {
    static let limit = 1536 * 1024
    enum Frame { case line(Data), oversized }
    private var bytes = Data()
    private var discarding = false
    mutating func append(_ data: Data) -> [Frame] {
        var frames = [Frame]()
        for byte in data {
            if byte == 10 {
                if !discarding && !bytes.isEmpty { frames.append(.line(bytes)) }
                bytes.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if bytes.count == Self.limit {
                    bytes.removeAll(keepingCapacity: true); discarding = true; frames.append(.oversized)
                } else { bytes.append(byte) }
            }
        }
        return frames
    }
    mutating func finish() -> [Frame] {
        defer { bytes.removeAll(); discarding = false }
        return !discarding && !bytes.isEmpty ? [.line(bytes)] : []
    }
}

/// fd 1 is reserved before creating any native service; legacy diagnostics go to stderr.
@MainActor
enum AgentExecutorStdio {
    static func run() -> Never {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(1) }
        signal(SIGPIPE, SIG_IGN)
        let writer = Writer(descriptor: descriptor)
        let executor = AgentExecutor()
        executor.onEvent = { event, payload in writer.send(["event": event, "payload": payload]) }
        let accept: (AgentExecutorLineDecoder.Frame) -> Void = { frame in
            switch frame {
            case .oversized: writer.invalid()
            case .line(let data):
                guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { writer.invalid(); return }
                executor.receive(request) { writer.send($0) }
            }
        }
        DispatchQueue(label: "ppomi.agent.executor.stdin").async {
            var decoder = AgentExecutorLineDecoder()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // Foundation read(upToCount:) may wait for the whole count on a pipe. POSIX read
                // returns each available frame immediately while the parent keeps stdin open.
                let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    fputs("executor: input unavailable\n", stderr); break
                }
                for frame in decoder.append(Data(buffer.prefix(count))) { DispatchQueue.main.async { accept(frame) } }
            }
            for frame in decoder.finish() { DispatchQueue.main.async { accept(frame) } }
            DispatchQueue.main.async { executor.invalidate(); exit(0) }
        }
        RunLoop.main.run()
        exit(0)
    }

    private final class Writer: @unchecked Sendable {
        private let output: FileHandle
        private let lock = NSLock()
        init(descriptor: Int32) { output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
            data.append(10)
            lock.lock(); defer { lock.unlock() }
            do { try output.write(contentsOf: data) }
            catch { fputs("executor: output unavailable\n", stderr); exit(1) }
        }
        func invalid() { send(["id": NSNull(), "error": ["code": "invalid_request", "message": "올바른 JSONL 요청이 필요합니다."]]) }
    }
}
