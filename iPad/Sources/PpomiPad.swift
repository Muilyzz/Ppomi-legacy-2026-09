// 아이패드 = 뷰어 한 장(Web/pad.html): 탭 한 줄 + 서버의 암호화 기록으로 만든 페이지(타임라인·증빙·분개) iframe. 키보드가 없는 기기라 타자 입력은 없고, 대화는 뒤에 통화로.
// 문서는 번들만 신뢰한다(ppomipad://app/pad.html). 설정은 톱니 하나: 구글 로그인뿐. 장부 키는 Mac 이 작업 공간에 올린 것을 받는다.
import SwiftUI
import WebKit

@main struct PpomiPad: App { var body: some Scene { WindowGroup { ContentView() } } }

struct ContentView: View {
    @State private var settings = false
    @State private var generation = 0   // 로그인·연결·로그아웃마다 +1 → 페이지 다시 읽기
    var body: some View {
        PadWebView(generation: generation)
            .overlay(alignment: .topTrailing) {
                Button { settings = true } label: { Image(systemName: "gearshape").font(.title3) }
                    .padding(10).opacity(0.5).accessibilityLabel("설정")
            }
            .sheet(isPresented: $settings) { SettingsSheet(generation: $generation) }
            .onAppear { if !PadSettings.configured { settings = true } }
    }
}

struct PadWebView: UIViewRepresentable {
    let generation: Int
    func makeCoordinator() -> PadBridge { PadBridge() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(PadFiles(), forURLScheme: PadFiles.scheme)
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isInspectable = true
        v.scrollView.bounces = false
        context.coordinator.webView = v
        v.load(URLRequest(url: PadBridge.entry))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        if context.coordinator.generation != generation { context.coordinator.generation = generation; v.reload() }
    }
}

/// 번들 파일과 만든 페이지를 ppomipad://app/<path> 로 준다: CSP 'self' 가 뜻을 가지려면 file:// 이 아니어야 한다(Mac WebFiles 와 같은 이유).
/// /timeline · /evidence 는 서버의 암호화 기록을 읽어 그 자리에서 만든다(뒤 큐에서).
final class PadFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "ppomipad"
    private static let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2",
                                "png": "image/png", "svg": "image/svg+xml", "json": "application/json"]
    private var live = Set<ObjectIdentifier>()   // 아직 답하지 않은 페이지 요청(메인 스레드만)
    private let queue = DispatchQueue(label: "ppomi.pad.files")

    static func file(_ name: String, _ ext: String) -> String {
        try! String(contentsOf: Bundle.main.url(forResource: name, withExtension: ext)!, encoding: .utf8)
    }
    /// Mac Web.page 와 같다: 템플릿의 /*THEME*/ 에 토큰 + 테마.
    static func page(_ name: String) -> String {
        file(name, "html").replacingOccurrences(of: "/*THEME*/", with: file("tokens", "css") + "\n" + file("theme", "css"))
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app", !url.path.contains("..") else { task.didFailWithError(URLError(.badURL)); return }
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
        let root = Bundle.main.resourceURL!.standardizedFileURL
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path), let type = Self.types[file.pathExtension], let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        Self.deliver(task, data, type)
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }
    private static func deliver(_ task: WKURLSchemeTask, _ data: Data, _ type: String) {
        task.didReceive(URLResponse(url: task.request.url!, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    /// 아직 안 될 때의 한 줄: 로그인 전 · 연결 전 · 서버 오류.
    static func notice(for error: Error) -> String {
        let text: String
        switch error {
        case PadServerClient.Failure.unconfigured: text = "설정에서 구글 로그인"
        case SharedRecordError.key: text = "Mac 뽀미 설정에서 구글 계정 연결"
        default: text = (error as? PadServerClient.Failure)?.message ?? (error as? LocalizedError)?.errorDescription ?? "기록을 읽지 못함"
        }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\"><style>" + file("tokens", "css") + file("theme", "css")
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
                Section("계정") {
                    if let session {
                        Text(session.registered ? "로그인됨 · 기기 등록됨" : "로그인됨 · 기기 등록 전").foregroundStyle(.secondary)
                        Button("로그아웃", role: .destructive) { Session.clear(); self.session = nil; generation += 1 }
                    } else {
                        Button("Google 계정으로 로그인") { run { try await PadAuth.shared.signInWithGoogle() } }
                        Text("Mac 뽀미 설정에서 같은 구글 계정을 연결해 두면 장부가 보입니다").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("설정")
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
