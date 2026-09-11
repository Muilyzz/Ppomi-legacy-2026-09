import XCTest
@testable import Ppomi

final class SharedTranscriptStoreTests: XCTestCase {
    func testStoreOpensAndAppendsStoredTurns() throws {
        let server = TranscriptServer()
        let store = SharedTranscriptStore(rpc: server.rpc)
        let opened = try store.open()
        XCTAssertEqual((opened["turns"] as? [Any])?.count, 0)
        XCTAssertEqual(try store.append(["id": "11111111-1111-4111-8111-111111111111", "role": "user",
                                        "parts": [["type": "text", "text": "안녕"]]])["seq"] as? Int64, 1)
        let again = try SharedTranscriptStore(rpc: server.rpc).open()
        let turns = again["turns"] as? [[String: Any]]
        XCTAssertEqual(turns?.count, 1)
        XCTAssertEqual(((turns?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String), "안녕")
        XCTAssertEqual(server.payloads.first?["id"] as? String, "11111111-1111-4111-8111-111111111111")
    }
}

private final class TranscriptServer {
    var payloads: [[String: Any]] = []
    private var id: String?
    private var turns: [(id: String, payload: [String: Any])] = []
    func rpc(_ method: String, _ args: [String: Any]) throws -> Any {
        switch method {
        case "ppomi_transcript_open":
            if let id { return ["id": id] }
            let created = args["p_transcript_id"] as! String
            id = created
            return ["id": created]
        case "ppomi_transcript_turns":
            return ["found": true, "transcript_id": id ?? "", "turns": turns.enumerated().map { index, row in
                ["turn_id": row.id, "seq": Int64(index + 1), "payload": row.payload] as [String: Any]
            }]
        case "ppomi_transcript_append":
            let turnID = args["p_turn_id"] as! String
            let payload = args["p_payload"] as! [String: Any]
            if let existing = turns.first(where: { $0.id == turnID }) {
                return ["turn_id": turnID, "seq": Int64(turns.firstIndex(where: { $0.id == turnID })! + 1),
                        "payload": existing.payload]
            }
            turns.append((turnID, payload))
            payloads.append(payload)
            return ["turn_id": turnID, "seq": Int64(turns.count), "payload": payload]
        default: throw SharedRecordError.invalid
        }
    }
}
