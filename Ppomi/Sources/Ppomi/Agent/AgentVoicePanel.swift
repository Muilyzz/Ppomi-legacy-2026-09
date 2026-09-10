import AppKit
import AVFoundation
import Foundation
import WebKit
import UserNotifications
import os

/// Owns only a trusted bundled document. Neither remote pages nor child frames receive native capabilities.
@MainActor
final class AgentVoicePanel: NSObject, AgentConversationWindow, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onActive: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    /// When this returns a host, the conversation is mounted there instead of opening its own window.
    var host: (() -> ConversationHost?)?
    /// 통화 중 사람의 말(전사). 구두 결재는 Kiosk가 차례와 맞춰 본다.
    var heard: ((String) -> Void)?
    private weak var embeddedHost: ConversationHost?
    private(set) var window: NSWindow?
    private var webView: WKWebView?
    private var entry: URL?
    private var epoch = UUID()
    private var sessionMode = "voice"
    private var pending = Set<String>()
    private let session = AgentNativeSession()
    private let bankProfileRequests = AgentBankProfileRequests()
    private let workspace = AgentWorkspace()
    private let queue = DispatchQueue(label: "ppomi.voice-agent.bridge")
    /// The MCP tool host in-process (fd -1: never speaks JSON-RPC). Same DB, gates and pay boundary as the outside agent; approvals go to the workbench buttons.
    // Built once at panel creation (not lazily inside a bridge call) so bootstrap never pays for it and the two queues below never race on it.
    private let mcp: MCPServer? = try? MCPServer(dbPath: AppSettings.dbPath, fd: -1)
    /// bootstrap only reads static/lazy state; it must not queue behind a two-minute model call or an OCR tool on the bridge queue.
    private let bootstrapQueue = DispatchQueue(label: "ppomi.voice-agent.bootstrap")
    private let defaults: UserDefaults
    private let server: SharedServerClient
    private var terminationObserver: NSObjectProtocol?
    var isVisible: Bool { window?.isVisible == true || (embeddedHost != nil && webView?.window?.isVisible == true) }
    var isEmbedded: Bool { embeddedHost != nil && webView != nil }
    var isActive: Bool { session.isActive }
    private var hostWindow: NSWindow? { window ?? webView?.window }

    init(defaults: UserDefaults = .standard, server: SharedServerClient = .shared) {
        self.defaults = defaults; self.server = server
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pushUIScale), name: Fonts.scaleChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(endpointChanged), name: AgentNativePolicy.endpointChanged, object: nil)
    }

    @objc private func endpointChanged() { invalidateSession() }

    /// 비서의 톡: 사람 차례의 용건을 페이지 말풍선으로 남기고 조용한 알림을 하나 띄운다. 재촉은 알림만 다시 띄운다.
    func notice(_ reason: String, nudge: Bool) {
        if !nudge { note(reason) }
        notify(id: "turn", title: nudge ? "뽀미 · 아직 기다려요" : "뽀미", body: reason)
    }
    /// 페이지 말풍선만(기록용).
    func note(_ text: String) {
        if let json = jsonArg(text) { webView?.evaluateJavaScript("window.ppomiNotice?.(\(json)[0])") }
    }

    /// 답이 없어 전화한다: 페이지에 걸려온 통화 띠를 띄우고(벨은 페이지가 울린다) 시스템 알림도 하나 띄운다. 빈 용건 = 해결됨.
    func ring(_ reason: String) {
        guard let json = jsonArg(reason) else { return }
        webView?.evaluateJavaScript("window.ppomiIncomingCall?.(\(json)[0])")
        guard !reason.isEmpty else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["incoming-call", "turn"]); return
        }
        notify(id: "incoming-call", title: "뽀미가 부릅니다", body: reason)
    }

    private func jsonArg(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func notify(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The page reads uiScale from bootstrap; a later change reaches the live document here.
    @objc private func pushUIScale() {
        webView?.evaluateJavaScript("document.documentElement.style.setProperty('--ui-scale', '\(AppSettings.uiScale)')")
    }

    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    func present() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        if let host = host?() {
            // Already mounted: only the window needs showing. A stale mount from a previous host is replaced.
            if isEmbedded, embeddedHost === host { host.revealConversation(); return }
            if webView != nil { teardown(notifying: false) }
            guard let view = makeWebView(frame: .zero) else { return }
            embeddedHost = host
            host.mount(conversation: view)
            host.revealConversation()
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "뽀미"; panel.minSize = NSSize(width: 360, height: 460)
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center()
        window = panel
        guard let view = makeWebView(frame: panel.contentView?.bounds ?? .zero) else {
            panel.contentView = fallbackLabel(AgentNativeError.unavailable.localizedDescription)
            panel.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    private func fallbackLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .ppomi(3); label.textColor = Palette.fg
        return label
    }

    /// The trusted bundled document in a fresh web view; nil when the bundle lacks it.
    private func makeWebView(frame: CGRect) -> WKWebView? {
        guard let entry = AppResources.bundle.url(forResource: "index", withExtension: "html", subdirectory: "Web/Agent") else { return nil }
        self.entry = entry
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "ppomiAgent")
        // The same first-mouse rules as every other workbench view: a click while Mirroring is in front reaches the page
        // instead of only activating the window (a plain WKWebView swallowed the first click on 음성/채팅).
        let view = WorkbenchWebView(frame: frame, configuration: configuration)
        view.allowsKeyboardInteraction = true   // the chat composer needs the keyboard
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self; view.uiDelegate = self
        view.underPageBackgroundColor = Palette.bg
        webView = view
        let currentEpoch = epoch
        let rules = #"[{"trigger":{"url-filter":"^https?://","resource-type":["script"]},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ppomi-agent-local-scripts-v1", encodedContentRuleList: rules) { [weak self, weak view] rule, _ in
            Task { @MainActor in
                guard let self, let view, self.epoch == currentEpoch, self.webView === view else { return }
                guard let rule else {
                    self.window?.contentView = self.fallbackLabel("보안 설정 실패")
                    return
                }
                view.configuration.userContentController.add(rule)
                view.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
            }
        }
        return view
    }

    func close() {
        if let window { window.close(); return }
        if isEmbedded { teardown() }
    }

    func windowWillClose(_ notification: Notification) { teardown() }

    /// Ends the session and releases the web view, whether it lived in our window or in a workbench host.
    private func teardown(notifying: Bool = true) {
        invalidateSession()
        webView?.evaluateJavaScript("window.ppomiVoiceStop?.()")
        webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "ppomiAgent")
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        if let view = webView, let embeddedHost { embeddedHost.unmount(conversation: view) }
        webView = nil; entry = nil; embeddedHost = nil; window?.contentView = nil; window = nil
        if notifying { onClose?() }
    }

    private func invalidateSession() {
        session.setActive(false); sessionMode = "voice"; epoch = UUID(); pending.removeAll(); onActive?(false)
        bankProfileRequests.invalidate()
        webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ppomiAgent", message.frameInfo.isMainFrame,
              let entry, AgentNativePolicy.trusted(message.frameInfo.request.url, entry: entry),
              let body = message.body as? String, body.utf8.count <= 1536 * 1024,   // a chat turn carries instructions, tools and history
              let data = body.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String, UUID(uuidString: id) != nil,
              let method = request["method"] as? String, let args = request["args"] as? [String: Any],
              !pending.contains(id), pending.count < 32 else { return }

        if method == "sessionState" {
            let mode = args["mode"] as? String ?? "voice"
            guard let active = args["active"] as? Bool,
                  Set(args.keys).isSubset(of: ["active", "mode"]),
                  args["mode"] == nil || args["mode"] is String,
                  mode == "voice" || mode == "text",
                  !active || isVisible else { reply(id, error: AgentNativeError.invalidRequest); return }
            epoch = UUID(); sessionMode = mode; pending.removeAll(); session.setActive(active); bankProfileRequests.invalidate(); onActive?(active)
            if !active || mode == "text" { webView?.setMicrophoneCaptureState(.none, completionHandler: nil) }
            reply(id, result: ["active": active]); return
        }
        if method == "heard" {
            guard Set(args.keys) == ["text"], let text = args["text"] as? String, text.count <= 500, session.isActive
            else { reply(id, error: AgentNativeError.invalidRequest); return }
            heard?(text)
            reply(id, result: ["heard": true]); return
        }
        if method == "declineCall" {   // Mac has no OS call to end; the page already dropped its banner.
            guard args.isEmpty else { reply(id, error: AgentNativeError.invalidRequest); return }
            reply(id, result: ["declined": true]); return
        }
        if method == "setEndpoint" {
            do {
                guard !session.isActive, hostWindow?.isKeyWindow == true, let value = args["endpoint"] as? String else {
                    throw AgentNativeError.invalidRequest
                }
                let url = try AgentNativePolicy.endpoint(value)
                invalidateSession()
                defaults.set(url.absoluteString, forKey: AgentNativePolicy.endpointPreference)
                reply(id, result: ["endpoint": url.absoluteString])
            } catch { reply(id, error: error) }
            return
        }

        let endpoint = defaults.string(forKey: AgentNativePolicy.endpointPreference) ?? ""
        let currentEpoch = epoch
        let nativeRevision = session.revision
        let session = session, workspace = workspace, server = server, bankProfileRequests = bankProfileRequests
        pending.insert(id)
        (method == "bootstrap" ? bootstrapQueue : queue).async { [weak self] in
            guard let self else { return }
            let outcome: Result<Any, Error> = Result {
                guard session.revision == nativeRevision else { throw AgentNativeError.inactive }
                switch method {
                case "bootstrap":
                    let configured = (try? SharedServerConfiguration.load()) != nil && (try? AgentNativePolicy.endpoint(endpoint)) != nil
                    return ["platform": "macos", "deviceLabel": "Mac", "configured": configured,
                            "endpoint": endpoint, "tools": AgentNativePolicy.toolNames + MCPServer.tools.map(\.name),
                            "toolSpecs": MCPServer.toolSpecs, "toolGuide": self.mcp?.instructions ?? "",
                            "bankProfileSupported": true, "uiScale": AppSettings.uiScale] as [String: Any]
                case "bankProfileRequest", "bankProfileSubmit", "bankProfileCancel":
                    // Only our bundled main-frame UI can call these methods; they are not model executeTool names.
                    // Session changes revoke outstanding card tokens before another save can occur.
                    return try session.perform(revision: nativeRevision) {
                        switch method {
                        case "bankProfileRequest": return try bankProfileRequests.begin(args)
                        case "bankProfileSubmit": return try bankProfileRequests.submit(args)
                        default: return try bankProfileRequests.cancel(args)
                        }
                    }
                case "request":
                    guard let path = args["path"] as? String, let payload = args["body"] as? [String: Any] else { throw AgentNativeError.invalidRequest }
                    if path == "/v1/session" || path == "/v1/memories/save" || path == "/v1/responses" {
                        guard session.isActive else { throw AgentNativeError.inactive }
                    }
                    return try server.agentRequest(endpoint: endpoint, path: path, body: payload)
                case "executeTool":
                    guard let name = args["name"] as? String, let payload = args["args"] as? [String: Any] else { throw AgentNativeError.invalidRequest }
                    return try session.perform(revision: nativeRevision) {
                        switch name {
                        case "device_status": return ["platform": "macos", "deviceLabel": "Mac", "accessibility": Permissions.accessibility,
                                                       "screenCapture": Permissions.screenCapture, "microphone": Permissions.microphone] as [String: Any]
                        case "file_list": return try workspace.list(path: payload["path"] as? String ?? "")
                        case "file_read":
                            guard let path = payload["path"] as? String else { throw AgentNativeError.invalidRequest }
                            return try workspace.read(path: path)
                        case "file_write":
                            guard let path = payload["path"] as? String, let content = payload["content"] as? String else { throw AgentNativeError.invalidRequest }
                            return try workspace.write(path: path, content: content)
                        default:
                            // Every MCP tool (phone, Windows, profiles, playbooks…) with the same gates and approval boundaries.
                            guard MCPServer.tools.contains(where: { $0.name == name }), let mcp = self.mcp else { throw AgentNativeError.invalidRequest }
                            let r = mcp.call(name, payload)
                            let text = ((r["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                            return ["text": text, "error": (r["isError"] as? Bool) ?? false] as [String: Any]
                        }
                    }
                default: throw AgentNativeError.invalidRequest
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == currentEpoch, self.pending.remove(id) != nil else { return }
                switch outcome {
                case .success(let value): self.reply(id, result: value)
                case .failure(let error): self.reply(id, error: error)
                }
            }
        }
    }

    private static let log = Logger(subsystem: "com.muilyzz.ppomi", category: "agent-bridge")
    /// The page maps unknown codes to a generic failure; known native/server categories get their own so the banner says why.
    static func bridgeCode(_ error: Error) -> String {
        if let native = error as? AgentNativeError {
            switch native {
            case .inactive: return "session_ended"
            case .invalidRequest, .invalidEndpoint: return "invalid_request"
            case .unavailable: return "native_unavailable"
            default: return "tool_failed"
            }
        }
        switch SharedServerClient.safe(error) {
        case .authentication, .permission, .deviceMismatch, .keychain: return "server_auth"
        case .unconfigured, .configuration, .privateFile: return "server_unconfigured"
        case .server: return "server_rejected"
        case .connection: return "server_unavailable"
        case .invalidResponse: return "response_invalid"
        default: return "tool_failed"
        }
    }

    private func reply(_ id: String, result: Any? = nil, error: Error? = nil) {
        var value: [String: Any] = ["id": id]
        if let error {
            let message = (error as? AgentNativeError)?.localizedDescription ?? SharedServerClient.safe(error).description
            let code = Self.bridgeCode(error)
            Self.log.error("bridge reply \(code, privacy: .public): \(message, privacy: .public)")   // fixed enum descriptions, never page or screen text
            value["error"] = ["code": code, "message": message]
        } else { value["result"] = result ?? NSNull() }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.ppomiAgentReceive?.(\(json))")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let entry, action.targetFrame?.isMainFrame == true,
              AgentNativePolicy.trusted(action.request.url, entry: entry), action.navigationType == .other else {
            if action.navigationType == .linkActivated { Self.openExternally(action.request.url) }   // 답변 속 링크는 기본 브라우저로; 페이지는 떠나지 않는다
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    /// target=_blank 링크: 새 웹뷰를 만들지 않고 기본 브라우저에 넘긴다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        Self.openExternally(navigationAction.request.url); return nil
    }
    private static func openExternally(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard type == .microphone, sessionMode == "voice", session.isActive, frame.isMainFrame, let entry,
              AgentNativePolicy.trusted(frame.request.url, entry: entry) else { decisionHandler(.deny); return }
        let currentEpoch = epoch
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self, self.epoch == currentEpoch, self.session.isActive else { decisionHandler(.deny); return }
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidateSession(); close() }
}
