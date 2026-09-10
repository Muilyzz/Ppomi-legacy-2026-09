// 구글 로그인 = Supabase Auth 의 OAuth(PKCE). 시스템 로그인 창(ASWebAuthenticationSession)이 열리고, 돌아온 code 를 토큰으로 바꾼다. 비밀번호는 없다.
import AuthenticationServices
import CryptoKit
import UIKit

@MainActor final class PadAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PadAuth()
    private var authSession: ASWebAuthenticationSession?

    func signInWithGoogle() async throws {
        let verifier = Self.base64url(Self.random(32))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: PadSettings.supabaseURL + "/auth/v1/authorize")!
        c.queryItems = [.init(name: "provider", value: "google"), .init(name: "redirect_to", value: PadSettings.callbackScheme + "://auth"),
                        .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "s256")]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: PadSettings.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
            }
            s.presentationContextProvider = self
            authSession = s
            if !s.start() { cont.resume(throwing: URLError(.cannotConnectToHost)) }
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value ?? ""
        guard !code.isEmpty else { throw URLError(.badServerResponse) }
        var login = try await Task.detached { try PadServerClient.exchange(code: code, verifier: verifier) }.value
        try login.save()
        // 이미 등록된 기기(재설치·재로그인)면 바로 쓴다. 아니면 Mac 의 QR 이 다음 차례.
        login.registered = await Task.detached { (try? PadServerClient.shared.rpc("ppomi_context", [:])) != nil }.value
        try login.save()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
    private static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
