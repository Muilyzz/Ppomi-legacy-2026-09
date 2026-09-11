import Foundation

/// Client-side E2E transcript open/append. The agent server never sees these RPCs.
final class SharedTranscriptStore: @unchecked Sendable {
    static let shared = SharedTranscriptStore()
    static let rpcNames: Set<String> = [
        "ppomi_transcript_open", "ppomi_transcript_list", "ppomi_transcript_turns",
        "ppomi_transcript_append", "ppomi_transcript_delete",
    ]
    typealias RPC = (String, [String: Any]) throws -> Any
    private let lock = NSLock()
    private let rpc: RPC
    private let loadConfiguration: () throws -> SharedRecordKey
    private var transcriptID: String?

    init(configuration: @escaping () throws -> SharedRecordKey = SharedRecordVault.loadKey,
         rpc: @escaping RPC = { try SharedServerClient.shared.rpc($0, $1) }) {
        self.loadConfiguration = configuration; self.rpc = rpc
    }

    func open() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let config = try loadConfiguration()
        guard let head = try rpc("ppomi_transcript_open", [
            "p_transcript_id": UUID().uuidString.lowercased(), "p_key_id": config.keyID,
        ]) as? [String: Any], let id = head["id"] as? String else { throw SharedRecordError.invalid }
        transcriptID = id
        let page = try rpc("ppomi_transcript_turns", ["p_transcript_id": id, "p_after_seq": 0]) as? [String: Any]
        let rows = page?["turns"] as? [[String: Any]] ?? []
        var turns: [[String: Any]] = []
        for row in rows {
            guard let turnID = row["turn_id"] as? String, let envelope = row["envelope"] as? [String: Any] else { throw SharedRecordError.invalid }
            let data = try SharedTranscriptCrypto.open(envelope, configuration: config, transcriptID: id, turnID: turnID)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SharedRecordError.invalid }
            turns.append(payload)
        }
        return ["transcript_id": id, "turns": turns]
    }

    func append(_ turn: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let config = try loadConfiguration()
        if transcriptID == nil { _ = try openUnlocked(config) }
        guard let id = transcriptID, let turnID = turn["id"] as? String, !turnID.isEmpty,
              (turn["role"] as? String == "user" || turn["role"] as? String == "assistant"),
              turn["parts"] is [Any] else { throw SharedRecordError.invalid }
        let data = try JSONSerialization.data(withJSONObject: turn, options: [.sortedKeys])
        let envelope = try SharedTranscriptCrypto.seal(data, configuration: config, transcriptID: id, turnID: turnID)
        guard let saved = try rpc("ppomi_transcript_append", [
            "p_transcript_id": id, "p_turn_id": turnID, "p_key_id": config.keyID, "p_envelope": envelope,
        ]) as? [String: Any] else { throw SharedRecordError.invalid }
        return saved
    }

    private func openUnlocked(_ config: SharedRecordKey) throws -> String {
        guard let head = try rpc("ppomi_transcript_open", [
            "p_transcript_id": UUID().uuidString.lowercased(), "p_key_id": config.keyID,
        ]) as? [String: Any], let id = head["id"] as? String else { throw SharedRecordError.invalid }
        transcriptID = id
        return id
    }
}
