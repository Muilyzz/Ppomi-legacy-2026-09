import Foundation

/// Serializes authentication and RPCs. No credentials, tokens, or raw network error bodies escape this client.
final class SharedServerClient: @unchecked Sendable {
    struct Reply { let data: Data; let status: Int }
    typealias Transport = (URLRequest) throws -> Reply
    static let shared = SharedServerClient()

    private let configuration: () throws -> SharedServerConfiguration?
    private let currentSession: () -> MacSession?
    private let currentDeviceID: () -> String
    private let refreshSession: (String) throws -> SupabaseAuth.Tokens
    private let saveSession: (MacSession) throws -> Void
    private let transport: Transport
    private let lock = NSLock()
    private var activeConfiguration: SharedServerConfiguration?
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var context: [String: Any]?
    /// 어느 자격으로 붙었는지: 구글 세션(기본) 또는 옛 기기 계정(--configure-shared).
    private var mode: Mode?
    private enum Mode { case session, legacy }
    private struct Credentials { let url: String; let publishableKey: String; let deviceId: String; let mode: Mode }

    init(configuration: @escaping () throws -> SharedServerConfiguration? = { try SharedServerConfiguration.load(interactionAllowed: false) },
         session: @escaping () -> MacSession? = { GoogleAccount.session },
         deviceID: @escaping () -> String = { GoogleAccount.deviceID },
         refreshSession: @escaping (String) throws -> SupabaseAuth.Tokens = SupabaseAuth.refresh,
         saveSession: @escaping (MacSession) throws -> Void = GoogleAccount.save,
         transport: @escaping Transport = SharedServerClient.send) {
        self.configuration = configuration; self.transport = transport
        self.currentSession = session; self.currentDeviceID = deviceID
        self.refreshSession = refreshSession; self.saveSession = saveSession
    }

    /// 구글 세션이 있으면 그것, 없으면 옛 기기 계정. 둘 다 없으면 미설정.
    var isConfigured: Bool { currentSession() != nil || (try? configuration()) != nil }
    /// The shared shell receives presentation state only, never account email or credentials.
    var authentication: [String: Any] {
        guard let session = currentSession() else { return ["method": "google", "signedIn": false] }
        var result: [String: Any] = ["method": "google", "signedIn": true]
        if let name = session.name, !name.isEmpty { result["displayName"] = name }
        return result
    }
    /// 세션·계정이 바뀌었다: 다음 요청에서 다시 붙는다.
    func invalidate() { lock.lock(); accessToken = nil; context = nil; mode = nil; expiresAt = .distantPast; lock.unlock() }

