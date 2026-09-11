// Mac 의 구글 로그인: 나 › Google 계정으로 로그인. 세션은 키체인, 기기는 모든 요청의 X-Ppomi-Device.
// 이 Mac 에 옛 기기 계정(이메일·비밀번호, --configure-shared)이 있으면 첫 로그인 때 그 기기·작업 공간을 구글 사용자 것으로 넘긴다(ppomi_rebind_device).
// 기록 키는 서버에 평문으로 안 올린다: 기기마다 X25519 공개키를 등록하고, 키를 가진 이 Mac 이 기다리는 기기의 공개키로 감싼 사본만 올린다(exchangeKeys).
// 새 기기는 Google 로그인 + 구성원으로 바로 등록된다(MZZ-27). 장부 키만 이 Mac 이 기다리는 기기의 공개키로 자동 감싼다(exchangeKeys).
import AppKit
import AuthenticationServices

/// 예전 승인 대기 행(표시용 라벨·플랫폼만). 새 기기는 여기에 오지 않는다. 기기 ID 는 서버의 안정적인 참조이며 화면에는 이름을 쓴다.
struct PendingDevice: Identifiable, Equatable {
    let id: String
    let label: String
    let platform: String
    var platformName: String {
        switch platform {
        case "macos": return "Mac"
        case "ios": return "iPad"
        case "android": return "Android"
        case "windows": return "Windows"
        case "web": return "웹 브라우저"
        default: return platform
        }
    }
}

struct MacSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var registered: Bool
    var email: String
    var name: String?        // 구글 프로필 이름·사진(표시용). 없으면 이메일·이니셜
    var avatarURL: String?
}

