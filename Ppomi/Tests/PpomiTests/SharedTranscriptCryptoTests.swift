import XCTest
@testable import Ppomi

final class SharedTranscriptCryptoTests: XCTestCase {
    private func config() -> SharedRecordKey {
        .init(workspaceID: UUID().uuidString.lowercased(), deviceID: UUID().uuidString.lowercased(),
              keyID: UUID().uuidString.lowercased(), key: Data(repeating: 7, count: 32),
              records: ["ledger": UUID().uuidString.lowercased()], sourcePath: "/synthetic")
    }

    func testTurnEnvelopeRoundTripAndAADBinding() throws {
        let config = config(), transcript = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        let data = Data("{\"id\":\"\(turn)\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"카드값\"}]}".utf8)
        let envelope = try SharedTranscriptCrypto.seal(data, configuration: config, transcriptID: transcript, turnID: turn)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(try SharedTranscriptCrypto.open(envelope, configuration: config, transcriptID: transcript, turnID: turn), data)
        XCTAssertThrowsError(try SharedTranscriptCrypto.open(envelope, configuration: config, transcriptID: UUID().uuidString, turnID: turn))
        XCTAssertThrowsError(try SharedTranscriptCrypto.open(envelope, configuration: config, transcriptID: transcript, turnID: UUID().uuidString))
        var other = config; other.keyID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try SharedTranscriptCrypto.open(envelope, configuration: other, transcriptID: transcript, turnID: turn))
        var tampered = envelope; tampered["ciphertext"] = "AAAA"
        XCTAssertThrowsError(try SharedTranscriptCrypto.open(tampered, configuration: config, transcriptID: transcript, turnID: turn))
    }

    func testStoreOpensAndAppendsDecryptedTurns() throws {
        let config = config()
        let server = TranscriptServer(config)
        let store = SharedTranscriptStore(configuration: { config }, rpc: server.rpc)
        let opened = try store.open()
        XCTAssertEqual((opened["turns"] as? [Any])?.count, 0)
        XCTAssertEqual(try store.append(["id": "11111111-1111-4111-8111-111111111111", "role": "user",
                                        "parts": [["type": "text", "text": "안녕"]]])["seq"] as? Int64, 1)
        let again = try SharedTranscriptStore(configuration: { config }, rpc: server.rpc).open()
        let turns = again["turns"] as? [[String: Any]]
        XCTAssertEqual(turns?.count, 1)
        XCTAssertEqual(((turns?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String), "안녕")
        XCTAssertFalse(server.envelopes.contains(where: { $0.contains("안녕") }))
    }
}

private final class TranscriptServer {
    var envelopes: [String] = []
    private var id: String?
    private var turns: [(id: String, envelope: [String: Any])] = []
    private let config: SharedRecordKey
    init(_ config: SharedRecordKey) { self.config = config }
    func rpc(_ method: String, _ args: [String: Any]) throws -> Any {
        switch method {
        case "ppomi_transcript_open":
            if let id { return ["id": id, "workspace_id": config.workspaceID, "key_id": config.keyID,
                                "created_by_device_id": config.deviceID] }
            let created = args["p_transcript_id"] as! String
            id = created
            return ["id": created, "workspace_id": config.workspaceID, "key_id": config.keyID,
                    "created_by_device_id": config.deviceID]
        case "ppomi_transcript_turns":
            return ["found": true, "transcript_id": id ?? "", "turns": turns.enumerated().map { index, row in
                ["turn_id": row.id, "seq": Int64(index + 1), "writer_device_id": config.deviceID,
                 "key_id": config.keyID, "envelope": row.envelope] as [String: Any]
            }]
        case "ppomi_transcript_append":
            let turnID = args["p_turn_id"] as! String
            let envelope = args["p_envelope"] as! [String: Any]
            if let existing = turns.first(where: { $0.id == turnID }) {
                return ["turn_id": turnID, "seq": Int64(turns.firstIndex(where: { $0.id == turnID })! + 1),
                        "envelope": existing.envelope]
            }
            turns.append((turnID, envelope))
            if let data = try? JSONSerialization.data(withJSONObject: envelope) {
                envelopes.append(String(data: data, encoding: .utf8) ?? "")
            }
            return ["turn_id": turnID, "seq": Int64(turns.count), "envelope": envelope]
        default: throw SharedRecordError.invalid
        }
    }
}
