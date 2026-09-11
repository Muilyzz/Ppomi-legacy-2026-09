// Supabase Auth 구글 로그인(PKCE)의 공통부: 로그인 주소, 코드 → 토큰, 토큰 갱신, 세션 키체인. Mac(GoogleAccount)과 아이패드(PadAuth)가 같이 쓴다.
// 로그인 창(ASWebAuthenticationSession)은 각자 띄운다. Foundation·CryptoKit·Security 뿐이라 두 타깃에 그대로 들어간다.
import CryptoKit
import Foundation
import Security

/// 뽀미의 공개 서버 주소. 비밀 아님 — 접근 제한은 서버 RLS 와 로그인 몫.
enum PpomiServer {
    static let supabaseURL = "https://nafutfqfbbmknzmyspus.supabase.co"
    static let publishableKey = "sb_publishable_diyhnKb7L4C1R5wt9FRoEQ_rQs8b4WX"
    static let agentEndpoint = "https://ppomi-agent.vercel.app"
    static let callbackScheme = "ppomi"          // 뽀미 앱 공통 로그인 콜백 ppomi://auth
    static let callback = "ppomi://auth"
}

enum SupabaseAuth {
    enum Failure: Error { case authentication, connection }
    struct Tokens { let access: String; let refresh: String; let expiresAt: Date; let claims: [String: Any] }
    struct PKCE {
        let verifier: String, challenge: String
        init() {
            verifier = SupabaseAuth.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            challenge = SupabaseAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }
    static func authorizeURL(_ pkce: PKCE) -> URL {
        var c = URLComponents(string: PpomiServer.supabaseURL)!; c.path = "/auth/v1/authorize"
        c.queryItems = [.init(name: "provider", value: "google"), .init(name: "redirect_to", value: PpomiServer.callback),
                        .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: "s256")]
        return c.url!
    }
    static func code(from callback: URL) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value ?? ""
        return code.isEmpty ? nil : code
    }
    static func exchange(code: String, verifier: String) throws -> Tokens { try token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier]) }
    static func refresh(_ refreshToken: String) throws -> Tokens { try token(grant: "refresh_token", body: ["refresh_token": refreshToken]) }

    private static func token(grant: String, body: [String: Any]) throws -> Tokens {
        var c = URLComponents(string: PpomiServer.supabaseURL)!; c.path = "/auth/v1/token"; c.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var r = URLRequest(url: c.url!); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(PpomiServer.publishableKey, forHTTPHeaderField: "apikey")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try send(r)
        guard status == 200, data.count <= 65_536, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, (16...16_384).contains(access.count), !access.contains(where: { $0.isWhitespace }),
              let refresh = o["refresh_token"] as? String, !refresh.isEmpty,
              let ttl = o["expires_in"] as? NSNumber, ttl.doubleValue > 0 else { throw Failure.authentication }
        return Tokens(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(min(ttl.doubleValue, 86_400)), claims: claims(access))
    }
    /// JWT 본문(검증 없이 읽기만: sub·email 표시용. 서버가 검증한다).
    static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: "."); guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }
    private static func send(_ request: URLRequest) throws -> (Data, Int) {
        let settings = URLSessionConfiguration.ephemeral; settings.timeoutIntervalForRequest = 20; settings.httpShouldSetCookies = false; settings.urlCache = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var result: (Data, Int)?; let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if let data, let status = (response as? HTTPURLResponse)?.statusCode { result = (data, status) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 21) == .success, let result else { throw Failure.connection }
        return result
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// 키체인 항목 하나 = Codable 값 하나(로그인 세션·기록 키). 이 기기에서만, 잠금 해제 때만.
enum SessionStore {
    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save<T: Encodable>(_ value: T, service: String, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let updates = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query(service, account) as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(service, account); updates.forEach { q[$0] = $1 }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw SupabaseAuth.Failure.connection }
        } else if status != errSecSuccess { throw SupabaseAuth.Failure.connection }
    }
    static func load<T: Decodable>(_ type: T.Type, service: String, account: String, interactionAllowed: Bool = true) -> T? {
        var q = query(service, account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactionAllowed { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func delete(service: String, account: String) { SecItemDelete(query(service, account) as CFDictionary) }
}