@MainActor final class GoogleAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAccount()
    static let rpcNames: Set<String> = ["ppomi_rebind_device", "ppomi_register_device", "ppomi_devices_waiting", "ppomi_key_wrap_put", "ppomi_key_get",
                                        "ppomi_devices_pending", "ppomi_device_approve", "ppomi_device_revoke"]
    private static let service = "com.muilyzz.ppomi.google"
    private var web: ASWebAuthenticationSession?

    /// 저장된 세션. 테스트에서는 없음 — 키체인의 실제 세션이 테스트를 네트워크로 끌고 가지 않게.
    nonisolated static var session: MacSession? {
        if NSClassFromString("XCTestCase") != nil { return nil }   // 테스트 프로세스: 이 Mac 의 실제 세션을 쓰지 않는다
        // Passive bootstrap/status and HTTP requests must not open a Keychain authorization dialog.
        // Explicit sign-in/save remains interactive in the native account window.
        return SessionStore.load(MacSession.self, service: service, account: "session", interactionAllowed: false)
    }
    nonisolated static func save(_ s: MacSession) throws { try SessionStore.save(s, service: service, account: "session") }
    nonisolated static func clear() { SessionStore.delete(service: service, account: "session") }
    /// 이 Mac 의 기기 ID: 옛 기기 계정이 있으면 그 ID(작업 공간·기록이 붙어 있다), 없으면 새로 하나.
    nonisolated static var deviceID: String {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "googleDeviceID") { return v }
        let v = (try? SharedServerConfiguration.load())?.deviceId.lowercased() ?? UUID().uuidString.lowercased()
        d.set(v, forKey: "googleDeviceID"); return v
    }

    func signIn() async throws -> MacSession {
        let pkce = SupabaseAuth.PKCE()
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: SupabaseAuth.authorizeURL(pkce), callbackURLScheme: PpomiServer.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
            }
            s.presentationContextProvider = self
            web = s
            if !s.start() { cont.resume(throwing: URLError(.cannotConnectToHost)) }
        }
        guard let code = SupabaseAuth.code(from: callback) else { throw SharedServerError.invalidResponse }
        let tokens = try await Task.detached { try SupabaseAuth.exchange(code: code, verifier: pkce.verifier) }.value
        guard let sub = tokens.claims["sub"] as? String, UUID(uuidString: sub) != nil else { throw SharedServerError.authentication }
        let email = tokens.claims["email"] as? String ?? sub
        let meta = tokens.claims["user_metadata"] as? [String: Any] ?? [:]
        let name = (meta["full_name"] ?? meta["name"]) as? String, avatar = (meta["avatar_url"] ?? meta["picture"]) as? String
        let client = SharedServerClient.shared
        let legacy = (try? SharedServerConfiguration.load()) != nil
        let deviceID = Self.deviceID
        do {
            // 옛 기기 계정이 있으면 그 계정으로 한 번: 구글 사용자를 구성원으로, 이 기기를 구글 사용자 것으로.
            if legacy { _ = try await Task.detached { try client.rpc("ppomi_rebind_device", ["p_auth_user_id": sub], legacy: true) }.value }
            try Self.save(MacSession(accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt, registered: legacy, email: email, name: name, avatarURL: avatar))
            client.invalidate()   // 이제부터 구글 세션
            try await Task.detached {
                _ = try client.rpc("ppomi_register_device", ["p_device_id": deviceID, "p_label": "Mac", "p_platform": "macos", "p_public_key": try Self.publicKey()])
                try Self.exchangeKeys(client)
            }.value
        } catch { Self.clear(); client.invalidate(); throw error }
        let done = MacSession(accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt, registered: true, email: email, name: name, avatarURL: avatar)
        try Self.save(done); client.invalidate()
        return done
    }
    func signOut() { Self.clear(); SharedServerClient.shared.invalidate() }

    /// 이 Mac 의 X25519 공개키(등록 때 서버로). 비밀키는 이 Mac 키체인에만.
    nonisolated static func publicKey() throws -> String { try DeviceKey.publicKeyBase64(service: service) }

    /// 예전 승인 대기 행. 새 등록은 바로 구성원이라 보통 비어 있다.
    nonisolated static func pendingDevices(_ client: SharedServerClient = .shared) throws -> [PendingDevice] {
        guard let rows = try client.rpc("ppomi_devices_pending", [:]) as? [[String: Any]] else { throw SharedServerError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
                  let label = row["label"] as? String, !label.isEmpty, let platform = row["platform"] as? String else { return nil }
            return PendingDevice(id: id.lowercased(), label: label, platform: platform)
        }
    }
    /// 예전 대기 행을 승인으로 옮긴 뒤, 이 Mac 에 키가 있으면 바로 감싸 올린다.
    nonisolated static func approve(_ deviceID: String, _ client: SharedServerClient = .shared) throws {
        guard UUID(uuidString: deviceID) != nil else { throw SharedServerError.invalidArgument("기기") }
        _ = try client.rpc("ppomi_device_approve", ["p_device_id": deviceID])
        try exchangeKeys(client)
    }
    /// 거절·해지: 그 기기는 등록이 끊기고 감싼 사본도 지워진다. 다시 쓰려면 그 기기가 다시 로그인하면 된다.
    nonisolated static func revoke(_ deviceID: String, _ client: SharedServerClient = .shared) throws {
        guard UUID(uuidString: deviceID) != nil else { throw SharedServerError.invalidArgument("기기") }
        _ = try client.rpc("ppomi_device_revoke", ["p_device_id": deviceID])
    }

    /// 기록 키 주고받기. 이 Mac 에 키가 있으면 키 없는 구성원 기기의 공개키로 감싸 올리고, 없으면(새 Mac) 다른 기기가 감싸 준 것을 받는다. 서버엔 감싼 사본만.
    nonisolated static func exchangeKeys(_ client: SharedServerClient = .shared) throws {
        if let key = try? SharedRecordVault.loadKey() {
            guard let waiting = try client.rpc("ppomi_devices_waiting", [:]) as? [[String: Any]] else { return }
            for device in waiting {
                guard let id = device["id"] as? String, let text = device["public_key"] as? String,
                      let recipient = Data(base64Encoded: text), recipient.count == 32 else { continue }
                let wrapped = try KeyWrap.wrap(key.key, for: recipient, workspaceID: key.workspaceID, keyID: key.keyID)
                _ = try client.rpc("ppomi_key_wrap_put", ["p_device_id": id, "p_key_id": key.keyID, "p_records": key.records, "p_wrapped": wrapped.base64EncodedString()])
            }
            return
        }
        guard let reply = try client.rpc("ppomi_key_get", [:]) as? [String: Any], reply["found"] as? Bool == true,
              let workspaceID = reply["workspace_id"] as? String, let keyID = reply["key_id"] as? String,
              let records = reply["records"] as? [String: String], let text = reply["wrapped"] as? String, let blob = Data(base64Encoded: text) else { return }
        let key = try KeyWrap.unwrap(blob, with: DeviceKey.privateKey(service: service), workspaceID: workspaceID, keyID: keyID)
        try SharedRecordVault.storeKey(SharedRecordKey(workspaceID: workspaceID, deviceID: deviceID, keyID: keyID, key: key, records: records, sourcePath: ""))
        UserDefaults.standard.set(true, forKey: "sharedRecordsEnabled.v1")
    }

    private var sharing: Timer?
    /// 앱이 켜져 있는 동안 로그인돼 있으면 1분마다 키를 주고받는다 — 새 기기는 이 Mac 이 켜져 있을 때 받는다. 처음 한 번은 이 Mac 의 공개키도 등록한다.
    func startSharing() {
        guard sharing == nil else { return }
        let deviceID = Self.deviceID
        Task.detached {
            guard Self.session != nil else { return }
            _ = try? SharedServerClient.shared.rpc("ppomi_register_device", ["p_device_id": deviceID, "p_label": "Mac", "p_platform": "macos", "p_public_key": try Self.publicKey()])
            try? Self.exchangeKeys()
        }
        sharing = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task.detached { guard Self.session != nil else { return }; try? Self.exchangeKeys() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
