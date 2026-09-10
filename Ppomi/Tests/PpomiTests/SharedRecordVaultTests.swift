import XCTest
import CryptoKit
@testable import Ppomi

final class SharedRecordVaultTests: XCTestCase {
    private func config() -> SharedRecordVault.Configuration {
        .init(workspaceID: UUID().uuidString.lowercased(), deviceID: UUID().uuidString.lowercased(), keyID: UUID().uuidString.lowercased(),
              key: Data(repeating: 42, count: 32), records: ["ledger": UUID().uuidString.lowercased()], sourcePath: "/synthetic")
    }
    private final class Server {
        var heads: [String: [String: Any]] = [:], blobs: [String: String] = [:], operations: [String: [String: Any]] = [:]
        var methods: [String] = [], lostReply = false, offline = false
        let config: SharedRecordVault.Configuration
        init(_ config: SharedRecordVault.Configuration) { self.config = config }
        func rpc(_ method: String, _ args: [String: Any]) throws -> Any {
            methods.append(method)
            if offline { throw SharedRecordError.unavailable }
            switch method {
            case "ppomi_context": return ["workspace": ["id": config.workspaceID], "device": ["id": config.deviceID]]
            case "ppomi_record_get": return heads[args["p_record_id"] as! String] ?? ["found": false]
            case "ppomi_record_blob_put":
                blobs[args["p_hash"] as! String] = args["p_data"] as? String; return [:]
            case "ppomi_record_blob_get":
                let hash = args["p_hash"] as! String
                return ["hash": hash, "data": blobs[hash] ?? ""]
            case "ppomi_record_put":
                let operation = args["p_operation_id"] as! String
                if let existing = operations[operation] { return existing }
                let id = args["p_record_id"] as! String, expected = args["p_expected_version"] as! Int64
                guard (heads[id]?["version"] as? Int64 ?? 0) == expected else { throw SharedRecordError.conflict }
                let head: [String: Any] = ["found": true, "record_id": id, "workspace_id": config.workspaceID,
                    "writer_device_id": config.deviceID, "key_id": args["p_key_id"]!, "version": expected + 1,
                    "chunk_ids": args["p_chunk_ids"]!, "updated_at": "synthetic-\(expected + 1)"]
                heads[id] = head; operations[operation] = head
                if lostReply { lostReply = false; throw SharedRecordError.unavailable }
                return head
            default: throw SharedRecordError.invalid
            }
        }
    }
    func testCiphertextBindsWorkspaceKeyRecordVersionOrderAndRejectsTampering() throws {
        let config = config(), id = config.records["ledger"]!
        var bytes = [UInt8](repeating: 0, count: 900000)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), errSecSuccess)
        let data = Data(bytes)
        let chunks = try SharedRecordVault.seal(data, configuration: config, recordID: id, version: 7)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(try SharedRecordVault.open(chunks, configuration: config, recordID: id, version: 7), data)
        XCTAssertThrowsError(try SharedRecordVault.open(chunks, configuration: config, recordID: UUID().uuidString, version: 7))
        XCTAssertThrowsError(try SharedRecordVault.open(chunks, configuration: config, recordID: id, version: 8))
        XCTAssertThrowsError(try SharedRecordVault.open(chunks.reversed(), configuration: config, recordID: id, version: 7))
        var wrong = config; wrong.workspaceID = UUID().uuidString
        XCTAssertThrowsError(try SharedRecordVault.open(chunks, configuration: wrong, recordID: id, version: 7))
        wrong = config; wrong.key = Data(repeating: 21, count: 32)
        XCTAssertThrowsError(try SharedRecordVault.open(chunks, configuration: wrong, recordID: id, version: 7))
        var corrupt = chunks; corrupt[0][30] ^= 1
        XCTAssertThrowsError(try SharedRecordVault.open(corrupt, configuration: config, recordID: id, version: 7))
    }
    func testLostCommitReplyResumesExactOperationAndReadsServerBeforeConfirmation() throws {
        let config = config(), server = Server(config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("SYNTHETIC_PRIVATE_RECORD_VALUE_123456789".utf8)
        let vault = SharedRecordVault(directory: directory, configuration: { config }, rpc: server.rpc)
        XCTAssertThrowsError(try vault.read("ledger"))
        XCTAssertFalse(server.methods.contains("ppomi_record_put"), "Reading cannot initialize the server")
        server.lostReply = true
        XCTAssertThrowsError(try vault.publish("ledger", data: source))
        XCTAssertThrowsError(try vault.read("ledger", refresh: false), "An uncertain write is not confirmed")
        let recovered = SharedRecordVault(directory: directory, configuration: { config }, rpc: server.rpc)
        XCTAssertEqual(try recovered.publish("ledger", data: source), 1)
        XCTAssertEqual(server.operations.count, 1, "Restart replays the exact operation, not a second revision")
        XCTAssertTrue(server.methods.contains("ppomi_record_blob_get"), "Publishing must download server ciphertext, not merely echo the source")
        XCTAssertEqual(try recovered.read("ledger").data, source)
        XCTAssertEqual(try recovered.publish("ledger", data: source), 1)
        XCTAssertEqual(try recovered.publish("ledger", data: Data("next".utf8)), 2)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: source), "Persistent cache must contain no source plaintext")
        }
        server.offline = true
        XCTAssertThrowsError(try recovered.read("ledger"))
        XCTAssertEqual(try recovered.read("ledger", refresh: false).data, Data("next".utf8))
    }
    func testStaleOrMissingServerHeadCannotBeOverwrittenFromLocalSource() throws {
        let config = config(), server = Server(config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = SharedRecordVault(directory: directory, configuration: { config }, rpc: server.rpc)
        try vault.publish("ledger", data: Data("first".utf8))
        let id = config.records["ledger"]!
        server.heads[id]?["version"] = Int64(2)
        XCTAssertThrowsError(try vault.publish("ledger", data: Data("second".utf8)))
        XCTAssertEqual(server.operations.count, 1)
        server.heads.removeAll()
        XCTAssertThrowsError(try vault.publish("ledger", data: Data("third".utf8)))
    }
    func testSourceArchivePreservesOriginalRowsAndLedgerArithmetic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        let db = try DB(path: path, writable: true)
        try db.run("INSERT INTO snapshots(ts,app,account,balance,shot) VALUES('2026-09-09 10:00','KAKAO','synthetic',123456,'source-1')")
        let original = try Ledger.load(db: db, me: "Synthetic")
        let captured = try SharedLedgerArchive.capture(path: path, me: "Synthetic")
        let restored = try LifeJSON.decoder().decode(SharedLedgerArchive.self, from: LifeJSON.encoder().encode(captured)).ledger()
        XCTAssertEqual(restored.accounts, original.accounts)
        XCTAssertEqual(restored.series, original.series)
        XCTAssertEqual(restored.lines, original.lines)
        XCTAssertEqual(restored.defaultLens, original.defaultLens)
        let tables = try JSONSerialization.jsonObject(with: captured.originalTables) as! [String: Any]
        XCTAssertEqual(Set(tables.keys), ["snapshots", "transactions"])
        XCTAssertTrue(String(data: captured.originalTables, encoding: .utf8)!.contains("source-1"))
    }
}
