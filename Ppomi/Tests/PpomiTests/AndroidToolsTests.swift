import XCTest
@testable import Ppomi

final class AndroidToolsTests: XCTestCase {
    func testRoutesOnlyKnownToolsAndValidArguments() throws {
        let click = try AndroidTools.request("android_click", ["nodeId": "snapshot:3"])
        XCTAssertEqual(click.0, "click")
        XCTAssertEqual(click.1["nodeId"] as? String, "snapshot:3")
        XCTAssertEqual(try AndroidTools.request("android_type", ["nodeId": "s:1", "text": "안녕"] ).0, "type_text")
        XCTAssertEqual(try AndroidTools.request("android_key", ["name": "home"]).0, "home")
        XCTAssertThrowsError(try AndroidTools.request("android_key", ["name": "enter; rm -rf /"]))
        XCTAssertThrowsError(try AndroidTools.request("android_open", ["packageName": "com.android.vending"]))
        XCTAssertThrowsError(try AndroidTools.request("android_click", [:]))
        XCTAssertThrowsError(try AndroidTools.request("android_tap", ["x": Double.nan, "y": 12]))
        XCTAssertThrowsError(try AndroidTools.request("android_tap", ["x": true, "y": 12]))
        XCTAssertThrowsError(try AndroidTools.request("android_tap", ["x": -1, "y": 12]))
        XCTAssertNoThrow(try AndroidTools.request("android_tap", ["x": 200, "y": 900]))
        XCTAssertThrowsError(try AndroidTools.request("android_swipe", ["x1": 1, "y1": 2, "x2": 3, "y2": 4, "durationMs": 9999]))
    }

    func testConfigurationCannotSelectPhysicalDeviceOrRemoteHost() throws {
        XCTAssertNoThrow(try AndroidRuntime.Configuration(serial: "emulator-5554", port: 8765, token: String(repeating: "a", count: 43)).validate())
        XCTAssertThrowsError(try AndroidRuntime.Configuration(serial: "R123456", port: 8765, token: String(repeating: "a", count: 43)).validate())
        XCTAssertThrowsError(try AndroidRuntime.Configuration(serial: "emulator-5554", port: 80, token: "bad").validate())
        XCTAssertThrowsError(try AndroidRuntime.Configuration(serial: "emulator-5554\n-s R123", port: 8765, token: String(repeating: "a", count: 43)).validate())
    }

    func testMCPReplyValidationAndErrorPropagation() throws {
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let valid = try data(["jsonrpc": "2.0", "id": "123", "result": ["structuredContent": ["connected": true]]])
        XCTAssertEqual(try AndroidRuntime.decodeReply(valid, expectedID: "123")["connected"] as? Bool, true)
        XCTAssertThrowsError(try AndroidRuntime.decodeReply(valid, expectedID: "other"))
        let failed = try data(["jsonrpc": "2.0", "id": "123", "result": ["isError": true, "content": [["text": "Stale node"]]]])
        XCTAssertThrowsError(try AndroidRuntime.decodeReply(failed, expectedID: "123")) { error in
            XCTAssertTrue(String(describing: error).contains("Stale node"))
        }
        let invalid = try data(["jsonrpc": "2.0", "id": "123", "result": [:]])
        XCTAssertThrowsError(try AndroidRuntime.decodeReply(invalid, expectedID: "123"))
    }

    func testConsentAndScreenshotFailureDoNotIssueInputOrReuseOldImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("android-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = try Tools(db: DB(path: dir.appendingPathComponent("ledger.db").path, writable: true))
        var calls: [String] = []
        tools.androidCall = { name, _ in calls.append(name); return ["nodes": [], "packageName": "com.ppomi.androidtarget"] }
        tools.androidCapture = { throw AndroidRuntime.Failure(description: "screen unavailable") }
        tools.currentText = "오늘 날씨"
        XCTAssertTrue(tools.execute("android_click", ["nodeId": "1"]).hasPrefix("실행 안 함:"))
        XCTAssertTrue(calls.isEmpty)
        tools.lastAndroidPNG = dir.appendingPathComponent("stale.png")
        tools.currentText = "해줘"
        let screen = tools.execute("android_screen", [:])
        XCTAssertTrue(screen.contains("screenshotError"))
        XCTAssertNil(tools.lastAndroidPNG)
        XCTAssertEqual(calls, ["ui_tree"])
        let typed = tools.execute("android_type", ["nodeId": "1", "text": "한글"])
        XCTAssertFalse(typed.hasPrefix("오류:"))
        XCTAssertEqual(calls, ["ui_tree", "type_text"])
    }

    func testAndroidCallsUseExistingRuntimeVocabulary() {
        XCTAssertTrue(AndroidTools.names.isSubset(of: RuntimeEvent.allowedTools))
        XCTAssertEqual(Tools.specs.filter { $0.name.hasPrefix("android_") }.count, 8)
        XCTAssertEqual(Set(MCPServer.tools.filter { $0.name.hasPrefix("android_") }.map(\.name)), AndroidTools.names)
    }
}
