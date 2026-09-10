// 아이패드 = 작업대 한 장(Web/pad.html): 왼쪽 대화(번들 agent 앱 + 네이티브 다리), 오른쪽 장부(서버의 암호화 기록으로 만든 타임라인·증빙 iframe).
// 문서는 번들만 신뢰한다(ppomipad://app/pad.html). 설정은 톱니 하나: 구글 로그인, Mac 의 QR.
import SwiftUI
import VisionKit
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
        cfg.userContentController.add(context.coordinator, name: "ppomiAgent")
        cfg.allowsInlineMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isInspectable = true
        v.scrollView.bounces = false
        v.uiDelegate = context.coordinator
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
        if path == "/timeline" || path == "/evidence" {
            live.insert(ObjectIdentifier(task))
            queue.async { [weak self] in
                let html: String
                do { html = path == "/timeline" ? try PadVault.timelineHTML() : try PadVault.evidenceHTML() } catch { html = Self.notice(for: error) }
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
        case SharedRecordError.key: text = "설정에서 Mac 의 QR 읽기"
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
    @State private var scanning = false
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("계정") {
                    if let session {
                        Text(session.registered ? "로그인됨 · Mac 장부 연결됨" : "로그인됨 · Mac 장부 연결 전").foregroundStyle(.secondary)
                        Button("로그아웃", role: .destructive) { Session.clear(); self.session = nil; generation += 1 }
                    } else {
                        Button("Google 계정으로 로그인") { run { try await PadAuth.shared.signInWithGoogle() } }
                    }
                }
                if let session, !session.registered {
                    Section("Mac 장부 연결 (Mac 설정 › 아이패드 › 연결 QR 보이기)") {
                        Button("QR 읽기") { scanning = true }
                        TextField("또는 QR 내용 붙여넣기", text: $pasted, axis: .vertical).lineLimit(2...4)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("연결") { let text = pasted; run { try await Task.detached { try PadVault.pair(text) }.value } }.disabled(pasted.isEmpty)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("설정")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner { code in scanning = false; run { try await Task.detached { try PadVault.pair(code) }.value } }
            }
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

/// Mac 화면의 연결 QR 을 카메라로 읽는다(VisionKit). 한 개 읽으면 끝.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            let c = UIViewController(); let label = UILabel(); label.text = "이 기기에서는 카메라 QR 읽기를 쓸 수 없습니다. QR 내용을 붙여넣어 주세요."
            label.numberOfLines = 0; label.textAlignment = .center; label.frame = c.view.bounds.insetBy(dx: 24, dy: 24); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            c.view.addSubview(label); return c
        }
        let s = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        s.delegate = context.coordinator
        try? s.startScanning()
        return s
    }
    func updateUIViewController(_ c: UIViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(_ onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in added { if !done, let text = code.payloadStringValue { done = true; scanner.stopScanning(); onCode(text); break } }
        }
    }
}
