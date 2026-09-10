import WebKit
import XCTest
@testable import Ppomi

@MainActor
final class WebFontTests: XCTestCase {
    /// The bundled Pretendard really loads inside our pages: tokens.css @font-face resolves through WebFiles.
    func testBundledPretendardLoadsInsideWebPages() async throws {
        let cfg = WebPage.configuration()
        cfg.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        let loaded = expectation(description: "timeline page loads")
        let probe = Probe(loaded: loaded)
        view.navigationDelegate = probe
        defer { view.navigationDelegate = nil; view.stopLoading() }
        view.loadHTMLString(Web.page("timeline"), baseURL: WebFiles.base)
        await fulfillment(of: [loaded], timeout: 10)

        // callAsyncJavaScript never calls back inside swift test, so the promise result is parked on window and polled.
        _ = try await view.evaluateJavaScript("""
            document.fonts.ready.then(() => document.fonts.load('14px "Pretendard Variable"', '뽀미')).then(faces => {
                window.ppomiFonts = {check: document.fonts.check('14px "Pretendard Variable"', '뽀미'),
                                     loaded: faces.filter(f => f.status === 'loaded').length}
            }, e => { window.ppomiFonts = {error: String(e)} }); 0
            """)
        var fonts: [String: Any]?
        for _ in 0..<100 where fonts == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            fonts = try await view.evaluateJavaScript("window.ppomiFonts || null") as? [String: Any]
        }
        XCTAssertEqual(fonts?["check"] as? Bool, true, "\(fonts ?? [:])")
        XCTAssertEqual(fonts?["loaded"] as? Int, 1, "@font-face must resolve ./Agent/fonts/PretendardVariable.woff2 via WebFiles")
        let family = try await view.evaluateJavaScript("getComputedStyle(document.body).fontFamily") as? String
        XCTAssertTrue(family?.hasPrefix("\"Pretendard Variable\"") == true, family ?? "nil")
    }

    private final class Probe: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }
}
