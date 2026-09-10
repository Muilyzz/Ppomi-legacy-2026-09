import Foundation

/// Serializes authentication and RPCs. No credentials, tokens, or raw network error bodies escape this client.
final class SharedServerClient: @unchecked Sendable {
    struct Reply { let data: Data; let status: Int }
    typealias Transport = (URLRequest) throws -> Reply
    static let shared = SharedServerClient()

    private let configuration: () throws -> SharedServerConfiguration?
    private let transport: Transport
    private let lock = NSLock()
    private var activeConfiguration: SharedServerConfiguration?
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var context: [String: Any]?

    init(configuration: @escaping () throws -> SharedServerConfiguration? = SharedServerConfiguration.load,
         transport: @escaping Transport = SharedServerClient.send) {
        self.configuration = configuration; self.transport = transport
    }

    func status() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let config = try configuration() else { return ["configured": false, "connected": false, "localDataImported": false] }
        var status = config.safeStatus
        do {
            try authenticate(config)
            let response = try requestRPC("ppomi_context", arguments: [:], config: config)
            try validateContext(response, config: config)
            status["connected"] = true
            status["context"] = response
        } catch {
            status["connected"] = false
            status["error"] = Self.safe(error).description
        }
        return status
    }

    func rpc(_ method: String, _ arguments: [String: Any]) throws -> Any {
        guard SharedTools.rpcNames.contains(method) || SharedRecordVault.rpcNames.contains(method) else { throw SharedServerError.invalidArgument("RPC") }
        lock.lock(); defer { lock.unlock() }
        guard let config = try configuration() else { throw SharedServerError.unconfigured }
        try authenticate(config)
        return try requestRPC(method, arguments: arguments, config: config)
    }

    /// The bundled voice client can call only the dedicated agent routes. Tokens stay native.
    func agentRequest(endpoint: String, path: String, body: [String: Any]) throws -> Any {
        let url = try AgentNativePolicy.requestURL(endpoint: endpoint, path: path)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= 1024 * 1024 else { throw AgentNativeError.invalidRequest }   // a Responses turn carries instructions, tools and history
        lock.lock(); defer { lock.unlock() }
        guard let config = try configuration() else { throw SharedServerError.unconfigured }
        try authenticate(config)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = path == "/v1/responses" ? 120 : 20   // one flagship-model turn may take a minute
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let reply = try safeSend(request)
        if reply.status == 401 { accessToken = nil; context = nil; throw SharedServerError.authentication }
        return try Self.decode(reply)
    }

    private func authenticate(_ config: SharedServerConfiguration) throws {
        try config.validate()
        if config != activeConfiguration {
            activeConfiguration = config; accessToken = nil; context = nil; expiresAt = .distantPast
        }
        if accessToken != nil, expiresAt.timeIntervalSinceNow > 30, context != nil { return }
        accessToken = nil; context = nil
        var request = baseRequest(config, path: "auth/v1/token")
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
        let response = try requestRPC("ppomi_context", arguments: [:], config: config)
        try validateContext(response, config: config)
    }

    private func validateContext(_ response: Any, config: SharedServerConfiguration) throws {
        guard let object = response as? [String: Any], let device = object["device"] as? [String: Any],
              let id = device["id"] as? String, let workspace = object["workspace"] as? [String: Any],
              let workspaceID = workspace["id"] as? String, UUID(uuidString: workspaceID) != nil,
              object["devices"] is [[String: Any]] else { throw SharedServerError.invalidResponse }
        guard id.lowercased() == config.deviceId.lowercased() else {
            accessToken = nil; context = nil; throw SharedServerError.deviceMismatch
        }
        context = object
    }

    private func requestRPC(_ method: String, arguments: [String: Any], config: SharedServerConfiguration) throws -> Any {
        var request = baseRequest(config, path: "rest/v1/rpc/" + method)
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let reply = try safeSend(request)
        // A failed or interrupted mutation is never silently replayed. Caller-controlled IDs support explicit retries.
        if reply.status == 401 { accessToken = nil; context = nil; throw SharedServerError.authentication }
        return try Self.decode(reply)
    }

    private func baseRequest(_ config: SharedServerConfiguration, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: config.url)!.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
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
