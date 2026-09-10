// Mac 이 Supabase 에 올린 암호화 기록(ledger·evidence)을 이 기기가 직접 읽는다. 키와 기록 ID(SharedRecordKey)는 Mac 의 QR 로 받아 키체인에만 둔다. 쓰기 없음.
import Foundation

enum PadVault {
    /// Mac 설정 › 아이패드 › 연결 QR 의 내용: 일회용 초대 + 기록 키.
    struct Pairing: Codable { let invite: String; let workspaceID: String; let keyID: String; let key: Data; let records: [String: String] }

    static var key: SharedRecordKey? { Keychain.load(SharedRecordKey.self, account: "vault") }

    /// 초대로 이 기기를 Mac 의 작업 공간에 등록하고 기록 키를 보관한다.
    static func pair(_ text: String) throws {
        let p = try JSONDecoder().decode(Pairing.self, from: Data(text.utf8))
        guard p.key.count == 32, UUID(uuidString: p.workspaceID) != nil, UUID(uuidString: p.keyID) != nil, !p.records.isEmpty else { throw SharedRecordError.invalid }
        let reply = try PadServerClient.shared.rpc("ppomi_register_device",
                                                   ["p_invite": p.invite, "p_device_id": PadSettings.deviceID, "p_label": PadSettings.deviceLabel, "p_platform": "ios"])
        guard let workspace = (reply as? [String: Any])?["workspace"] as? [String: Any],
              (workspace["id"] as? String)?.lowercased() == p.workspaceID.lowercased() else { throw SharedRecordError.invalid }
        try Keychain.save(SharedRecordKey(workspaceID: p.workspaceID, deviceID: PadSettings.deviceID, keyID: p.keyID, key: p.key, records: p.records, sourcePath: ""),
                          account: "vault")
        guard var session = Session.load() else { throw PadServerClient.Failure.unconfigured }
        session.registered = true; try session.save()
    }

    /// 기록 하나(ledger·evidence)의 현재 버전을 내려받아 연다. Mac SharedRecordVault.read 와 같은 검증: 키 ID · 조각 해시 · AAD.
    static func read(_ name: String) throws -> Data {
        guard let key, let id = key.records[name] else { throw SharedRecordError.key }
        guard let head = try PadServerClient.shared.rpc("ppomi_record_get", ["p_record_id": id]) as? [String: Any], head["found"] as? Bool == true,
              head["key_id"] as? String == key.keyID, let version = (head["version"] as? NSNumber)?.int64Value, version > 0,
              let chunkIDs = head["chunk_ids"] as? [String], (1...1024).contains(chunkIDs.count) else { throw SharedRecordError.unavailable }
        var chunks: [Data] = []
        for hash in chunkIDs {
            guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let blob = try PadServerClient.shared.rpc("ppomi_record_blob_get", ["p_hash": hash]) as? [String: Any],
                  let text = blob["data"] as? String, let bytes = Data(base64Encoded: text), SharedRecordCrypto.hash(bytes) == hash else { throw SharedRecordError.invalid }
            chunks.append(bytes)
        }
        return try SharedRecordCrypto.open(chunks, configuration: key, recordID: id, version: version)
    }
    static func timelineHTML() throws -> String {
        let archive = try LifeJSON.decoder().decode(SharedLedgerArchive.self, from: read("ledger"))
        return LedgerPage.timelineHTML(template: PadFiles.page("timeline"), ledger: try archive.ledger())
    }
    static func evidenceHTML() throws -> String { String(decoding: try read("evidence"), as: UTF8.self) }
}
