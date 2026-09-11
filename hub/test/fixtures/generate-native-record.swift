// TEST DATA ONLY. Compiled with the actual SharedRecordCrypto.swift. Never reads
// Keychain, application settings, a database, or any user's records.
import Foundation
import CryptoKit

// The shared source also declares DeviceKey; its Keychain dependency is unused.
enum SessionStore {
    static func load<T: Decodable>(_ type: T.Type, service: String, account: String) -> T? { nil }
    static func save<T: Encodable>(_ value: T, service: String, account: String) throws { fatalError("Fixture must not access Keychain") }
}

@main struct Fixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "fixture-path-required", code: 1) }
        let rawPrivate = Data((0..<32).map(UInt8.init))
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivate)
        let config = SharedRecordKey(workspaceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", deviceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            keyID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", key: Data((32..<64).map(UInt8.init)),
            records: ["accounting": "dddddddd-dddd-4ddd-8ddd-dddddddddddd"], sourcePath: "")
        let version: Int64 = 9223372036854775807
        let source = "{\"formatVersion\":1,\"amount\":9223372036854775807,\"negative\":-9223372036854775808,\"note\":\"" + String(repeating: "가상 테스트 기록 · ", count: 2000) + "\"}"
        let bytes = Data(source.utf8)
        let chunks = try SharedRecordCrypto.seal(bytes, configuration: config, recordID: config.records["accounting"]!, version: version)
        let wrapped = try KeyWrap.wrap(config.key, for: recipient.publicKey.rawRepresentation, workspaceID: config.workspaceID, keyID: config.keyID)
        let fixture: [String: Any] = [
            "testOnly": true, "userID": "11111111-1111-4111-8111-111111111111", "deviceID": config.deviceID,
            "workspaceID": config.workspaceID, "keyID": config.keyID, "recordID": config.records["accounting"]!,
            "version": String(version), "privateKey": rawPrivate.base64EncodedString(),
            "publicKey": recipient.publicKey.rawRepresentation.base64EncodedString(), "wrapped": wrapped.base64EncodedString(),
            "chunks": chunks.map { ["hash": SharedRecordCrypto.hash($0), "data": $0.base64EncodedString(), "size": $0.count] },
            "plainSHA256": SharedRecordCrypto.hash(bytes), "plainBytes": bytes.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Synthetic native fixture generated (no user data)")
    }
}