    func status() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var status: [String: Any]
        if let s = currentSession() {
            status = ["configured": true, "host": URL(string: PpomiServer.supabaseURL)?.host ?? "", "deviceId": currentDeviceID(), "authority": "server",
                      "account": s.email, "localDataImported": SharedRecordVault.enabled, "recordsEncrypted": SharedRecordVault.enabled]
        } else {
            guard let config = try configuration() else { return ["configured": false, "connected": false, "localDataImported": false] }
            status = config.safeStatus
        }
        do {
            let credentials = try authenticate(legacy: false)
            let response = try requestRPC("ppomi_context", arguments: [:], credentials: credentials)
            try validateContext(response, deviceId: credentials.deviceId)
            status["connected"] = true
            status["context"] = response
        } catch {
            status["connected"] = false
            status["error"] = Self.safe(error).description
        }
        return status
    }

    /// `legacy`: 구글 세션이 있어도 옛 기기 계정으로(첫 로그인 때 기기를 넘기는 한 번).
    func rpc(_ method: String, _ arguments: [String: Any], legacy: Bool = false) throws -> Any {
        guard SharedTools.rpcNames.contains(method) || SharedRecordVault.rpcNames.contains(method)
                || SharedTranscriptStore.rpcNames.contains(method) || GoogleAccount.rpcNames.contains(method) else {
            throw SharedServerError.invalidArgument("RPC")
        }
        lock.lock(); defer { lock.unlock() }
        let credentials = try authenticate(legacy: legacy)
        return try requestRPC(method, arguments: arguments, credentials: credentials)
    }

    /// The bundled voice client can call only the dedicated agent routes. Tokens stay native.
    func agentRequest(endpoint: String, path: String, body: [String: Any]) throws -> Any {
        let url = try AgentNativePolicy.requestURL(endpoint: endpoint, path: path)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw AgentNativeError.invalidRequest }   // a Responses turn carries instructions, tools, history — or one screenshot
        lock.lock(); defer { lock.unlock() }
        let credentials = try authenticate(legacy: false)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = path == "/v1/responses" ? 120 : 20   // one flagship-model turn may take a minute
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        if credentials.mode == .session { request.setValue(credentials.deviceId, forHTTPHeaderField: "X-Ppomi-Device") }
        request.httpBody = data
        let reply = try safeSend(request)
        if reply.status == 401 { accessToken = nil; context = nil; throw SharedServerError.authentication }
        return try Self.decode(reply)
    }

    /// 자격을 고르고 토큰을 준비한다. 구글 세션: 만료 30초 전이면 refresh_token 으로 갱신(SupabaseAuth). 옛 기기 계정: 비밀번호 로그인 + ppomi_context 로 기기 확인.
    /// 이미 만든 요청(보조 눈의 /v1/responses)에 로그인 세션과 기기 헤더만 붙여 보낸다. 주소는 에이전트 서버여야 한다. 응답은 그대로(호출자가 검증).
    func agentSend(_ request: URLRequest) throws -> Reply {
        guard let url = request.url, request.httpMethod == "POST", let body = request.httpBody, body.count <= 4 * 1024 * 1024,
              let endpoint = try? AgentNativePolicy.endpoint(Chat.endpoint), url.host == endpoint.host, url.scheme == "https",
              url.path.hasSuffix("/v1/responses") else { throw AgentNativeError.invalidRequest }
        lock.lock(); defer { lock.unlock() }
        let credentials = try authenticate(legacy: false)
        var request = request
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        if credentials.mode == .session { request.setValue(credentials.deviceId, forHTTPHeaderField: "X-Ppomi-Device") }
        let reply = try safeSend(request)
        if reply.status == 401 { accessToken = nil; context = nil; throw SharedServerError.authentication }
        return reply
    }

    private func authenticate(legacy: Bool) throws -> Credentials {
        if !legacy, var session = currentSession() {
            // The account window and executor are separate processes. A new Keychain session must
            // replace this process's cache immediately, including an account switch before expiry.
            if mode != .session || accessToken != session.accessToken { accessToken = nil; context = nil; expiresAt = .distantPast; activeConfiguration = nil; mode = .session }
            let credentials = Credentials(url: PpomiServer.supabaseURL, publishableKey: PpomiServer.publishableKey, deviceId: currentDeviceID(), mode: .session)
            if accessToken != nil, expiresAt.timeIntervalSinceNow > 30 { return credentials }
            if session.expiresAt.timeIntervalSinceNow <= 30 {
                let tokens: SupabaseAuth.Tokens
                do { tokens = try refreshSession(session.refreshToken) }
                catch SupabaseAuth.Failure.connection { throw SharedServerError.connection }
                catch { throw SharedServerError.authentication }
                session.accessToken = tokens.access; session.refreshToken = tokens.refresh; session.expiresAt = tokens.expiresAt
                try saveSession(session)
            }
            accessToken = session.accessToken; expiresAt = session.expiresAt
            return credentials
        }
        guard let config = try configuration() else { throw SharedServerError.unconfigured }
        try config.validate()
        if mode != .legacy || config != activeConfiguration {
            activeConfiguration = config; accessToken = nil; context = nil; expiresAt = .distantPast; mode = .legacy
        }
        let credentials = Credentials(url: config.url, publishableKey: config.publishableKey, deviceId: config.deviceId, mode: .legacy)
        if accessToken != nil, expiresAt.timeIntervalSinceNow > 30, context != nil { return credentials }
        accessToken = nil; context = nil
        var request = baseRequest(credentials, path: "auth/v1/token")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        request.url = components.url
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": config.email, "password": config.password])
        let reply = try safeSend(request)
        guard reply.status == 200, reply.data.count <= 65_536,
              let body = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              let token = body["access_token"] as? String, (16...16_384).contains(token.count),
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              let ttl = body["expires_in"] as? NSNumber, ttl.doubleValue > 0 else { throw SharedServerError.authentication }
        accessToken = token; expiresAt = Date().addingTimeInterval(min(ttl.doubleValue, 86_400))
        let response = try requestRPC("ppomi_context", arguments: [:], credentials: credentials)
        try validateContext(response, deviceId: credentials.deviceId)
        return credentials
    }

    private func validateContext(_ response: Any, deviceId: String) throws {
        guard let object = response as? [String: Any], let device = object["device"] as? [String: Any],
              let id = device["id"] as? String, let workspace = object["workspace"] as? [String: Any],
              let workspaceID = workspace["id"] as? String, UUID(uuidString: workspaceID) != nil,
              object["devices"] is [[String: Any]] else { throw SharedServerError.invalidResponse }
        guard id.lowercased() == deviceId.lowercased() else {
            accessToken = nil; context = nil; throw SharedServerError.deviceMismatch
        }
        context = object
    }

    private func requestRPC(_ method: String, arguments: [String: Any], credentials: Credentials) throws -> Any {
        var request = baseRequest(credentials, path: "rest/v1/rpc/" + method)
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        if credentials.mode == .session { request.setValue(credentials.deviceId, forHTTPHeaderField: "X-Ppomi-Device") }
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let reply = try safeSend(request)
        // A failed or interrupted mutation is never silently replayed. Caller-controlled IDs support explicit retries.
        if reply.status == 401 { accessToken = nil; context = nil; throw SharedServerError.authentication }
        return try Self.decode(reply)
    }

    private func baseRequest(_ credentials: Credentials, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: credentials.url)!.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.publishableKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func safeSend(_ request: URLRequest) throws -> Reply {
        do { return try transport(request) } catch { throw Self.safe(error) }
    }

    static func safe(_ error: Error) -> SharedServerError { (error as? SharedServerError) ?? .connection }

    static func decode(_ reply: Reply) throws -> Any {
        guard reply.data.count <= 2_000_000 else { throw SharedServerError.invalidResponse }
        guard (200...299).contains(reply.status) else {
            let body = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
            let code = body?["code"] as? String ?? ""
            let message = (body?["message"] as? String ?? "").lowercased()
            // Inspect only recognized server categories; never echo a server body containing user data or credentials.
            if reply.status == 409 || ["23505", "40001", "PT409", "55000"].contains(code)
                || message.contains("version_conflict") || message.contains("idempotency_conflict") {
                throw SharedServerError.conflict
            }
            if reply.status == 401 { throw SharedServerError.authentication }
            if reply.status == 403 || code == "42501" { throw SharedServerError.permission }
            if reply.status == 404 || code == "P0002" { throw SharedServerError.notFound }
            if code == "22023" { throw SharedServerError.invalidArgument("입력 또는 재사용한 변경 ID") }
            throw SharedServerError.server(reply.status)
        }
        guard let value = try? JSONSerialization.jsonObject(with: reply.data, options: [.fragmentsAllowed]),
              value is [String: Any] || value is [Any] else { throw SharedServerError.invalidResponse }
        return value
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func send(_ request: URLRequest) throws -> Reply {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 20; settings.timeoutIntervalForResource = 20
        settings.httpShouldSetCookies = false; settings.urlCache = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let finished = DispatchSemaphore(value: 0), resultLock = NSLock()
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = session.dataTask(with: request) { data, response, error in
            resultLock.lock(); result = (data, response, error); resultLock.unlock(); finished.signal()
        }
        task.resume()
        guard finished.wait(timeout: .now() + 21) == .success else { task.cancel(); throw SharedServerError.connection }
        resultLock.lock(); let value = result; resultLock.unlock()
        guard value.2 == nil, let data = value.0, let response = value.1 as? HTTPURLResponse else { throw SharedServerError.connection }
        return Reply(data: data, status: response.statusCode)
    }
}
