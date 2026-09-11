import XCTest
@testable import Ppomi

final class AgentExecutorFramingTests: XCTestCase {
    func testChildAnswersWhileStdinRemainsOpenAndStdoutContainsOnlyJSONL() async throws {
        let executable = Bundle(for: AgentExecutorFramingTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Ppomi")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { XCTFail("Missing built executor at \(executable.path)"); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-executor-pipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = ["--executor"]
        var environment = ProcessInfo.processInfo.environment
        environment["PPOMI_DB"] = root.appendingPathComponent("ledger.db").path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let replied = expectation(description: "status before EOF"), exited = expectation(description: "EOF ends child")
        let id = UUID().uuidString
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in data.split(separator: 10) {
                guard let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    XCTFail("Non-JSON stdout"); continue
                }
                if reply["id"] as? String == id {
                    let result = reply["result"] as? [String: Any]
                    XCTAssertEqual(result?["platform"] as? String, "macos")
                    XCTAssertEqual(result?["active"] as? Bool, false)
                    replied.fulfill()
                }
            }
        }
        process.terminationHandler = { _ in exited.fulfill() }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        try process.run()
        var request = try JSONSerialization.data(withJSONObject: ["id": id, "method": "executorStatus", "args": [:]] as [String: Any])
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(process.isRunning)
        try input.fileHandleForWriting.close()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testSplitFramesAndOversizeRecovery() {
        var decoder = AgentExecutorLineDecoder()
        XCTAssertTrue(decoder.append(Data("{\"id\":".utf8)).isEmpty)
        let first = decoder.append(Data("1}\n\n".utf8))
        XCTAssertEqual(first.count, 1)
        if case .line(let data) = first.first { XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"id\":1}") }
        else { XCTFail("missing split frame") }
        let rejected = decoder.append(Data(repeating: 65, count: AgentExecutorLineDecoder.limit + 100))
        XCTAssertEqual(rejected.count, 1)
        if case .oversized = rejected.first {} else { XCTFail("oversized line must be rejected") }
        let recovered = decoder.append(Data("discard\n{}\n".utf8))
        XCTAssertEqual(recovered.count, 1)
        if case .line(let data) = recovered.first { XCTAssertEqual(data, Data("{}".utf8)) }
        else { XCTFail("failed to recover after oversized line") }
        XCTAssertTrue(decoder.append(Data("{}".utf8)).isEmpty)
        XCTAssertEqual(decoder.finish().count, 1)
        XCTAssertTrue(decoder.finish().isEmpty)
    }
}

final class AgentExecutorApprovalTests: XCTestCase {
    func testOnlyCurrentExplicitOptionResolvesApproval() throws {
        let approval = AgentExecutorApproval(), revision = UUID()
        approval.reset(revision: revision)
        let offered = expectation(description: "question offered"), finished = expectation(description: "answer resolved")
        approval.onChange = { if approval.current != nil { offered.fulfill() } }
        DispatchQueue.global().async {
            XCTAssertEqual(approval.ask("<b>선택</b>", options: ["승인", "취소"], revision: revision, timeout: 3), "승인")
            finished.fulfill()
        }
        wait(for: [offered], timeout: 2)
        let current = try XCTUnwrap(approval.current)
        XCTAssertEqual(current.text, "선택")
        XCTAssertThrowsError(try approval.respond(id: UUID().uuidString, choice: "승인"))
        XCTAssertThrowsError(try approval.respond(id: current.id, choice: "model-approved"))
        try approval.respond(id: current.id, choice: "승인")
        wait(for: [finished], timeout: 2)
        XCTAssertNil(approval.current)
        XCTAssertThrowsError(try approval.respond(id: current.id, choice: "승인"))
    }

