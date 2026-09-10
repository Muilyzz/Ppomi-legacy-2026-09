// 아이패드의 네이티브 다리. Mac AgentVoicePanel 의 메서드 중 서버 대화에 필요한 것만: bootstrap · sessionState · heard · declineCall · setEndpoint · request · executeTool(device_status).
// 도구는 없다(아이패드는 아무것도 조종하지 않는다). 신뢰하는 문서는 번들 pad.html 하나.
import Foundation
import WebKit

final class PadBridge: NSObject, WKScriptMessageHandler, WKUIDelegate {
    static let entry = URL(string: "ppomipad://app/pad.html")!
    weak var webView: WKWebView?
    var generation = 0
    private var active = false
    private let queue = DispatchQueue(label: "ppomi.pad.bridge")

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ppomiAgent", message.frameInfo.isMainFrame, message.frameInfo.request.url == Self.entry,
              let body = message.body as? String, body.utf8.count <= 1536 * 1024,
              let request = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let id = request["id"] as? String, UUID(uuidString: id) != nil,
              let method = request["method"] as? String, let args = request["args"] as? [String: Any] else { return }
        switch method {
        case "sessionState": active = args["active"] as? Bool ?? false; reply(id, result: ["active": active]); return
        case "heard": reply(id, result: ["heard": true]); return
        case "declineCall": reply(id, result: ["declined": true]); return
        case "setEndpoint": reply(id, result: ["endpoint": PadSettings.agentEndpoint]); return   // 주소는 고정
        default: break
        }
        let isActive = active
        queue.async { [weak self] in
            guard let self else { return }
            let outcome: Result<Any, Error> = Result {
                switch method {
                case "bootstrap":
                    return ["platform": "macos", "deviceLabel": "iPad", "configured": PadSettings.configured, "endpoint": PadSettings.agentEndpoint,
                            "tools": ["device_status"], "toolSpecs": [], "toolGuide": "", "bankProfileSupported": false,
                            "uiScale": PadSettings.uiScale] as [String: Any]
                case "request":
                    guard let path = args["path"] as? String, let payload = args["body"] as? [String: Any] else { throw PadServerClient.Failure.invalidRequest }
                    if ["/v1/session", "/v1/memories/save", "/v1/responses"].contains(path), !isActive { throw PadServerClient.Failure.inactive }
                    return try PadServerClient.shared.agentRequest(path: path, body: payload)
                case "executeTool":
                    guard args["name"] as? String == "device_status" else { throw PadServerClient.Failure.invalidRequest }
                    return ["platform": "macos", "deviceLabel": "iPad"] as [String: Any]
                default: throw PadServerClient.Failure.invalidRequest
                }
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let value): self.reply(id, result: value)
                case .failure(let error): self.reply(id, failure: (error as? PadServerClient.Failure) ?? .connection)
                }
            }
        }
    }

    private func reply(_ id: String, result: Any) { send(["id": id, "result": result]) }
    private func reply(_ id: String, failure: PadServerClient.Failure) { send(["id": id, "error": ["code": failure.code, "message": failure.message]]) }
    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.ppomiAgentReceive?.(\(json))")
    }

    /// 통화(음성)의 마이크: 번들 문서에만 허용.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(frame.isMainFrame && frame.request.url == Self.entry && type == .microphone ? .grant : .deny)
    }
}

