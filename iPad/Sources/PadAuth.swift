// 구글 로그인 = Supabase Auth 의 OAuth(PKCE). 시스템 로그인 창(ASWebAuthenticationSession)이 열리고, 돌아온 code 를 토큰으로 바꾼다. 비밀번호는 없다.
import AuthenticationServices
import UIKit

@MainActor final class PadAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PadAuth()
    private var authSession: ASWebAuthenticationSession?

    func signInWithGoogle() async throws {
        let pkce = SupabaseAuth.PKCE()
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: SupabaseAuth.authorizeURL(pkce), callbackURLScheme: PadSettings.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
            }
            s.presentationContextProvider = self
            authSession = s
            if !s.start() { cont.resume(throwing: URLError(.cannotConnectToHost)) }
        }
        guard let code = SupabaseAuth.code(from: callback) else { throw URLError(.badServerResponse) }
        let tokens = try await Task.detached { try SupabaseAuth.exchange(code: code, verifier: pkce.verifier) }.value
        let login = Session(accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt, registered: false)
        try login.save()
        // 기기 등록 + 작업 공간의 기록 키(Mac 이 "구글 계정 연결"을 눌렀으면 있다). 초대·QR 없음.
        try await Task.detached { try PadVault.enroll() }.value
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