    func testSessionReplacementRevokesWaiterAndOldToolCannotAskAgain() throws {
        let approval = AgentExecutorApproval(), revision = UUID()
        approval.reset(revision: revision)
        let offered = expectation(description: "question offered"), finished = expectation(description: "wait cancelled")
        approval.onChange = { if approval.current != nil { offered.fulfill() } }
        DispatchQueue.global().async {
            XCTAssertNil(approval.ask("기다릴 작업", options: ["승인", "취소"], revision: revision, timeout: 30))
            finished.fulfill()
        }
        wait(for: [offered], timeout: 2)
        let old = try XCTUnwrap(approval.current)
        approval.reset(revision: UUID())
        wait(for: [finished], timeout: 2)
        XCTAssertNil(approval.ask("이전 작업", options: ["승인"], revision: revision, timeout: 0))
        XCTAssertThrowsError(try approval.respond(id: old.id, choice: "승인"))
    }
}

@MainActor
final class AgentExecutorTests: XCTestCase {
    private func call(_ executor: AgentExecutor, _ method: String, _ args: [String: Any] = [:]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            executor.receive(["id": UUID().uuidString, "method": method, "args": args]) { continuation.resume(returning: $0) }
        }
    }

    func testSameExecutorRunsWorkspaceToolsAndRefusesLegacyOrUIActionsAsTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-executor-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = AgentExecutor(workspace: AgentWorkspace(root: root), mcp: nil, configured: { false })
        let bootstrap = await call(executor, "bootstrap")
        let body = try XCTUnwrap(bootstrap["result"] as? [String: Any])
        XCTAssertEqual(body["tools"] as? [String], AgentNativePolicy.toolNames)
        XCTAssertEqual(body["configured"] as? Bool, false)
        let inactive = await call(executor, "executeTool", ["name": "file_write", "args": ["path": "note.txt", "content": "test"]])
        XCTAssertEqual((inactive["error"] as? [String: String])?["code"], "session_ended")
        _ = await call(executor, "sessionState", ["active": true, "mode": "text"])
        let saved = await call(executor, "executeTool", ["name": "file_write", "args": ["path": "note.txt", "content": "test"]])
        XCTAssertEqual((saved["result"] as? [String: Any])?["verified"] as? Bool, true)
        for name in ["windows_click", "phone_tap", "android_click", "run_combo", "answerApproval", "configureDevice"] {
            let rejected = await call(executor, "executeTool", ["name": name, "args": [:]])
            XCTAssertEqual((rejected["error"] as? [String: String])?["code"], "invalid_request", name)
        }
        let stop = await call(executor, "sessionState", ["active": false, "mode": "text"])
        XCTAssertEqual((stop["result"] as? [String: Any])?["active"] as? Bool, false)
        XCTAssertNil(executor.status()["approval"] as? [String: Any])
    }

    func testStopRepliesWithoutWaitingForBlockedProxyAndDiscardsLateResult() async throws {
        let entered = expectation(description: "proxy entered"), cancelled = expectation(description: "pending reply cancelled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let config = SharedServerConfiguration(url: "https://abcdefghijklmnopqrst.supabase.co", publishableKey: "sb_publishable_synthetic123456789",
                                               email: "synthetic@example.invalid", password: "synthetic-password", deviceId: UUID().uuidString)
        let server = SharedServerClient(configuration: { config }) { _ in
            entered.fulfill(); release.wait()
            throw AgentNativeError.inactive
        }
        let suite = "ppomi-executor-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://agent.example.invalid", forKey: AgentNativePolicy.endpointPreference)
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = AgentExecutor(defaults: defaults, server: server, mcp: nil, configured: { true })
        _ = await call(executor, "sessionState", ["active": true, "mode": "text"])
        var callbacks = 0
        executor.receive(["id": UUID().uuidString, "method": "request", "args": ["path": "/v1/responses", "body": [:]]]) { reply in
            callbacks += 1
            XCTAssertEqual((reply["error"] as? [String: String])?["code"], "session_ended")
            cancelled.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        let stopped = await call(executor, "sessionState", ["active": false, "mode": "text"])
        XCTAssertEqual((stopped["result"] as? [String: Any])?["active"] as? Bool, false)
        await fulfillment(of: [cancelled], timeout: 2)
        release.signal()
        // A fresh bootstrap uses an independent queue, even while the previous proxy unwinds.
        let bootstrap = await call(executor, "bootstrap")
        XCTAssertNotNil(bootstrap["result"])
        XCTAssertEqual(callbacks, 1)
    }

    func testMCPApprovalUsesExecutorUIAndStopCancelsInFlightTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-executor-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mcp = try MCPServer(dbPath: root.appendingPathComponent("ledger.db").path, fd: -1)
        let executor = AgentExecutor(workspace: AgentWorkspace(root: root.appendingPathComponent("files")), mcp: mcp, configured: { false })
        let offered = expectation(description: "approval notice"), cancelled = expectation(description: "tool cancelled")
        executor.onEvent = { event, _ in if event == "notice" { offered.fulfill() } }
        _ = await call(executor, "sessionState", ["active": true, "mode": "text"])
        executor.receive(["id": UUID().uuidString, "method": "executeTool",
                          "args": ["name": "ask_choice", "args": ["question": "Synthetic selection", "options": "[\"A\",\"B\"]"]]]) { reply in
            XCTAssertEqual((reply["error"] as? [String: String])?["code"], "session_ended")
            cancelled.fulfill()
        }
        await fulfillment(of: [offered], timeout: 2)
        let status = await call(executor, "executorStatus")
        let approval = try XCTUnwrap((status["result"] as? [String: Any])?["approval"] as? [String: Any])
        XCTAssertEqual(approval["options"] as? [String], ["A", "B"])
        _ = await call(executor, "sessionState", ["active": false, "mode": "text"])
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(executor.status()["approval"] as? [String: Any])
        let stale = await call(executor, "answerApproval", ["id": approval["id"]!, "choice": "A"])
        XCTAssertNotNil(stale["error"])
    }

    func testAccountProcessExcludesSessionsAndDuplicateWindowsUntilItExits() async throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var launches = 0
        let executor = AgentExecutor(mcp: nil, configured: { false }, managementProcess: { method in
            XCTAssertEqual(method, "openAccount"); launches += 1; return process
        })
        defer { if process.isRunning { process.terminate() } }
        _ = await call(executor, "sessionState", ["active": true, "mode": "text"])
        let activeReject = await call(executor, "openAccount")
        XCTAssertNotNil(activeReject["error"])
        XCTAssertEqual(launches, 0)
        _ = await call(executor, "sessionState", ["active": false, "mode": "text"])
        let opened = await call(executor, "openAccount")
        XCTAssertEqual((opened["result"] as? [String: Any])?["opened"] as? Bool, true)
        XCTAssertTrue(executor.isAccountWindowOpen)
        for (method, args) in [("openAccount", [:]), ("sessionState", ["active": true, "mode": "text"]),
                               ("sessionState", ["active": true, "mode": "voice"])] as [(String, [String: Any])] {
            let rejected = await call(executor, method, args)
            XCTAssertEqual((rejected["error"] as? [String: String])?["code"], "account_window_open")
        }
        XCTAssertEqual(launches, 1)
        XCTAssertFalse(executor.isActive)
        _ = await call(executor, "sessionState", ["active": false, "mode": "text"])
        XCTAssertTrue(executor.isAccountWindowOpen) // a UI stop must not remove the account lock
        try input.fileHandleForWriting.close()
        for _ in 0..<100 {
            if !executor.isAccountWindowOpen { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(executor.isAccountWindowOpen)
        let started = await call(executor, "sessionState", ["active": true, "mode": "text"])
        XCTAssertEqual((started["result"] as? [String: Any])?["active"] as? Bool, true)
        executor.invalidate()
    }

    func testFailedAccountLaunchDoesNotPermanentlyLockConversation() async {
        let executor = AgentExecutor(mcp: nil, configured: { false }, managementProcess: { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/nonexistent/ppomi-account-test")
            return process
        })
        let failed = await call(executor, "openAccount")
        XCTAssertNotNil(failed["error"])
        XCTAssertFalse(executor.isAccountWindowOpen)
        let started = await call(executor, "sessionState", ["active": true, "mode": "text"])
        XCTAssertEqual((started["result"] as? [String: Any])?["active"] as? Bool, true)
        executor.invalidate()
    }
}
