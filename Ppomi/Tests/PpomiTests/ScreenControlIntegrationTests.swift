import Foundation
import XCTest
@testable import Ppomi

final class ScreenControlIntegrationTests: XCTestCase {
    private var directory: URL!
    private var ledgerPath: String { directory.appendingPathComponent("ledger.db").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiFocusTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Tools.fake = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func makeTools() throws -> Tools {
        let tools = try Tools(db: DB(path: ledgerPath, writable: true))
        tools.currentText = "해줘"
        return tools
    }

    func testFocusRefusesToolsBeforeCallbacksCapturesAndHands() throws {
        let tools = try makeTools()
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        var callbacks: [String] = [], events: [RuntimeEvent] = []
        tools.onTool = { callbacks.append($0) }
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        Tools.fake = (screen: { XCTFail("No screen capture while focused"); return [] },
                      hand: { _ in XCTFail("No hand movement while focused") })
        tools.openBrowser = { _ in XCTFail("No browser activation while focused") }
        tools.androidCall = { _, _ in XCTFail("No Android call while focused"); return [:] }
        tools.androidCapture = { XCTFail("No Android capture while focused"); return self.directory }
        tools.captureInBody = { _ in XCTFail("No InBody capture while focused"); return "" }
        tools.phoneGateStatus = { XCTFail("No phone permission or state lookup while focused"); return (true, "CONNECTED") }
        tools.windowsGateStatus = { XCTFail("No Windows state lookup while focused"); return (true, "READY") }
        tools.lastPNG = directory.appendingPathComponent("previous.png")
        tools.lastAndroidPNG = directory.appendingPathComponent("previous-android.png")
        for name in ["phone_screen", "phone_tap", "phone_installed", "windows_screen", "windows_type",
                     "android_screen", "android_click", "browser_open", "run_combo", "screen_inspect",
                     "inbody_capture", "profile_fill", "collect_now"] {
            events = []
            XCTAssertEqual(tools.execute(name, [:]), ScreenControlLease.blockedMessage, name)
            XCTAssertEqual(events.map(\.kind), [.started, .blocked], name)
        }
        XCTAssertEqual(tools.screenForMCP().text, ScreenControlLease.blockedMessage)
        XCTAssertNil(tools.screenForMCP().png, "Refusal must not resend a previous phone screenshot")
        XCTAssertNil(tools.screenForMCP(windows: true).png, "Refusal must not resend a previous Windows screenshot")
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testLeaseCoversCallbackAndScreenCaptureThenAllowsFocus() throws {
        let tools = try makeTools()
        var callbackCount = 0, captureCount = 0
        tools.onTool = { _ in
            callbackCount += 1
            do {
                let focus = try ScreenControlLease.beginFocus(ledgerPath: self.ledgerPath)
                XCTAssertNil(focus, "Window callbacks must run inside the shared lease")
            } catch { XCTFail("Could not probe the callback's lock: \(error)") }
        }
        Tools.fake = (screen: {
            captureCount += 1
            XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: self.ledgerPath))
            return []
        }, hand: { _ in XCTFail("A screen read has no hand movement") })
        XCTAssertEqual(tools.screenForMCP().text, "")
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(captureCount, 1)
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        XCTAssertEqual(tools.execute("phone_screen", [:]), ScreenControlLease.blockedMessage)
    }

    func testRecordsAndConnectionStatusRemainAvailableInFocus() throws {
        let tools = try makeTools()
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        var callbacks: [String] = []
        tools.onTool = { callbacks.append($0) }
        tools.androidCall = { method, _ in
            XCTAssertEqual(method, "status")
            return ["connected": true]
        }
        for name in ["today_spending", "balances", "accounting_template", "android_status"] {
            let result = tools.execute(name, [:])
            XCTAssertFalse(result.hasPrefix("실행 안 함:"), name)
            XCTAssertFalse(result.hasPrefix("오류:"), name)
        }
        XCTAssertEqual(callbacks, ["today_spending", "balances", "accounting_template", "android_status"])
    }

    func testMissingOrInvalidLockFailsClosedOnlyForScreenTools() throws {
        let memory = try Tools(db: DB(path: ":memory:", writable: true))
        var callbacks: [String] = []
        memory.onTool = { callbacks.append($0) }
        memory.openBrowser = { _ in XCTFail("In-memory stores cannot coordinate real screen tools") }
        XCTAssertTrue(memory.execute("browser_open", ["url": "https://example.com"]).hasPrefix("실행 안 함:"))
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertFalse(memory.execute("balances", [:]).hasPrefix("실행 안 함:"))

        let tools = try makeTools()
        let untouched = directory.appendingPathComponent("untouched.txt")
        try Data("untouched".utf8).write(to: untouched)
        try FileManager.default.createSymbolicLink(atPath: ScreenControlLease.path(for: ledgerPath), withDestinationPath: untouched.path)
        tools.onTool = { _ in XCTFail("Lock failure must precede window callbacks") }
        tools.openBrowser = { _ in XCTFail("Lock failure must precede browser activation") }
        XCTAssertTrue(tools.execute("browser_open", ["url": "https://example.com"]).hasPrefix("실행 안 함:"))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "untouched")
    }

    func testDirectCollectorHoldsTheSameLeaseBeforeItsPhoneSession() throws {
        var logs: [String] = [], sessions = 0
        let collector = try Collector(dbPath: ledgerPath, log: { logs.append($0) })
        collector.phoneSessionOverride = { _ in
            sessions += 1
            do {
                let focus = try ScreenControlLease.beginFocus(ledgerPath: self.ledgerPath)
                XCTAssertNil(focus)
            } catch { XCTFail("Could not probe the collector's lock: \(error)") }
            // Do not run the body: this test never reads or navigates a bank app.
        }
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        collector.snapshot(["KAKAO"])
        XCTAssertEqual(logs, [ScreenControlLease.blockedMessage])
        XCTAssertEqual(sessions, 0)
        focus.release()
        collector.snapshot(["KAKAO"])
        XCTAssertEqual(sessions, 1)
        let restored = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        restored.release()
    }

    func testStdioReturnsFocusedRefusalsAsErrorsAndStillServesRecords() throws {
        _ = try DB(path: ledgerPath, writable: true)
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        // Use this test bundle's build products, including when swift test uses --scratch-path.
        let executable = Bundle(for: ScreenControlIntegrationTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("Ppomi")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.arguments = ["--mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["PPOMI_DB"] = ledgerPath
        child.environment = environment
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        let exited = expectation(description: "MCP completes refused calls and a ledger read")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        // Empty arguments are also invalid before any real UI operation if the focus gate regresses.
        let names = ["browser_open", "phone_open", "windows_open", "android_open", "screen_inspect", "today_spending"]
        for (id, name) in names.enumerated() {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                          "method": "tools/call", "params": ["name": name, "arguments": [:]]]
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 10)
        guard !child.isRunning else { return XCTFail("MCP failed to drain its requests") }
        XCTAssertEqual(child.terminationStatus, 0)
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: 10)
        XCTAssertEqual(lines.count, names.count)
        for line in lines {
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            let id = try XCTUnwrap(reply["id"] as? Int)
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertFalse(content.contains { $0["type"] as? String == "image" })
            if id < names.count - 1 {
                XCTAssertEqual(result["isError"] as? Bool, true, names[id])
                XCTAssertEqual(content.first?["text"] as? String, ScreenControlLease.blockedMessage, names[id])
            } else {
                XCTAssertNil(result["isError"])
            }
        }
    }
}
