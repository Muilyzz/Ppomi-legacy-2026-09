// 아이패드 = 뷰어 한 장(Web/pad.html): 탭 한 줄 + 서버의 암호화 기록으로 만든 페이지(타임라인·증빙·분개) iframe. 키보드가 없는 기기라 타자 입력은 없고, 대화는 뒤에 통화로.
// 문서는 번들 또는 서명 검증한 화면 묶음만 신뢰한다(ppomipad://app/pad.html). 장부 키는 Mac 이 작업 공간에 올린 것을 받는다.
import SwiftUI
import WebKit

@main struct PpomiPad: App { var body: some Scene { WindowGroup { ContentView() } } }

struct ContentView: View {
    @State private var settings = false
    @State private var generation = 0   // 로그인·연결·로그아웃마다 +1 → 페이지 다시 읽기
    var body: some View {
        PadWebView(generation: generation)
            .overlay(alignment: .topTrailing) {
                // 프로필 아이콘 = 나: 로그인 전엔 실루엣, 뒤엔 구글 사진. Mac 과 같은 자리·같은 시트.
                Button { settings = true } label: { AvatarView(session: Session.load(), size: 28) }
                    .padding(10).accessibilityLabel("나")
            }
            .sheet(isPresented: $settings) { SettingsSheet(generation: $generation) }
            .onAppear { if !PadSettings.configured { settings = true } }
    }
}

struct PadWebView: UIViewRepresentable {
    let generation: Int
    func makeCoordinator() -> PadWebCoordinator { PadWebCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.setURLSchemeHandler(context.coordinator.files, forURLScheme: PadFiles.scheme)
        // 기록 뷰어에는 대화·도구 다리를 등록하지 않는다. 준비 신호는 별도의 작은 다리로만 받는다.
        cfg.userContentController.add(context.coordinator, name: "ppomiUpdateReady")
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isInspectable = true
        v.scrollView.bounces = false
        context.coordinator.webView = v
        context.coordinator.generation = generation
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        context.coordinator.prepare()
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        if context.coordinator.generation != generation {
            context.coordinator.generation = generation
            context.coordinator.reload()
        }
    }
    static func dismantleUIView(_ v: WKWebView, coordinator: PadWebCoordinator) {
        coordinator.stop()
        v.configuration.userContentController.removeScriptMessageHandler(forName: "ppomiUpdateReady")
        v.navigationDelegate = nil
        v.uiDelegate = nil
        v.stopLoading()
    }
}

/// 업데이트는 다음 앱 실행에서만 고른다. 새 화면이 준비되지 않으면 같은 실행에서 번들 뷰어로 되돌린다.
final class PadWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    let files = PadFiles()
    var generation = 0
    private var prepared = false
    private var ready = false
    private var timeout: DispatchWorkItem?
    private let updates = FamilyUpdateRuntime.shared

    func prepare() {
        // 기록은 네이티브가 읽는다. 웹 안의 외부 요청은 막아 원격 코드가 검증한 묶음에 섞이지 않게 한다.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "PpomiPadFamilyUpdatesV1", encodedContentRuleList: rules) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                guard let self, let view = self.webView else { return }
                if let ruleList { view.configuration.userContentController.add(ruleList) }
                else {
                    self.updates.markFailed()
                    self.updates.useBundledFallback()
                }
                self.prepared = true
                self.reload()
                self.updates.checkInBackground()
            }
        }
    }

    func reload() {
        guard prepared, let webView else { return }
        timeout?.cancel()
        webView.stopLoading()
        files.cancelPendingRequests()
        webView.load(URLRequest(url: PadBridge.entry, cachePolicy: .reloadIgnoringLocalCacheData))
        if updates.isTrial && !ready {
            let timeout = DispatchWorkItem { [weak self] in self?.recoverTrial() }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        }
    }

    func stop() { timeout?.cancel(); files.cancelPendingRequests(); webView = nil }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ppomiUpdateReady", message.frameInfo.isMainFrame,
              message.frameInfo.request.url == PadBridge.entry, message.webView === webView,
              let body = message.body as? [String: Any], body.count == 1,
              let version = body["bridgeVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == NSNumber(value: 1) else { return }
        ready = true
        timeout?.cancel()
        updates.markReady()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.targetFrame, let url = action.request.url else { decisionHandler(.cancel); return }
        if target.isMainFrame {
            decisionHandler(url == PadBridge.entry ? .allow : .cancel)
        } else {
            let allowed = url.scheme == PadFiles.scheme && url.host == "app" && url.user == nil && url.password == nil
                && url.port == nil && url.query == nil && url.fragment == nil
                && ["/timeline", "/evidence", "/journal"].contains(url.path)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { recoverTrial() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { recoverTrial() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recoverTrial() }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)   // records.v1 화면 묶음은 마이크·카메라 권한을 추가하지 못한다.
    }

    private func recoverTrial() {
        guard updates.isTrial && !ready, let webView else { return }
        timeout?.cancel()
        webView.stopLoading()
        files.cancelPendingRequests()
        updates.markFailed()
        updates.useBundledFallback()
        reload()
    }
}

