// Mac 이 Supabase 에 올린 암호화 기록(ledger·evidence·accounting)을 이 기기가 직접 읽는다.
// 기록 키는 서버에 평문으로 없다: 이 기기의 X25519 공개키를 등록해 두면 Mac 이 그 공개키로 감싼 사본을 올리고(ppomi_key_get), 여기서 비밀키로 푼다. 쓰기 없음.
import Foundation

enum PadVault {
    static var key: SharedRecordKey? { Keychain.load(SharedRecordKey.self, account: "vault") }
    private static let service = "com.muilyzz.ppomi.pad"

    /// 로그인 뒤: 이 기기를 공개키와 함께 등록하고(초대 없음 — 구글 계정이 곧 구성원), Mac 이 감싸 준 키가 있으면 받아 둔다.
    static func enroll() throws {
        let reply = try PadServerClient.shared.rpc("ppomi_register_device",
                                                   ["p_device_id": PadSettings.deviceID, "p_label": PadSettings.deviceLabel, "p_platform": "ios",
                                                    "p_public_key": try DeviceKey.publicKeyBase64(service: service)])
        guard let workspace = (reply as? [String: Any])?["workspace"] as? [String: Any], let id = workspace["id"] as? String, UUID(uuidString: id) != nil
        else { throw SharedRecordError.invalid }
        guard var session = Session.load() else { throw PadServerClient.Failure.unconfigured }
        session.registered = true; try session.save()
        _ = try? fetchKey()
    }

    /// Mac 이 이 기기의 공개키로 감싸 올린 기록 키. 아직 없으면 nil(Mac 이 켜지면 몇 초 안에 올린다).
    @discardableResult static func fetchKey() throws -> SharedRecordKey? {
        guard let reply = try PadServerClient.shared.rpc("ppomi_key_get", [:]) as? [String: Any] else { throw SharedRecordError.invalid }
        guard reply["found"] as? Bool == true else { return nil }
        guard let workspaceID = reply["workspace_id"] as? String, UUID(uuidString: workspaceID) != nil,
              let keyID = reply["key_id"] as? String, UUID(uuidString: keyID) != nil,
              let text = reply["wrapped"] as? String, let blob = Data(base64Encoded: text),
              let records = reply["records"] as? [String: String], !records.isEmpty else { throw SharedRecordError.invalid }
        let key = try KeyWrap.unwrap(blob, with: DeviceKey.privateKey(service: service), workspaceID: workspaceID, keyID: keyID)
        let value = SharedRecordKey(workspaceID: workspaceID, deviceID: PadSettings.deviceID, keyID: keyID, key: key, records: records, sourcePath: "")
        try Keychain.save(value, account: "vault")
        return value
    }

    /// 기록 하나(ledger·evidence·accounting)의 현재 버전을 내려받아 연다. 등록이 안 됐거나(옛 세션) 자리가 옮겨졌으면(Mac 이 나중에 연결) 한 번 다시 등록하고 재시도.
    static func read(_ name: String) throws -> Data {
        if Session.load()?.registered != true { try enroll() }
        do { return try readOnce(name) }
        catch PadServerClient.Failure.permission { try enroll(); return try readOnce(name) }
    }
    private static func readOnce(_ name: String) throws -> Data {
        var found = try self.key ?? fetchKey()
        if found == nil { try enroll(); found = try fetchKey() }   // 구성원 자리가 바뀌었을 수 있다
        guard var key = found, let id = key.records[name] else { throw SharedRecordError.key }
        guard let head = try PadServerClient.shared.rpc("ppomi_record_get", ["p_record_id": id]) as? [String: Any], head["found"] as? Bool == true,
              let headKey = head["key_id"] as? String, let version = (head["version"] as? NSNumber)?.int64Value, version > 0,
              let chunkIDs = head["chunk_ids"] as? [String], (1...1024).contains(chunkIDs.count) else { throw SharedRecordError.unavailable }
        if headKey != key.keyID { guard let fresh = try fetchKey(), fresh.keyID == headKey else { throw SharedRecordError.invalid }; key = fresh }
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
    /// 분개: 서버의 accounting 기록(AccountingArchive JSON)을 journal.html 의 자리에. 기록은 슬래시를 안 이스케이프한 JSON 이라 다시 직렬화해(</ 가 못 생기게) 넣는다.
    static func journalHTML() throws -> String {
        let archive = try JSONSerialization.jsonObject(with: read("accounting"))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys]), as: UTF8.self)
        return PadFiles.page("journal").replacingOccurrences(of: "/*ARCHIVE*/null", with: json)
    }
}
