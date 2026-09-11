import Foundation
import CryptoKit
import Security


/// The server owns committed revisions. Local files contain ciphertext and public
/// metadata only. A source adapter may publish, but readers never publish on read.
final class SharedRecordVault {
    static let names = ["ledger", "evidence", "accounting", "spatial", "health", "playbooks"]
    static let rpcNames: Set<String> = ["ppomi_record_get", "ppomi_record_put", "ppomi_record_blob_get", "ppomi_record_blob_put"]
    static let shared = SharedRecordVault()
    static var enabled: Bool {
        if CommandLine.arguments.first?.contains(".xctest") == true { return false }
        return UserDefaults.standard.bool(forKey: "sharedRecordsEnabled.v1")
    }
    typealias Configuration = SharedRecordKey
    struct Head: Codable, Equatable {
        var record_id: String
        var workspace_id: String
        var writer_device_id: String
        var key_id: String
        var version: Int64
        var chunk_ids: [String]
        var updated_at: String
    }
    struct Cached: Codable {
        var head: Head
        var sourceDigest: String?
        var confirmedAt: Date
    }
    struct Pending: Codable {
        var operationID: String
        var expectedVersion: Int64
        var head: Head
        var sourceDigest: String
    }
    typealias RPC = (String, [String: Any]) throws -> Any
    private let lock = NSRecursiveLock()
    private let rpc: RPC
    private let loadConfiguration: () throws -> Configuration
    private let directory: URL
    private var memory: [String: (Head, Data)] = [:]
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Ppomi/Private/shared-records", isDirectory: true)

