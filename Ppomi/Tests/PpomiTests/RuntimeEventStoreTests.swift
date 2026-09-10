import Foundation
import XCTest
@testable import Ppomi

final class RuntimeEventStoreTests: XCTestCase {
    func testFixedVocabularyMatchesEveryExposedToolAndRejectsRawUnknownNames() throws {
        XCTAssertEqual(RuntimeEvent.allowedTools, Set((Tools.specs + MCPServer.tools).map(\.name)))
        let fixture = try Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        let unknown = RuntimeEvent(callID: UUID(), tool: "private value <script>'\"", kind: .started, method: .tool)
        XCTAssertEqual(unknown.tool, "", "Unrecognized text must not survive in an event")
        XCTAssertThrowsError(try store.append(unknown))
        XCTAssertThrowsError(try store.append(RuntimeEvent(callID: UUID(), timestamp: Date(timeIntervalSince1970: .infinity),
                                                          tool: "phone_screen", kind: .read, method: .ocr)))
        XCTAssertThrowsError(try store.append(RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .read, method: .ocr, step: -1)))
        XCTAssertEqual(try store.recent(), [])

        let columns = try DB(path: store.path).rows("PRAGMA table_info(runtime_events)").compactMap { $0[1] as? String }
        XCTAssertEqual(columns, ["seq", "id", "call_id", "timestamp", "tool", "kind", "method", "step"])
    }

    func testRoundTripPreservesSequenceAndOpaqueIDsWithoutTouchingLedgerDataVersion() throws {
        let fixture = try Fixture()
        let ledger = try DB(path: fixture.ledgerPath, writable: true)
        try ledger.insertSnapshot(ts: "2026-09-08 12:00", app: "TEST", account: "Synthetic", balance: 42, shot: "")
        let ledgerReader = try DB(path: fixture.ledgerPath)
        let before = try ledgerReader.scalar("PRAGMA data_version") as? Int
        let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        let callID = UUID()
        let events = RuntimeEvent.Kind.allCases.enumerated().map { index, kind in
            RuntimeEvent(callID: callID, timestamp: Date(timeIntervalSince1970: index < 8 ? 2 : 1),
                         tool: "run_combo", kind: kind,
                         method: RuntimeEvent.Method.allCases[index % RuntimeEvent.Method.allCases.count], step: index)
        }
        for event in events { try store.append(event) }
        try store.append(events[0])
        XCTAssertEqual(try store.recent(), events, "Duplicate IDs are idempotent; clocks do not determine execution order")
        XCTAssertEqual(try store.recent(limit: 3), Array(events.suffix(3)))
        XCTAssertEqual(try store.recent(limit: 0), [])
        XCTAssertEqual(try ledgerReader.scalar("PRAGMA data_version") as? Int, before)
        XCTAssertEqual(try ledgerReader.snapshots().map(\.balance), [42])
        let runtimeTables = try DB(path: store.path).rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0[0] as? String }
        XCTAssertEqual(Set(runtimeTables), ["runtime_events", "sqlite_sequence"])
        XCTAssertTrue(RuntimeEvent.Kind.handedOff.isTerminal)
        XCTAssertNotEqual(RuntimeEvent(callID: callID, tool: "ask_choice", kind: .handedOff, method: .human).title,
                          RuntimeEvent(callID: callID, tool: "run_combo", kind: .handedOff, method: .agent).title)
    }

    func testRetentionKeepsOnlyLast500EventsAndReadOnlyStoreCannotAppend() throws {
        let fixture = try Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        let events = (0..<507).map { RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .read, method: .ocr, step: $0) }
        for event in events { try store.append(event) }
        XCTAssertEqual(try store.recent(limit: 999), Array(events.suffix(500)))
        let reader = try RuntimeEventStore(ledgerPath: fixture.ledgerPath, writable: false)
        XCTAssertThrowsError(try reader.append(events[0]))
        XCTAssertEqual(try reader.recent().count, 120)
    }

    func testTimestampRoundTripPreservesAdjacentReferenceDateValuesExactly() throws {
        let fixture = try Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        // Adjacent native Date values share a Unix-epoch Double after addition rounds away its low bit.
        var referenceSeconds = 810_555_481.0
        let events = (0..<128).map { _ -> RuntimeEvent in
            defer { referenceSeconds = referenceSeconds.nextUp }
            return RuntimeEvent(callID: UUID(), timestamp: Date(timeIntervalSinceReferenceDate: referenceSeconds),
                                tool: "phone_screen", kind: .read, method: .ocr)
        }
        XCTAssertNotEqual(events[1].timestamp,
                          Date(timeIntervalSince1970: events[1].timestamp.timeIntervalSince1970),
                          "The fixture must exercise the lossy epoch conversion, not just whole seconds")
        for event in events { try store.append(event) }
        let loaded = try store.recent(limit: 128)
        XCTAssertEqual(loaded, events)
        XCTAssertEqual(loaded.map { $0.timestamp.timeIntervalSinceReferenceDate.bitPattern },
                       events.map { $0.timestamp.timeIntervalSinceReferenceDate.bitPattern })
    }

    func testCanonicalLedgerAliasesShareOneRuntimeStore() throws {
        let fixture = try Fixture()
        _ = try DB(path: fixture.ledgerPath, writable: true)
        let alias = fixture.directory.appendingPathComponent("alias.db").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.ledgerPath)
        let first = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        let second = try RuntimeEventStore(ledgerPath: alias)
        XCTAssertEqual(first.path, second.path)
        let event = RuntimeEvent(callID: UUID(), tool: "balances", kind: .returned, method: .storage)
        try first.append(event)
        XCTAssertEqual(try second.recent(), [event])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias + ".runtime.sqlite"))
    }

    func testReadOnlyMissingStoreIsEmptyAndCreatesNeitherDatabaseNorParent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiRuntimeMissing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerPath = directory.appendingPathComponent("nested/ledger.db").path
        let store = try RuntimeEventStore(ledgerPath: ledgerPath, writable: false)
        XCTAssertEqual(try store.recent(), [])
        XCTAssertNil(try store.dataVersion())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testConcurrentConnectionsKeepBothCallsInOneCommittedHistory() throws {
        let fixture = try Fixture()
        let firstID = UUID(), secondID = UUID()
        let results = LockedResults()
        let group = DispatchGroup()
        for callID in [firstID, secondID] {
            group.enter()
            DispatchQueue(label: "RuntimeWriter.\(callID)").async {
                defer { group.leave() }
                do {
                    let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
                    for step in 0..<25 {
                        try store.append(RuntimeEvent(callID: callID, tool: "run_combo", kind: .verified, method: .replay, step: step))
                    }
                } catch { results.append(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        let events = try RuntimeEventStore(ledgerPath: fixture.ledgerPath, writable: false).recent()
        for callID in [firstID, secondID] {
            XCTAssertEqual(events.filter { $0.callID == callID }.compactMap(\.step), Array(0..<25))
        }
    }

    func testWriterWaitsForAnotherProcessTransactionAndKeepsBothEvents() throws {
        let fixture = try Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
        let externalID = UUID(), callID = UUID()
        let process = Process(), input = Pipe()
        let ready = fixture.directory.appendingPathComponent("writer-ready")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [store.path]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let sql = """
            .timeout 1000
            BEGIN IMMEDIATE;
            INSERT INTO runtime_events(id,call_id,timestamp,tool,kind,method) VALUES('\(externalID)','\(callID)',1,'phone_screen','read','ocr');
            .once '\(ready.path)'
            SELECT 'locked';

            """
        try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
        let deadline = Date(timeIntervalSinceNow: 2)
        while (try? String(contentsOf: ready, encoding: .utf8)) != "locked\n" && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard (try? String(contentsOf: ready, encoding: .utf8)) == "locked\n" else {
            return XCTFail("External writer did not acquire its transaction")
        }

        let completed = expectation(description: "Writer commits after external transaction")
        let began = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let results = LockedResults()
        let event = RuntimeEvent(callID: callID, tool: "phone_screen", kind: .returned, method: .tool)
        DispatchQueue(label: "RuntimeExternalContention").async {
            began.signal()
            do {
                let writer = try RuntimeEventStore(ledgerPath: fixture.ledgerPath)
                try writer.append(event)
            } catch { results.append(error) }
            finished.signal()
            completed.fulfill()
        }
        XCTAssertEqual(began.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut, "The writer must wait for the external transaction")
        try input.fileHandleForWriting.write(contentsOf: Data("COMMIT;\n.quit\n".utf8))
        wait(for: [completed], timeout: 3)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(try store.recent().map(\.id), [externalID, event.id])
    }

    private final class LockedResults {
        private let lock = NSLock()
        private var values: [Swift.Error] = []
        var errors: [Swift.Error] { lock.lock(); defer { lock.unlock() }; return values }
        func append(_ error: Swift.Error) { lock.lock(); values.append(error); lock.unlock() }
    }

    private final class Fixture {
        let directory: URL
        let ledgerPath: String
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiRuntimeStore-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ledgerPath = directory.appendingPathComponent("ledger.db").path
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}
