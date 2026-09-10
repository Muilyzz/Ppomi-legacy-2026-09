import Foundation
import XCTest
@testable import Ppomi

final class MCPRuntimeIntegrationTests: XCTestCase {
    func testStdioCallsPublishOneSpanAndKeepArgumentsOutOfRuntimeStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-mcp-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appendingPathComponent("ledger.db").path
        let executable = Bundle(for: MCPRuntimeIntegrationTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("Ppomi")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = ["--mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["PPOMI_DB"] = ledger
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = expectation(description: "stdio server drained calls")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let sentinel = "PRIVATE-RUNTIME-ARGUMENT-\(UUID())"
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "sql", "arguments": ["query": "SELECT '\(sentinel)' AS sample"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "screen_inspect", "arguments": ["surface": "invalid", "question": sentinel]]]
        ]
        for request in requests {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 10)
        guard !process.isRunning else { return XCTFail("stdio server did not stop") }
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: 10)
        let replies = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        XCTAssertEqual(replies.compactMap { $0?["id"] as? Int }, [1, 2])
        let events = try RuntimeEventStore(ledgerPath: ledger, writable: false).recent()
        let sql = events.filter { $0.tool == "sql" }
        XCTAssertEqual(Set(sql.map(\.callID)).count, 1)
        XCTAssertEqual(sql.filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(sql.last?.kind, .returned)
        XCTAssertFalse(sql.contains { $0.kind == .verified }, "Returning a query is not verified workflow completion")
        let visual = events.filter { $0.tool == "screen_inspect" }
        XCTAssertEqual(Set(visual.map(\.callID)).count, 1, "MCP and Tools must share one call")
        XCTAssertEqual(visual.filter { $0.kind == .started }.count, 1)
        XCTAssertTrue([RuntimeEvent.Kind.failed, .blocked].contains(try XCTUnwrap(visual.last?.kind)))
        XCTAssertFalse(visual.contains { $0.kind == .observing })
        XCTAssertFalse(events.contains { [$0.tool, $0.toolTitle, $0.title, $0.detail].joined().contains(sentinel) })
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.contains("runtime") {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(sentinel))
        }
    }
}
