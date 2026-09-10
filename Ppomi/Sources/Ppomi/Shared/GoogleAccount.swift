// Mac 의 구글 로그인: 아이패드와 같은 흐름(설정 › 계정 › Google 계정으로 로그인). 세션은 키체인, 기기는 모든 요청의 X-Ppomi-Device.
// 이 Mac 에 옛 기기 계정(이메일·비밀번호, --configure-shared)이 있으면 첫 로그인 때 그 기기·작업 공간을 구글 사용자 것으로 넘기고(ppomi_rebind_device)
// 기록 키를 작업 공간에 올린다 — 장부는 그대로, 아이패드가 같은 것을 본다. 없으면 새 기기로 등록한다(ppomi_register_device).
import AppKit
import AuthenticationServices

struct MacSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var registered: Bool
    var email: String
}

@MainActor final class GoogleAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAccount()
    static let rpcNames: Set<String> = ["ppomi_rebind_device", "ppomi_register_device", "ppomi_key_put"]
    private static let service = "com.muilyzz.ppomi.google"
    private var web: ASWebAuthenticationSession?

    /// 저장된 세션. 테스트에서는 없음 — 키체인의 실제 세션이 테스트를 네트워크로 끌고 가지 않게.
    nonisolated static var session: MacSession? {
        if NSClassFromString("XCTestCase") != nil { return nil }   // 테스트 프로세스: 이 Mac 의 실제 세션을 쓰지 않는다
        return SessionStore.load(MacSession.self, service: service, account: "session")
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
        let client = SharedServerClient.shared
        let legacy = (try? SharedServerConfiguration.load()) != nil
        let deviceID = Self.deviceID
        do {
            // 옛 기기 계정이 있으면 그 계정으로 한 번: 구글 사용자를 구성원으로, 이 기기를 구글 사용자 것으로.
            if legacy { _ = try await Task.detached { try client.rpc("ppomi_rebind_device", ["p_auth_user_id": sub], legacy: true) }.value }
            try Self.save(MacSession(accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt, registered: legacy, email: email))
            client.invalidate()   // 이제부터 구글 세션
            try await Task.detached {
                if !legacy { _ = try client.rpc("ppomi_register_device", ["p_device_id": deviceID, "p_label": "Mac", "p_platform": "macos"]) }
                if let key = try? SharedRecordVault.loadKey() {   // 아이패드 등이 같은 기록을 읽도록 작업 공간에
                    _ = try client.rpc("ppomi_key_put", ["p_key_id": key.keyID, "p_key": key.key.base64EncodedString(), "p_records": key.records])
                }
            }.value
        } catch { Self.clear(); client.invalidate(); throw error }
        let done = MacSession(accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt, registered: true, email: email)
        try Self.save(done); client.invalidate()
        return done
    }
    func signOut() { Self.clear(); SharedServerClient.shared.invalidate() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
