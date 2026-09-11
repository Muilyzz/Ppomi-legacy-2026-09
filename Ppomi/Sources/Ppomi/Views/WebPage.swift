// A page of ours in a WKWebView: HTML built by the app (template + JSON), messages back through webkit.messageHandlers.ppomi.
// HTML owns document identity; data update scripts and focus run once per change in the existing document.
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct WebPage: NSViewRepresentable {
    let html: String
    var focus: String? = nil
    var updateScript: String? = nil
    var onMessage: ((Any) -> Void)? = nil
    var onReady: ((WKWebView) -> Void)? = nil          // the page is loaded: a caller may keep the view to call into it

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WebPage.configuration()
        cfg.userContentController.add(context.coordinator, name: "ppomi")
        let v = WorkbenchWebView(frame: .zero, configuration: cfg)
        v.underPageBackgroundColor = Palette.bg
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        c.focus = focus; c.updateScript = updateScript; c.onMessage = onMessage; c.onReady = onReady
        if c.html != html {
            WindowDiagnostics.log("web.load", ["bytes": html.utf8.count])
            c.html = html; c.loaded = false; v.loadHTMLString(html, baseURL: WebFiles.base)
        }
        else if c.loaded { c.apply(v) }
    }
    /// Pages are HTML strings; their relative subresources (the bundled font) come from Web/ through WebFiles.
    static func configuration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(WebFiles(), forURLScheme: WebFiles.scheme)
        return cfg
    }
    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "ppomi")
        v.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var html = "", focus: String?, loaded = false, applied: String? = nil
        var updateScript: String?, appliedUpdateScript: String?
        var onMessage: ((Any) -> Void)?
        var onReady: ((WKWebView) -> Void)?
        /// JavaScript prompt() (예: 타임라인 '+ 그룹'): WKWebView 는 이 델리게이트 없이는 조용히 null 을 돌려준다. 시트 한 장; 테스트는 바꿔 끼운다.
        var prompt: (_ message: String, _ defaultText: String?, _ window: NSWindow?) -> String? = { message, defaultText, window in
            let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.stringValue = defaultText ?? ""
            alert.accessoryView = field; alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        func webView(_ v: WKWebView, runJavaScriptTextInputPanelWithPrompt message: String, defaultText: String?, initiatedByFrame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(prompt(message, defaultText, v.window))
        }
        private var scaleObserver: NSObjectProtocol?
        /// The page's whole UI follows the app's 글자 크기: set once per load and again whenever the setting changes.
        func applyScale(_ v: WKWebView) {
            v.evaluateJavaScript("document.documentElement.style.setProperty('--ui-scale','\(AppSettings.uiScale)')")
            if scaleObserver == nil {
                scaleObserver = NotificationCenter.default.addObserver(forName: Fonts.scaleChanged, object: nil, queue: .main) { [weak self, weak v] _ in
                    guard let self, let v, self.loaded else { return }
                    self.applyScale(v)
                }
            }
        }
        deinit { if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) } }
        func apply(_ v: WKWebView) {
            if appliedUpdateScript != updateScript {
                appliedUpdateScript = updateScript
                if let updateScript { v.evaluateJavaScript(updateScript) }
            }
            guard applied != focus else { return }
            applied = focus
            let argument = String(decoding: try! JSONEncoder().encode(focus), as: UTF8.self)
            v.evaluateJavaScript("typeof focus==='function'&&focus(\(argument))")
        }
        func webView(_ v: WKWebView, didFinish: WKNavigation!) {
            WindowDiagnostics.log("web.ready")
            loaded = true; applied = nil; appliedUpdateScript = nil; applyScale(v); apply(v); onReady?(v)
        }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.frameInfo.isMainFrame else { return }
            onMessage?(m.body)
        }
    }
}

/// Serves Web/ from the bundle as ppomi-web://web/<path>. A file:// base URL does not work for HTML strings:
/// the network process gets no sandbox extension for it, so ./Agent/fonts/PretendardVariable.woff2 fails to load.
final class WebFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "ppomi-web"
    static let base = URL(string: "\(scheme)://web/")!
    func webView(_ v: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = Web.directory.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(Web.directory.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ v: WKWebView, stop task: WKURLSchemeTask) {}
}
