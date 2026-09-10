import XCTest
@testable import Ppomi

final class VisualToolsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-visual-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func makeTools() throws -> Tools {
        let tools = try Tools(db: DB(path: directory.appendingPathComponent("ledger.db").path, writable: true))
        tools.currentText = "해줘"
        tools.visualAssistanceEnabled = { true }
        tools.windowsGateStatus = { (true, "READY") }
        tools.phoneGateStatus = { (true, "CONNECTED") }
        tools.wakePhone = {}
        return tools
    }

    func testDisabledInvalidAndDeniedRequestsNeverCaptureOrCallModel() throws {
        let tools = try makeTools()
        tools.captureVisualScreen = { _ in XCTFail("capture must not happen"); throw NSError(domain: "test", code: 1) }
        tools.inspectVisualScreen = { _, _, _, _ in XCTFail("network must not happen"); return "" }
        tools.visualAssistanceEnabled = { false }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "windows", "question": "팝업 상태"]).hasPrefix("실행 안 함:"))
        tools.visualAssistanceEnabled = { true }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "mac", "question": "팝업 상태"]).hasPrefix("오류:"))
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "windows", "question": " "]).hasPrefix("오류:"))
        tools.windowsGateStatus = { (false, "READY") }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "windows", "question": "팝업 상태"]).contains("권한"))
        tools.windowsGateStatus = { (true, "NONE") }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "windows", "question": "팝업 상태"]).contains("창 모드"))
        tools.phoneGateStatus = { (true, "IN_USE") }
        tools.wakePhone = { throw Phone.Failure(description: "synthetic mirroring still in use") }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "phone", "question": "팝업 상태"]).hasPrefix("실행 안 함:"))
    }

    func testFreshCaptureAndDuplicateCacheDoNotAlterOriginalEvidenceOrApproval() throws {
        let tools = try makeTools()
        let png = directory.appendingPathComponent("synthetic.png")
        try Data("frame-one".utf8).write(to: png)
        let words = [OCR.Word(x: 0.1, y: 0.2, w: 0.2, h: 0.03, text: "홈")]
        tools.lastWords = words
        tools.lastPNG = directory.appendingPathComponent("original.png")
        var captures = 0, requests = 0
        tools.captureVisualScreen = { windows in
            XCTAssertTrue(windows); captures += 1
            return (png, words)
        }
        tools.inspectVisualScreen = { _, _, question, surface in
            XCTAssertEqual(surface, "windows"); XCTAssertEqual(question, "홈 버튼 위치")
            requests += 1
            return "{\"source\":\"vlm_observation\",\"state\":\"normal\"}"
        }
        let arguments = ["surface": "windows", "question": "홈 버튼 위치"]
        let first = tools.execute("screen_inspect", arguments)
        XCTAssertEqual(tools.execute("screen_inspect", arguments), first)
        XCTAssertEqual(captures, 2, "Even a cache lookup needs a current, gated capture")
        XCTAssertEqual(requests, 1, "The identical frame and question need only one paid request")
        try Data("frame-two".utf8).write(to: png)
        _ = tools.execute("screen_inspect", arguments)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(tools.lastWords.map(\.text), ["홈"])
        XCTAssertEqual(tools.lastPNG?.lastPathComponent, "original.png")
        XCTAssertNil(tools.approval)
        XCTAssertNil(tools.currentApp)
    }

    func testToolIsExposedThroughMCPAndOrdinaryScreenHasNoPaidObserver() throws {
        XCTAssertTrue(MCPServer.tools.contains { $0.name == "screen_inspect" })
        let tools = try makeTools()
        tools.currentText = "오늘 얼마 썼어?"
        tools.inspectVisualScreen = { _, _, _, _ in XCTFail("ordinary screen must not call a paid observer"); return "" }
        XCTAssertTrue(tools.execute("windows_screen", [:]).hasPrefix("실행 안 함:"))
        tools.currentText = "해줘"
        Tools.fake = (screen: { [OCR.Word(x: 0.1, y: 0.2, w: 0.2, h: 0.02, text: "홈")] }, hand: { _ in XCTFail("read only") })
        defer { Tools.fake = nil }
        XCTAssertTrue(tools.execute("windows_screen", [:]).contains("홈"))
    }
}
