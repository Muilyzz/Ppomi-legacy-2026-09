import XCTest
@testable import Ppomi

final class BrowserLaunchTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        Tools.fake = nil
        try FileManager.default.removeItem(at: root)
    }

    private func manifest() -> PlaybookManifest {
        .init(id: "public-web", name: "공개 웹", version: "1.0.0", aliases: ["웹 별칭"],
              launch: .init(search: "https://example.com/", target: "browser"),
              capabilities: [.init(id: "browse", title: "조회", description: "공개 웹 조회", inputs: [],
                                   steps: [.init(id: "open", title: "열기", kind: "open")])], humanSteps: [], guide: "guide.md")
    }

    private func tools() throws -> Tools {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest()).write(to: source.appendingPathComponent("manifest.json"))
        try "# 공개 웹".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let tools = try Tools(db: DB(path: root.appendingPathComponent("ledger.db").path, writable: true))
        tools.footprintDir = root.appendingPathComponent("playbooks")
        _ = try PlaybookCatalog.install(from: source, in: tools.footprintDir)
        return tools
    }

    func testLegacyLaunchDecodesWithoutChangingItsRoute() throws {
        let launch = try JSONDecoder().decode(PlaybookManifest.Launch.self, from: Data(#"{"search":"kb"}"#.utf8))
        XCTAssertEqual(launch.search, "kb")
        XCTAssertNil(launch.target)
        XCTAssertFalse(launch.isBrowser)
        XCTAssertNil(launch.browserURL)
        var value = manifest(); value.launch = launch
        XCTAssertNoThrow(try PlaybookCatalog.validate(value))
    }

    func testBrowserManifestAcceptsOnlyCredentialFreeWebURLsAndNoPhoneCollector() throws {
        XCTAssertNoThrow(try PlaybookCatalog.validate(manifest()))
        for search in ["sample", "file:///tmp/a", "javascript:alert(1)", "https://", "https://user:secret@example.com/",
                       "https://@example.com/", "https://example.com/\n", "https://example.com/a b", "https:example.com", "https:\\example.com"] {
            var value = manifest(); value.launch.search = search
            XCTAssertThrowsError(try PlaybookCatalog.validate(value), search)
        }
        var value = manifest(); value.launch.target = "shell"
        XCTAssertThrowsError(try PlaybookCatalog.validate(value))
        value = manifest(); value.collection = .init(key: "PUBLIC_WEB", account: "계좌")
        XCTAssertThrowsError(try PlaybookCatalog.validate(value))
    }

    func testBrowserOpenUsesManifestAndLeavesPhoneRecordingUntouched() throws {
        let tool = try tools()
        var opened: [URL] = []
        tool.openBrowser = { opened.append($0) }
        tool.currentApp = "existing-phone"
        Tools.fake = (screen: { XCTFail("browser navigation must not capture the phone"); return [] },
                      hand: { _ in XCTFail("browser navigation must not drive a phone or Windows window") })
        XCTAssertTrue(tool.execute("browser_open", ["app": "웹 별칭"]).hasPrefix("Mac의 Google Chrome에 열었다"))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/"])
        XCTAssertEqual(tool.currentApp, "existing-phone")
        XCTAssertTrue(FootprintStore.load("public-web", in: tool.footprintDir).isEmpty)
        XCTAssertNil(try tool.db.state("installed:public-web"))
        XCTAssertTrue(tool.execute("phone_open", ["app": "public-web"]).contains("browser_open"))
        XCTAssertTrue(tool.execute("phone_installed", ["names": "public-web"]).contains("browser_open"))
        tool.lastPNG = URL(fileURLWithPath: "/tmp/stale.png")
        XCTAssertTrue(tool.execute("run_combo", ["app": "public-web"]).contains("browser_open"))
        XCTAssertNil(tool.lastPNG)
        XCTAssertEqual(tool.currentApp, "existing-phone")
    }

    func testBrowserOpenRejectsBadRoutesAndReportsActionableFailures() throws {
        let tool = try tools()
        tool.openBrowser = { _ in XCTFail("invalid routes must not open") }
        for args in [["url": "javascript:alert(1)"], ["url": "https://user:secret@example.com/"], ["app": "missing"], [:]] {
            XCTAssertTrue(tool.execute("browser_open", args).hasPrefix("오류:"))
        }
        tool.openBrowser = { _ in throw MacBrowser.Failure.chromeMissing }
        let result = tool.execute("browser_open", ["app": "public-web"])
        XCTAssertTrue(result.contains("Chrome을 설치"), result)
        XCTAssertTrue(MCPServer.tools.contains { $0.name == "browser_open" })
        for name in ["screen_read", "ui_tap", "ui_type"] {
            XCTAssertTrue(MCPServer.tools.contains { $0.name == name }, name)
        }
        XCTAssertEqual(try MacBrowser.bundleID(for: "safari"), "com.apple.Safari")
        XCTAssertEqual(try MacBrowser.displayName(for: "safari"), "Safari")
    }

    func testWindowsOpenRemainsAnExplicitFallbackForBrowserPackages() throws {
        let tool = try tools()
        tool.currentText = "해줘"
        var hands: [[String]] = []
        Tools.fake = (screen: { [] }, hand: { hands.append($0) })
        XCTAssertTrue(tool.execute("windows_open", ["app": "public-web"]).hasPrefix("열었다"))
        XCTAssertEqual(hands, [["open", "https://example.com/"]])
        XCTAssertNil(tool.currentApp)
    }
}
