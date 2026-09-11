import Foundation
import Security

/// Device credentials are provisioned explicitly. Existing ledgers and local records are never imported here.
struct SharedServerConfiguration: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: String
    let publishableKey: String
    let email: String
    let password: String
    let deviceId: String

    var description: String { "SharedServerConfiguration(credentials: redacted)" }
    var debugDescription: String { description }

    func validate() throws {
        guard let endpoint = URLComponents(string: url), endpoint.scheme == "https",
              let host = endpoint.host, host.range(of: #"^[a-z0-9]{1,63}\.supabase\.co$"#, options: .regularExpression) != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.port == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/" else { throw SharedServerError.configuration }
        guard Self.isPublicKey(publishableKey), email.count <= 254, email.contains("@"),
              !email.contains(where: { $0.isWhitespace || $0.isNewline }),
              (12...256).contains(password.count), UUID(uuidString: deviceId) != nil else { throw SharedServerError.configuration }
    }

    static func isPublicKey(_ value: String) -> Bool {
        if value.range(of: #"^sb_publishable_[A-Za-z0-9_-]{16,256}$"#, options: .regularExpression) != nil { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, value.count <= 4096 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["role"] as? String == "anon"
    }

    var safeStatus: [String: Any] {
        ["configured": true, "host": URL(string: url)?.host ?? "", "deviceId": deviceId,
         "authority": "server", "localDataImported": SharedRecordVault.enabled,
         "recordsEncrypted": SharedRecordVault.enabled]
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw SharedServerError.configuration
        }
        try value.validate()
        return value
    }

    /// CLI input is a private file, not command-line credentials. Only this dedicated keychain item is changed.
    static func install(from file: URL) throws {
        guard file.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: file) else { throw SharedServerError.privateFile }
        let config = try decode(data)
        let encoded = try JSONEncoder().encode(config)
        let updates = [kSecValueData as String: encoded,
                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(keychainQuery as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            updates.forEach { query[$0] = $1 }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SharedServerError.keychain }
        } else if status != errSecSuccess { throw SharedServerError.keychain }
    }

    static func load() throws -> Self? {
        try load(interactionAllowed: true)
    }

    static func load(interactionAllowed: Bool) throws -> Self? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactionAllowed { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SharedServerError.keychain }
        return try decode(data)
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ppomi.shared-server.device.v1",
         kSecAttrAccount as String: NSUserName(), kSecAttrSynchronizable as String: false]
    }
}

enum SharedServerError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case configuration, privateFile, keychain, unconfigured, authentication, connection, invalidResponse, deviceMismatch
    case conflict, permission, server(Int), invalidArgument(String), notFound

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .configuration: return "공유 서버 설정이 올바르지 않습니다. HTTPS Supabase 주소·공개 키·기기 인증 정보가 필요합니다."
        case .privateFile: return "공유 서버 설정 파일은 현재 사용자만 읽을 수 있는 일반 파일이어야 합니다 (권한 600)."
        case .keychain: return "공유 서버의 기기 인증 정보를 키체인에서 처리하지 못했습니다."
        case .unconfigured: return "공유 서버가 아직 설정되지 않았습니다."
        case .authentication: return "공유 서버의 기기 인증에 실패했습니다. 기기 등록 상태를 확인해 주세요."
        case .connection: return "공유 서버 응답을 확인하지 못했습니다. 쓰기 요청은 같은 작업·변경 ID로 결과를 확인하세요."
        case .invalidResponse: return "공유 서버 응답 형식이 올바르지 않습니다."
        case .deviceMismatch: return "공유 서버의 인증된 기기와 이 Mac의 기기 ID가 다릅니다."
        case .conflict: return "공유 서버 버전 또는 변경 ID 충돌입니다. 최신 내용을 읽고 변경을 검토하세요. 자동 덮어쓰기는 하지 않았습니다."
        case .permission: return "이 기기는 요청한 공유 데이터에 접근할 권한이 없습니다."
        case .server(let code): return "공유 서버가 요청을 처리하지 못했습니다 (HTTP \(code))."
        case .invalidArgument(let key): return "공유 요청의 \(key) 값이 올바르지 않습니다."
        case .notFound: return "해당 공유 기록을 찾지 못했습니다."
        }
    }
}