    init(directory: URL = defaultDirectory,
         configuration: @escaping () throws -> Configuration = SharedRecordVault.loadKey,
         rpc: @escaping RPC = { try SharedServerClient.shared.rpc($0, $1) }) {
        self.directory = directory; self.loadConfiguration = configuration; self.rpc = rpc
    }
    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // App and CLI may coexist. One private process-shared lock serializes the outbox.
        let fd = Darwin.open(directory.appendingPathComponent("access.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SharedRecordError.unavailable }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SharedRecordError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func verify(_ config: Configuration) throws {
        guard config.key.count == 32, let value = try rpc("ppomi_context", [:]) as? [String: Any],
              let workspace = value["workspace"] as? [String: Any], workspace["id"] as? String == config.workspaceID,
              let device = value["device"] as? [String: Any], device["id"] as? String == config.deviceID else { throw SharedRecordError.key }
    }
    func read(_ name: String, refresh: Bool = true) throws -> (data: Data, version: Int64, confirmedAt: Date) {
        try exclusive {
            let config = try loadConfiguration(), id = try recordID(name, config)
            var cached = try readCache(id)
            if refresh {
                try verify(config)
                guard let head = try remoteHead(id) else { throw SharedRecordError.unavailable }
                try validate(head, id: id, config: config)
                if let cached, head.version < cached.head.version { throw SharedRecordError.invalid }
                let data = try plaintext(head, config: config, network: true)
                let next = Cached(head: head, sourceDigest: cached?.head == head ? cached?.sourceDigest : nil, confirmedAt: Date())
                try writeMetadata(next, id + ".json")
                cached = next
                return (data, head.version, next.confirmedAt)
            }
            guard let cached else { throw SharedRecordError.unavailable }
            try validate(cached.head, id: id, config: config)
            return (try plaintext(cached.head, config: config, network: false), cached.head.version, cached.confirmedAt)
        }
    }
    /// An uncertain publication retains the exact ciphertext, operation UUID and
    /// expected version. Retrying transmits data only, never device actions.
    @discardableResult func publish(_ name: String, data: Data) throws -> Int64 {
        try exclusive {
            let config = try loadConfiguration(), id = try recordID(name, config)
            try verify(config)
            if let pending: Pending = try readMetadata(id + ".pending") {
                try commit(pending, config: config)
            }
            let previous = try readCache(id), head = try remoteHead(id)
            if let previous, head?.version != previous.head.version { throw SharedRecordError.conflict }
            if let head { try validate(head, id: id, config: config) }
            let digest = Self.digest(data, key: config.key)
            if let previous, previous.sourceDigest == digest { return previous.head.version }
            // Existing remote data cannot be initialized or replaced without its confirmed base.
            if head != nil && previous == nil { throw SharedRecordError.conflict }
            guard (head?.version ?? 0) < Int64.max else { throw SharedRecordError.invalid }
            let version = (head?.version ?? 0) + 1
            let chunks = try SharedRecordCrypto.seal(data, configuration: config, recordID: id, version: version)
            let hashes = chunks.map(SharedRecordCrypto.hash)
            for (hash, bytes) in zip(hashes, chunks) { try writeBytes(bytes, hash + ".blob") }
            let pending = Pending(operationID: UUID().uuidString.lowercased(), expectedVersion: version - 1,
                head: Head(record_id: id, workspace_id: config.workspaceID, writer_device_id: config.deviceID,
                    key_id: config.keyID, version: version, chunk_ids: hashes, updated_at: ""), sourceDigest: digest)
            try writeMetadata(pending, id + ".pending")
            try commit(pending, config: config)
            return version
        }
    }
    private func commit(_ pending: Pending, config: Configuration) throws {
        for hash in pending.head.chunk_ids {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(hash + ".blob"))
            guard SharedRecordCrypto.hash(bytes) == hash else { throw SharedRecordError.invalid }
            _ = try rpc("ppomi_record_blob_put", ["p_hash": hash, "p_data": bytes.base64EncodedString()])
        }
        _ = try rpc("ppomi_record_put", ["p_record_id": pending.head.record_id, "p_expected_version": pending.expectedVersion,
             "p_operation_id": pending.operationID, "p_key_id": pending.head.key_id, "p_chunk_ids": pending.head.chunk_ids])
        // Always GET and decrypt server-selected chunks before presenting a committed value.
        guard let current = try remoteHead(pending.head.record_id), current.version == pending.head.version,
              current.chunk_ids == pending.head.chunk_ids else { throw SharedRecordError.conflict }
        try validate(current, id: current.record_id, config: config)
        memory.removeValue(forKey: current.record_id)
        let verified = try plaintext(current, config: config, network: true, forceDownload: true)
        guard Self.digest(verified, key: config.key) == pending.sourceDigest else { throw SharedRecordError.invalid }
        try writeMetadata(Cached(head: current, sourceDigest: pending.sourceDigest, confirmedAt: Date()), current.record_id + ".json")
        try FileManager.default.removeItem(at: directory.appendingPathComponent(current.record_id + ".pending"))
    }
    private func remoteHead(_ id: String) throws -> Head? {
        guard let value = try rpc("ppomi_record_get", ["p_record_id": id]) as? [String: Any] else { throw SharedRecordError.invalid }
        guard value["found"] as? Bool == true else { return nil }
        return try JSONDecoder().decode(Head.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func validate(_ head: Head, id: String, config: Configuration) throws {
        guard head.record_id == id, head.workspace_id == config.workspaceID, head.writer_device_id == config.deviceID,
              head.key_id == config.keyID, head.version > 0, (1...1024).contains(head.chunk_ids.count),
              head.chunk_ids.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw SharedRecordError.invalid }
    }
    private func plaintext(_ head: Head, config: Configuration, network: Bool, forceDownload: Bool = false) throws -> Data {
        if !forceDownload, let cached = memory[head.record_id], cached.0 == head { return cached.1 }
        var chunks: [Data] = []
        for hash in head.chunk_ids {
            let path = directory.appendingPathComponent(hash + ".blob")
            var bytes = !forceDownload ? try? Data(contentsOf: path) : nil
            if bytes.map(SharedRecordCrypto.hash) != hash {
                guard network, let blob = try rpc("ppomi_record_blob_get", ["p_hash": hash]) as? [String: Any],
                      blob["hash"] as? String == hash, let encoded = blob["data"] as? String,
                      let downloaded = Data(base64Encoded: encoded), SharedRecordCrypto.hash(downloaded) == hash else { throw SharedRecordError.invalid }
                bytes = downloaded
                try writeBytes(downloaded, hash + ".blob")
            }
            guard let bytes, bytes.count <= 409600 else { throw SharedRecordError.invalid }
            chunks.append(bytes)
        }
        let data = try SharedRecordCrypto.open(chunks, configuration: config, recordID: head.record_id, version: head.version)
        memory[head.record_id] = (head, data)
        return data
    }
    private static func digest(_ data: Data, key: Data) -> String { HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined() }
    private func recordID(_ name: String, _ config: Configuration) throws -> String {
        guard let id = config.records[name], UUID(uuidString: id) != nil else { throw SharedRecordError.invalid }
        return id
    }
    private func readCache(_ id: String) throws -> Cached? { try readMetadata(id + ".json") }
    private func readMetadata<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    private func writeMetadata<T: Encodable>(_ value: T, _ name: String) throws { try writeBytes(JSONEncoder().encode(value), name) }
    private func writeBytes(_ data: Data, _ name: String) throws {
        let url = directory.appendingPathComponent(name)
        // Class C, not A: the vault is written by background work while the Mac may be locked; class A (complete) refuses
        // to create files whenever the keybag is locked (EPERM from mktemp). The blob is ciphertext with 0600 permissions.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func prepareKey() throws -> Configuration {
        if let existing = try keyData() { return try JSONDecoder().decode(Configuration.self, from: existing) }
        guard let context = try SharedServerClient.shared.rpc("ppomi_context", [:]) as? [String: Any],
              let workspace = context["workspace"] as? [String: Any], let workspaceID = workspace["id"] as? String,
              let device = context["device"] as? [String: Any], let deviceID = device["id"] as? String else { throw SharedRecordError.key }
        let config = Configuration(workspaceID: workspaceID, deviceID: deviceID, keyID: UUID().uuidString.lowercased(),
            key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            records: Dictionary(uniqueKeysWithValues: names.map { ($0, UUID().uuidString.lowercased()) }),
            sourcePath: URL(fileURLWithPath: AppSettings.dbPath).standardizedFileURL.path)
        var query = keyQuery
        query[kSecValueData as String] = try JSONEncoder().encode(config)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SharedRecordError.key }
        return config
    }
    /// 다른 기기가 감싸 준 키를 이 Mac 의 것으로 둔다(새 Mac). 있으면 덮어쓴다.
    static func storeKey(_ config: Configuration) throws {
        var query = keyQuery
        let updates = [kSecValueData as String: try JSONEncoder().encode(config), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            updates.forEach { query[$0] = $1 }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SharedRecordError.key }
        } else if status != errSecSuccess { throw SharedRecordError.key }
    }
    static func loadKey() throws -> Configuration {
        guard let data = try keyData() else { throw SharedRecordError.key }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ppomi.records.vault.v1",
         kSecAttrAccount as String: NSUserName(), kSecAttrSynchronizable as String: false]
    }
    private static func keyData() throws -> Data? {
        var query = keyQuery; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SharedRecordError.key }
        return data
    }
}
