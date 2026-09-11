import AppKit
import AVFoundation
import Foundation
import WebKit
import UserNotifications
import os

/// Owns a bundled or signature-verified local document. Remote pages and child frames receive no native capabilities.
@MainActor
final class AgentVoicePanel: NSObject, AgentConversationWindow, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onActive: ((Bool) -> Void)?
    /// The surface the assistant just drove (phone_* → iPhone, windows_* → Windows, android_* → Android): the workbench follows it.
    var onSurfaceHint: ((WorkSurface) -> Void)?
    /// Marks to draw over the docked window (tap rings, validated fields, reading sweep, a VLM line).
    var onOverlay: ((OverlayMark) -> Void)?
    var onClose: (() -> Void)?
    /// When this returns a host, the conversation is mounted there instead of opening its own window.
    var host: (() -> ConversationHost?)?
    /// 통화 중 사람의 말(전사). 구두 결재는 Kiosk가 차례와 맞춰 본다.
    var heard: ((String) -> Void)?
    private weak var embeddedHost: ConversationHost?
    private(set) var window: NSWindow?
    private var webView: WKWebView?
    private var entry: URL?
    private var updateReady = false
    private var bootstrapAnswered = false
    private var updateStartup: DispatchWorkItem?
    private var epoch = UUID()
    private var sessionMode = "voice"
    private let executor: AgentExecutor
    private var session: AgentNativeSession { executor.session }
    private var terminationObserver: NSObjectProtocol?
    var isVisible: Bool { window?.isVisible == true || (embeddedHost != nil && webView?.window?.isVisible == true) }
    var isEmbedded: Bool { embeddedHost != nil && webView != nil }
    var isActive: Bool { session.isActive }
    private var hostWindow: NSWindow? { window ?? webView?.window }

    init(defaults: UserDefaults = .standard, server: SharedServerClient = .shared) {
        executor = AgentExecutor(defaults: defaults, server: server, legacySurfaces: true)
        super.init()
        executor.onSessionChanged = { [weak self] active, mode in
            guard let self else { return }
            self.epoch = UUID(); self.sessionMode = mode; self.onActive?(active)
            if !active || mode == "text" { self.webView?.setMicrophoneCaptureState(.none, completionHandler: nil) }
        }
        executor.onHeard = { [weak self] text in self?.heard?(text) }
        executor.onSurfaceHint = { [weak self] surface in self?.onSurfaceHint?(surface) }
        executor.onOverlay = { [weak self] mark in self?.onOverlay?(mark) }
        executor.onEvent = { [weak self] event, payload in
            guard let self else { return }
            if event == "stop" { self.webView?.evaluateJavaScript("window.ppomiVoiceStop?.()") }
            if event == "toolProgress", let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                self.webView?.evaluateJavaScript("window.ppomiToolProgress?.(\(json))")
            }
        }
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
        let updates = FamilyUpdateRuntime.shared
        if updates.hasStartupFailure {
            let view = WorkbenchWebView(frame: frame, configuration: WKWebViewConfiguration())
            view.autoresizingMask = [.width, .height]
            view.loadHTMLString(Self.updateRecoveryHTML, baseURL: nil)
            webView = view; entry = nil
            return view
        }
        let candidate = updates.directory != nil
            ? updates.fileURL("Agent/index.html")
            : AppResources.bundle.url(forResource: "index", withExtension: "html", subdirectory: "Web/Agent")
        guard let entry = candidate else { updates.markFailed(); return nil }
        self.entry = entry
        updateReady = false
        bootstrapAnswered = false
        updates.checkInBackground()
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
                    if updates.isTrial { self.failedUpdateStartup(view); return }
                    self.window?.contentView = self.fallbackLabel("보안 설정 실패")
                    return
                }
                view.configuration.userContentController.add(rule)
                view.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
                if updates.isTrial {
                    let timeout = DispatchWorkItem { [weak self, weak view] in
                        guard let self, let view, self.webView === view, !self.updateReady, !self.session.isActive else { return }
                        self.failedUpdateStartup(view)
                    }
                    self.updateStartup = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
                }
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
        updateStartup?.cancel(); updateStartup = nil
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

    private func invalidateSession() { executor.invalidate() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ppomiAgent", message.frameInfo.isMainFrame,
              let entry, AgentNativePolicy.trusted(message.frameInfo.request.url, entry: entry),
              let body = message.body as? String, body.utf8.count <= AgentExecutorLineDecoder.limit,
              let data = body.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String, UUID(uuidString: id) != nil,
              let method = request["method"] as? String, let args = request["args"] as? [String: Any] else { return }
        if method == "updateReady" {
            guard bootstrapAnswered, !FamilyUpdateRuntime.shared.hasStartupFailure,
                  Set(args.keys) == ["bridgeVersion"], let version = args["bridgeVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else { reply(id, error: AgentNativeError.invalidRequest); return }
            updateReady = true; updateStartup?.cancel(); updateStartup = nil
            FamilyUpdateRuntime.shared.markReady()
            reply(id, result: [:] as [String: String]); return
        }
        // The embedded UI retains its visibility and trusted-method boundary after extraction.
        let methods: Set<String> = ["bootstrap", "sessionState", "heard", "declineCall", "setEndpoint", "request", "executeTool",
                                    "bankProfileRequest", "bankProfileSubmit", "bankProfileCancel"]
        guard methods.contains(method),
              !(method == "sessionState" && args["active"] as? Bool == true &&
                (!isVisible || FamilyUpdateRuntime.shared.hasStartupFailure || (FamilyUpdateRuntime.shared.isTrial && !updateReady))),
              !(method == "setEndpoint" && hostWindow?.isKeyWindow != true) else {
            reply(id, error: AgentNativeError.invalidRequest); return
        }
        executor.receive(request) { [weak self, weak originatingView = webView] reply in
            guard let self, let originatingView, self.webView === originatingView else { return }
            var reply = reply
            if method == "bootstrap", var result = reply["result"] as? [String: Any] {
                self.bootstrapAnswered = true
                result["nativeBuild"] = FamilyUpdateRuntime.nativeBuild
                result["bridgeVersion"] = FamilyUpdateRuntime.bridgeVersion
                result["webRelease"] = FamilyUpdateRuntime.shared.release
                result["capabilities"] = FamilyUpdateRuntime.capabilities.sorted()
                reply["result"] = result
            }
            self.sendReply(reply)
        }
    }

    private static let log = Logger(subsystem: "com.muilyzz.ppomi", category: "agent-bridge")
    /// Which external window a tool is about to drive, from its fixed name (never from model text).
    static func surfaceHint(for tool: String, args: [String: Any]) -> WorkSurface? {
        if tool.hasPrefix("windows_") { return .windows }
        if tool.hasPrefix("android_") { return .android }
        if tool.hasPrefix("phone_") || tool == "run_combo" || tool == "bank_profile_capture" || tool == "inbody_capture" { return .iphone }
        if tool == "profile_fill" { return ((args["form"] as? String) ?? "").hasPrefix("kb_enterprise") ? .iphone : .windows }
        if tool == "screen_inspect" { return (args["surface"] as? String) == "windows" ? .windows : .iphone }
        return nil
    }
    /// The page maps unknown codes to a generic failure; known native/server categories get their own so the banner says why.
    static func bridgeCode(_ error: Error) -> String { AgentExecutor.bridgeCode(error) }

    private func reply(_ id: String, result: Any? = nil, error: Error? = nil) {
        var value: [String: Any] = ["id": id]
        if let error {
            let message = (error as? AgentNativeError)?.localizedDescription ?? SharedServerClient.safe(error).description
            let code = Self.bridgeCode(error)
            Self.log.error("bridge reply \(code, privacy: .public): \(message, privacy: .public)")   // fixed enum descriptions, never page or screen text
            value["error"] = ["code": code, "message": message]
        } else { value["result"] = result ?? NSNull() }
        sendReply(value)
    }

    private func sendReply(_ value: [String: Any]) {
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

    private static let updateRecoveryHTML = "<!doctype html><meta charset=utf-8><p>새 화면을 열지 못했습니다. 뽀미를 종료하고 다시 열면 이전 화면으로 복구됩니다.</p>"
    private func failedUpdateStartup(_ view: WKWebView) {
        guard self.webView === view, !updateReady, !session.isActive else { return }
        FamilyUpdateRuntime.shared.markFailed()
        updateStartup?.cancel(); updateStartup = nil
        // Never replay a tool or swap a record page's assets in a running process. The next launch selects the prior release.
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ppomiAgent")
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.loadHTMLString(Self.updateRecoveryHTML, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if FamilyUpdateRuntime.shared.isTrial { failedUpdateStartup(webView) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if FamilyUpdateRuntime.shared.isTrial { failedUpdateStartup(webView) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if FamilyUpdateRuntime.shared.isTrial, !updateReady, !session.isActive { failedUpdateStartup(webView); return }
        invalidateSession(); close()
    }
}
