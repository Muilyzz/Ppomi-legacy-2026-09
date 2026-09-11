import Foundation

/// Uploads conversation turns as JSON the server can read. No client E2E key.
final class SharedTranscriptStore: @unchecked Sendable {
    static let shared = SharedTranscriptStore()
    static let rpcNames: Set<String> = [
        "ppomi_transcript_open", "ppomi_transcript_list", "ppomi_transcript_turns",
        "ppomi_transcript_append", "ppomi_transcript_delete",
    ]
    typealias RPC = (String, [String: Any]) throws -> Any
    private let lock = NSLock()
    private let rpc: RPC
    private var transcriptID: String?

    init(rpc: @escaping RPC = { try SharedServerClient.shared.rpc($0, $1) }) {
        self.rpc = rpc
    }

    func open() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let id = try openUnlocked()
        let page = try rpc("ppomi_transcript_turns", ["p_transcript_id": id, "p_after_seq": 0]) as? [String: Any]
        let rows = page?["turns"] as? [[String: Any]] ?? []
        var turns: [[String: Any]] = []
        for row in rows {
            guard let payload = row["payload"] as? [String: Any] else { throw SharedRecordError.invalid }
            turns.append(payload)
        }
        return ["transcript_id": id, "turns": turns]
    }

    func append(_ turn: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if transcriptID == nil { _ = try openUnlocked() }
        guard let id = transcriptID, let turnID = turn["id"] as? String, !turnID.isEmpty,
              (turn["role"] as? String == "user" || turn["role"] as? String == "assistant"),
              turn["parts"] is [Any] else { throw SharedRecordError.invalid }
        guard let saved = try rpc("ppomi_transcript_append", [
            "p_transcript_id": id, "p_turn_id": turnID, "p_payload": turn,
        ]) as? [String: Any] else { throw SharedRecordError.invalid }
        return saved
    }

    private func openUnlocked() throws -> String {
        if let transcriptID { return transcriptID }
        guard let head = try rpc("ppomi_transcript_open", [
            "p_transcript_id": UUID().uuidString.lowercased(),
        ]) as? [String: Any], let id = head["id"] as? String else { throw SharedRecordError.invalid }
        transcriptID = id
        return id
    }
}