/// 고른 화면 묶음과 만든 페이지를 ppomipad://app/<path> 로 준다: CSP 'self' 가 뜻을 가지려면 file:// 이 아니어야 한다.
/// /timeline · /evidence 는 서버의 암호화 기록을 읽어 그 자리에서 만든다(뒤 큐에서).
final class PadFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "ppomipad"
    private static let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2",
                                "png": "image/png", "svg": "image/svg+xml", "json": "application/json"]
    private var live = Set<ObjectIdentifier>()   // 아직 답하지 않은 페이지 요청(메인 스레드만)
    private let queue = DispatchQueue(label: "ppomi.pad.files")

    static func file(_ name: String, _ ext: String) -> String {
        read(name + "." + ext, root: FamilyUpdateRuntime.shared.directory)
    }
    /// Mac Web.page 와 같다: 템플릿의 /*THEME*/ 에 토큰 + 테마.
    static func page(_ name: String) -> String {
        let root = FamilyUpdateRuntime.shared.directory
        return read(name + ".html", root: root).replacingOccurrences(of: "/*THEME*/", with: read("tokens.css", root: root) + "\n" + read("theme.css", root: root))
    }
    private static func read(_ relative: String, root: URL?) -> String {
        guard let file = asset(relative, root: root), let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text
    }
    /// 한 묶음에서만 읽는다. 파일이 없다고 다른 버전의 번들 파일을 섞지 않는다.
    private static func asset(_ relative: String, root: URL?) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relative.contains("\\"), !relative.contains("\0"), let base = root ?? Bundle.main.resourceURL else { return nil }
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath()
        let file = basePath.appendingPathComponent(relative).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        guard file == resolved, resolved.path.hasPrefix(basePath.path + "/") else { return nil }
        return resolved
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let root = FamilyUpdateRuntime.shared.directory
        guard let url = task.request.url, url.scheme == Self.scheme, url.host == "app", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              Self.asset(String(url.path.dropFirst()), root: root) != nil else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path
        if path == "/timeline" || path == "/evidence" || path == "/journal" {
            live.insert(ObjectIdentifier(task))
            queue.async { [weak self] in
                let html: String
                do { html = path == "/timeline" ? try PadVault.timelineHTML() : path == "/journal" ? try PadVault.journalHTML() : try PadVault.evidenceHTML() }
                catch { html = Self.notice(for: error) }
                DispatchQueue.main.async {
                    guard let self, self.live.remove(ObjectIdentifier(task)) != nil else { return }
                    Self.deliver(task, Data(html.utf8), "text/html")
                }
            }
            return
        }
        guard let file = Self.asset(String(path.dropFirst()), root: root),
              let type = Self.types[file.pathExtension], let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        Self.deliver(task, data, type)
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }
    /// WebKit 의 stop 통지가 늦더라도 이전 문서의 비동기 기록 응답은 새 화면에 전달하지 않는다.
    func cancelPendingRequests() { live.removeAll() }
    private static func deliver(_ task: WKURLSchemeTask, _ data: Data, _ type: String) {
        task.didReceive(response(for: task.request.url!, type: type, count: data.count))
        task.didReceive(data); task.didFinish()
    }
    private static func response(for url: URL, type: String, count: Int) -> URLResponse {
        // sandbox 문서의 origin 은 opaque 이므로 공개 폰트에만 CORS 를 허용한다. 장부 응답에는 허용하지 않는다.
        if type == "font/woff2", let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": String(count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]) {
            return response
        }
        return URLResponse(url: url, mimeType: type, expectedContentLength: count, textEncodingName: "utf-8")
    }
    /// 아직 안 될 때의 한 줄: 로그인 전 · 연결 전 · 서버 오류.
    static func notice(for error: Error) -> String {
        let text: String
        switch error {
        case PadServerClient.Failure.unconfigured: text = "설정에서 구글 로그인"
        case SharedRecordError.key: text = "Mac 뽀미가 켜져 있으면 몇 초 안에 키를 받습니다 · 탭을 다시 누르세요"
        default: text = (error as? PadServerClient.Failure)?.message ?? (error as? LocalizedError)?.errorDescription ?? "기록을 읽지 못함"
        }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let root = FamilyUpdateRuntime.shared.directory
        return "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\"><style>" + read("tokens.css", root: root) + read("theme.css", root: root)
            + " body{display:grid;place-items:center;min-height:100vh;margin:0;max-width:none;color:var(--fg-2)}</style></head><body><p>" + escaped + "</p></body></html>"
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var generation: Int
    @State private var session = Session.load()
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(session: session, size: 44)
                        VStack(alignment: .leading) {
                            Text(session?.name ?? "나").font(.headline)
                            if let email = session?.email { Text(email).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("계정") {
                    if let session {
                        Text(session.registered ? "Google · 기기 등록됨" : "Google · 기기 등록 전").foregroundStyle(.secondary)
                        Button("로그아웃", role: .destructive) { Session.clear(); self.session = nil; generation += 1 }
                    } else {
                        Button("Google 계정으로 로그인") { run { try await PadAuth.shared.signInWithGoogle() } }
                        Text("Mac 뽀미와 같은 구글 계정으로 로그인하면 같은 장부를 봅니다").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("나")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .disabled(busy)
        }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await work(); session = Session.load(); generation += 1 }
            catch { self.error = (error as? PadServerClient.Failure)?.message ?? (error as? LocalizedError)?.errorDescription ?? "실패: \(error)" }
            busy = false
        }
    }
}

/// 구글 프로필 사진, 없으면 이니셜, 로그인 전엔 실루엣. Mac 과 같은 모양.
struct AvatarView: View {
    let session: Session?
    let size: CGFloat
    var body: some View {
        Group {
            if let session, let url = session.avatarURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { initial(session) }
            } else if let session { initial(session) }
            else { Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    private func initial(_ session: Session) -> some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.2))
            Text(String((session.name ?? session.email ?? "나").prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Color.accentColor)
        }
    }
}