/// Supabase(구글 로그인 토큰) 와 에이전트 서버(Vercel) 호출. 토큰은 여기 밖으로 나가지 않고, 모든 요청에 이 기기의 X-Ppomi-Device 가 붙는다.
final class PadServerClient {
    enum Failure: Error {
        case unconfigured, unregistered, authentication, permission, connection, server(Int), invalidResponse, invalidRequest, inactive
        var code: String {
            switch self {
            case .unconfigured: "server_unconfigured"
            case .unregistered, .authentication, .permission: "server_auth"
            case .connection: "server_unavailable"
            case .server: "server_rejected"
            case .invalidResponse: "response_invalid"
            case .invalidRequest: "invalid_request"
            case .inactive: "session_ended"
            }
        }
        var message: String {
            switch self {
            case .unconfigured: "설정에서 구글 로그인"
            case .unregistered: "설정에서 Mac 의 QR 읽기"
            case .authentication: "다시 로그인 필요"
            case .permission: "기기 권한 없음"
            case .connection: "서버 응답 없음"
            case .server(let s): "서버 거부 (\(s))"
            case .invalidResponse: "응답 형식 오류"
            case .invalidRequest: "요청 형식 오류"
            case .inactive: "대화 종료"
            }
        }
    }
    static let shared = PadServerClient()
    static let paths: Set<String> = ["/v1/session", "/v1/responses", "/v1/memories/list", "/v1/memories/save", "/v1/memories/delete"]
    private let lock = NSLock()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 120; c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    /// 유효한 액세스 토큰. 만료 30초 전이면 refresh_token 으로 갱신한다. 세션이 없으면 unconfigured.
    func token() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard var s = Session.load() else { throw Failure.unconfigured }
        if s.expiresAt.timeIntervalSinceNow > 30 { return s.accessToken }
        var r = Self.authRequest("/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        r.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
        let (data, status) = try send(r)
        guard status == 200, let t = Self.tokens(data) else { throw Failure.authentication }
        s.accessToken = t.access; s.refreshToken = t.refresh; s.expiresAt = t.expiresAt
        try s.save()
        return s.accessToken
    }
    /// PKCE: 로그인 창이 돌려준 code + verifier → 토큰.
    static func exchange(code: String, verifier: String) throws -> Session {
        var r = authRequest("/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "pkce")])
        r.httpBody = try JSONSerialization.data(withJSONObject: ["auth_code": code, "code_verifier": verifier])
        let (data, status) = try shared.send(r)
        guard status == 200, let t = tokens(data) else { throw Failure.authentication }
        return Session(accessToken: t.access, refreshToken: t.refresh, expiresAt: t.expiresAt, registered: false)
    }
    private static func tokens(_ data: Data) -> (access: String, refresh: String, expiresAt: Date)? {
        guard data.count <= 65_536, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, (16...16_384).contains(access.count), !access.contains(where: { $0.isWhitespace }),
              let refresh = o["refresh_token"] as? String, !refresh.isEmpty, let ttl = o["expires_in"] as? NSNumber, ttl.doubleValue > 0 else { return nil }
        return (access, refresh, Date().addingTimeInterval(min(ttl.doubleValue, 86_400)))
    }

    func rpc(_ name: String, _ args: [String: Any]) throws -> Any {
        var r = Self.authRequest("/rest/v1/rpc/" + name)
        r.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization")
        r.setValue(PadSettings.deviceID, forHTTPHeaderField: "X-Ppomi-Device")
        r.httpBody = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let (data, status) = try send(r)
        return try Self.decode(data, status)
    }
    func agentRequest(path: String, body: [String: Any]) throws -> Any {
        guard Self.paths.contains(path) else { throw Failure.invalidRequest }
        guard PadSettings.configured else { throw Failure.unregistered }
        var r = URLRequest(url: URL(string: PadSettings.agentEndpoint)!.appendingPathComponent(String(path.dropFirst())))
        r.httpMethod = "POST"; r.timeoutInterval = path == "/v1/responses" ? 120 : 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        r.setValue("Bearer " + (try token()), forHTTPHeaderField: "Authorization")
        r.setValue(PadSettings.deviceID, forHTTPHeaderField: "X-Ppomi-Device")
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, status) = try send(r)
        return try Self.decode(data, status)
    }
    private static func authRequest(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(string: PadSettings.supabaseURL)!; c.path = path; if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(PadSettings.publishableKey, forHTTPHeaderField: "apikey")
        return r
    }
    /// 다리 큐에서 동기로: 대화 앱은 응답 하나를 기다린다.
    private func send(_ request: URLRequest) throws -> (Data, Int) {
        var result: (Data, Int)?; let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if let data, let status = (response as? HTTPURLResponse)?.statusCode { result = (data, status) }
            done.signal()
        }.resume()
        done.wait()
        guard let result else { throw Failure.connection }
        return result
    }
    static func decode(_ data: Data, _ status: Int) throws -> Any {
        guard data.count <= 2_000_000 else { throw Failure.invalidResponse }
        guard (200...299).contains(status) else {
            if status == 401 { throw Failure.authentication }
            if status == 403 { throw Failure.permission }
            throw Failure.server(status)
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), value is [String: Any] || value is [Any] else { throw Failure.invalidResponse }
        return value
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
