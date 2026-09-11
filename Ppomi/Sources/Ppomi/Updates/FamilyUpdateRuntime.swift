import Foundation

/// One selection for every web surface in a process. Config is shipped in the signed native app, never fetched.
final class FamilyUpdateRuntime {
    #if os(iOS)
    static let platform = "ipados"
    static let capabilities: Set<String> = ["records.v1"]
    #else
    static let platform = "macos"
    static let capabilities: Set<String> = ["agent.v1", "records.v1"]
    #endif
    static let nativeBuild = 1
    static let bridgeVersion = 1
    static func permitsUpdates(arguments: [String]) -> Bool {
        let headless: Set<String> = ["--mcp", "--snapshot", "--verify-records", "--migrate-records", "--configure-shared", "--configure-agent-endpoint", "--voice"]
        return !arguments.contains(where: { headless.contains($0) || $0.contains(".xctest") })
    }
    static let shared = FamilyUpdateRuntime()
    private let store: FamilyUpdateStore?
    private let configuration: FamilyUpdateConfiguration?
    private let guardLock = NSLock()
    private var requested = false
    private var download: FamilyUpdateDownload?
    private var ready = false
    private var failed = false
    private(set) var lastResult = "disabled"
    var directory: URL? { guardLock.lock(); defer { guardLock.unlock() }; return store?.selected }
    var release: String { guardLock.lock(); defer { guardLock.unlock() }; return store?.release ?? "bundled" }
    var isTrial: Bool { guardLock.lock(); defer { guardLock.unlock() }; return store?.isTrial ?? false }
    var hasStartupFailure: Bool { guardLock.lock(); defer { guardLock.unlock() }; return failed }

    private init() {
        // Tests must never connect to an update server or mutate a real user's release state.
        guard NSClassFromString("XCTestCase") == nil,
              Self.permitsUpdates(arguments: ProcessInfo.processInfo.arguments),
              let file = Bundle.main.url(forResource: "Updates", withExtension: "json"),
              let bytes = try? Data(contentsOf: file), bytes.count <= 8192,
              let configuration = try? FamilyUpdateConfiguration.decode(bytes) else {
            self.configuration = nil; self.store = nil; return
        }
        self.configuration = configuration
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Ppomi/Updates", isDirectory: true)
            .appendingPathComponent(configuration.namespace(platform: Self.platform), isDirectory: true)
        let store = FamilyUpdateStore(root: root, configuration: configuration, platform: Self.platform, capabilities: Self.capabilities)
        self.store = store
        do { try store.beginLaunch(); lastResult = store.isTrial ? "trial" : "ready" }
        catch { store.disable(); lastResult = "storage-unavailable" }
    }
    /// nil means either bundled mode or an unavailable pack path. Callers must not mix bundled files into an active pack.
    func fileURL(_ relative: String) -> URL? {
        guard FamilyUpdatePackage.safePath(relative), let directory else { return nil }
        let file = directory.appendingPathComponent(relative)
        guard file.resolvingSymlinksInPath().path == file.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return file
    }
    func checkInBackground() {
        guardLock.lock()
        guard !requested, let configuration, let store, let url = URL(string: configuration.endpoint) else { guardLock.unlock(); return }
        requested = true
        let task = FamilyUpdateDownload(url: url) { [weak self] result in
            guard let self else { return }
            let status: String
            switch result {
            case .success(let data):
                do { try store.stage(data); status = "staged-for-next-launch" }
                catch FamilyUpdateError.replay { status = "up-to-date" }
                catch FamilyUpdateError.incompatible { status = "native-update-required" }
                catch { status = "rejected" }
            case .failure: status = "offline"
            }
            self.guardLock.lock(); self.lastResult = status; self.download = nil; self.guardLock.unlock()
        }
        download = task
        guardLock.unlock()
        task.start()
    }
    func markReady() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard !ready, !failed else { return }
        do { try store?.markReady(); ready = true }
        catch { lastResult = "storage-unavailable" }
    }
    func markFailed() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard !ready else { return }
        failed = true
        do { try store?.markFailed(); lastResult = "startup-failed" }
        catch { lastResult = "storage-unavailable" }
    }
    func useBundledFallback() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard !ready else { return }
        store?.useBundledFallback()
    }
}

/// Streaming cap prevents an untrusted download server from allocating an unbounded response.
/// Redirects are rejected; the updater has no cookies, authentication, record IDs or access to the native bridge.
private final class FamilyUpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private var completion: ((Result<Data, Error>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    init(url: URL, completion: @escaping (Result<Data, Error>) -> Void) { self.url = url; self.completion = completion }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url,
              response.expectedContentLength <= FamilyUpdatePackage.maximumEnvelope else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= FamilyUpdatePackage.maximumEnvelope - data.count else { dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion; completion = nil
        if let error { callback?(.failure(error)) } else { callback?(.success(data)) }
        data.removeAll(); session.finishTasksAndInvalidate(); self.session = nil
    }
}
