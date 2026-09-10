import AppKit
import WebKit
import XCTest
@testable import Ppomi

@MainActor
final class AgentVoiceWebTests: XCTestCase {
    /// This loads the real build but never requests microphone permission, auth, or a model response.
    func testBundledVoicePageHasSecureWebRTCCapabilitiesWithoutCapturingAudio() async throws {
        let entry = try XCTUnwrap(AppResources.bundle.url(forResource: "index", withExtension: "html", subdirectory: "Web/Agent"))
        let loaded = expectation(description: "Bundled voice UI loads")
        let bootstrapped = expectation(description: "Shared UI uses native bridge")
        let delegate = Probe(loaded: loaded, bootstrapped: bootstrapped)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(delegate, name: "ppomiAgent")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        view.navigationDelegate = delegate; delegate.view = view
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "ppomiAgent")
            view.navigationDelegate = nil
            view.stopLoading(); view.loadHTMLString("", baseURL: nil)
        }
        view.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        await fulfillment(of: [loaded, bootstrapped], timeout: 15)
        let evaluated = try await view.evaluateJavaScript("""
            ({secure:window.isSecureContext,media:typeof navigator.mediaDevices?.getUserMedia==='function',
              rtc:typeof RTCPeerConnection==='function',rendered:document.querySelector('#root').childElementCount>0,
              stop:typeof window.ppomiVoiceStop==='function',textInputs:document.querySelectorAll('textarea').length})
            """) as? [String: Any]
        let value = try XCTUnwrap(evaluated)
        XCTAssertEqual(value["secure"] as? Bool, true)
        XCTAssertEqual(value["media"] as? Bool, true)
        XCTAssertEqual(value["rtc"] as? Bool, true)
        XCTAssertEqual(value["rendered"] as? Bool, true)
        XCTAssertEqual(value["stop"] as? Bool, true)
        XCTAssertEqual(value["textInputs"] as? Int, 1)
        XCTAssertEqual(delegate.methods, ["bootstrap"])
    }

    private final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let loaded: XCTestExpectation, bootstrapped: XCTestExpectation
        weak var view: WKWebView?
        var methods = [String]()
        init(loaded: XCTestExpectation, bootstrapped: XCTestExpectation) { self.loaded = loaded; self.bootstrapped = bootstrapped }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let raw = message.body as? String, let data = raw.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = body["id"] as? String, let method = body["method"] as? String else { XCTFail("Invalid bridge request"); return }
            methods.append(method)
            guard method == "bootstrap" else { XCTFail("Idle voice UI must not start audio or requests"); return }
            let reply: [String: Any] = ["id": id, "result": ["platform": "macos", "deviceLabel": "Synthetic Mac", "configured": false,
                                                                   "endpoint": "", "tools": AgentNativePolicy.toolNames]]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
            view?.evaluateJavaScript("window.ppomiAgentReceive(\(json))") { [weak self] _, error in
                XCTAssertNil(error); self?.bootstrapped.fulfill()
            }
        }
    }
}
