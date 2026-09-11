import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import Ppomi

@MainActor final class FamilyUpdateWebTests: XCTestCase {
    /// The production JS/CSS is signed, staged, activated, and loaded from the downloaded-file location.
    /// The synthetic host supplies no account, microphone, model endpoint, or executable native tools.
    func testSignedProductionScreenConfirmsTrialAfterBootstrapWithoutStartingSession() async throws {
        let bundled = AppResources.bundle.resourceURL!.appendingPathComponent("Web")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: bundled, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [[String: String]] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(bundled.path.count + 1))
            guard FamilyUpdatePackage.safePath(path) else { continue }
            let bytes = try Data(contentsOf: url)
            files.append(["path": path, "sha256": FamilyUpdatePackage.hash(bytes), "data": bytes.base64EncodedString()])
        }
        let catalog = Data("{}".utf8)
        files.append(["path": "playbooks.json", "sha256": FamilyUpdatePackage.hash(catalog), "data": catalog.base64EncodedString()])
        let key = P256.Signing.PrivateKey()
        let config = try FamilyUpdateConfiguration.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "endpoint": "https://updates.example.test/preview/macos.json", "channel": "preview", "publicKey": key.publicKey.x963Representation.base64EncodedString()
        ]))
        let payload = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "release": "web-test", "sequence": 1,
            "channel": "preview", "platform": "macos", "bridgeVersion": 1, "minNativeBuild": 1,
            "capabilities": ["agent.v1", "records.v1"], "files": files])
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).derRepresentation.base64EncodedString()])
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("family-web-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FamilyUpdateStore(root: root, configuration: config, platform: "macos", capabilities: ["agent.v1", "records.v1"])
        try first.beginLaunch(); try first.stage(envelope)
        let trial = FamilyUpdateStore(root: root, configuration: config, platform: "macos", capabilities: ["agent.v1", "records.v1"])
        try trial.beginLaunch(); XCTAssertTrue(trial.isTrial)
        let entry = try XCTUnwrap(trial.selected).appendingPathComponent("Agent/index.html")
        let ready = expectation(description: "signed UI rendered and acknowledged")
        let probe = Probe(entry: entry, store: trial, ready: ready)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(probe, name: "ppomiAgent")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: configuration)
        probe.view = view
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "ppomiAgent"); view.stopLoading() }
        view.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        await fulfillment(of: [ready], timeout: 15)
        XCTAssertEqual(probe.methods, ["bootstrap", "updateReady"])
        XCTAssertFalse(trial.isTrial)
        let rendered = try await view.evaluateJavaScript("document.querySelectorAll('textarea').length") as? Int
        XCTAssertEqual(rendered, 1)
    }
    private final class Probe: NSObject, WKScriptMessageHandler {
        let entry: URL, store: FamilyUpdateStore, ready: XCTestExpectation
        weak var view: WKWebView?
        var methods: [String] = []
        init(entry: URL, store: FamilyUpdateStore, ready: XCTestExpectation) { self.entry = entry; self.store = store; self.ready = ready }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, AgentNativePolicy.trusted(message.frameInfo.request.url, entry: entry),
                  let raw = message.body as? String, let body = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let id = body["id"] as? String, let method = body["method"] as? String else { XCTFail("Invalid update bridge message"); return }
            methods.append(method)
            var result: [String: Any] = [:]
            if method == "bootstrap" {
                XCTAssertTrue(store.isTrial)
                result = ["platform": "macos", "deviceLabel": "Synthetic Mac", "configured": false, "endpoint": "", "tools": [],
                          "nativeBuild": 1, "bridgeVersion": 1, "webRelease": "web-test", "capabilities": ["agent.v1", "records.v1"]]
            } else if method == "updateReady" {
                XCTAssertEqual(methods, ["bootstrap", "updateReady"])
                XCTAssertEqual((body["args"] as? [String: Int])?["bridgeVersion"], 1)
                XCTAssertNoThrow(try store.markReady())
            } else { XCTFail("An idle signed screen must not start a session or tool"); return }
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": id, "result": result]), as: UTF8.self)
            view?.evaluateJavaScript("window.ppomiAgentReceive(\(json))") { [weak self] _, error in
                XCTAssertNil(error)
                if method == "updateReady" { self?.ready.fulfill() }
            }
        }
    }
}
