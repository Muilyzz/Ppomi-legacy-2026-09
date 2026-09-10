import Foundation
import XCTest
@testable import Ppomi

final class LedgerMonitorTests: XCTestCase {
    func testPersistentReaderOnlyReturnsCommittedLedgerChanges() throws {
        let fixture = try Fixture(balance: 100)
        let reader = LedgerChangeReader(dbPath: fixture.path, me: "Synthetic")
        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 100)
        XCTAssertNil(try reader.poll())

        try fixture.writer.setState("ask:pending", "unrelated state")
        XCTAssertNil(try reader.poll(), "Approval state commits must not redraw financial values")

        try fixture.writer.run("BEGIN IMMEDIATE TRANSACTION")
        try fixture.snapshot(balance: 250, minute: "01")
        XCTAssertNil(try reader.poll(), "Uncommitted observations must not appear")
        try fixture.writer.run("COMMIT")
        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 250)
        XCTAssertNil(try reader.poll())

        // Changing a memo matters even when total assets do not move.
        try fixture.writer.exec("""
            INSERT INTO transactions(ts,kind,amount,merchant,source,uid)
            VALUES('2026-09-02 12:02','approval',10,'Original','app:KAKAO','voucher')
            """, [])
        XCTAssertEqual(try reader.poll()?.lines.first?.memo, " Original")
        try fixture.writer.exec("UPDATE transactions SET merchant='Corrected' WHERE uid='voucher'", [])
        XCTAssertEqual(try reader.poll()?.lines.first?.memo, " Corrected")
    }

    func testLockedReadsThrowWithoutReturningAnEmptyLedgerAndRecover() throws {
        let fixture = try Fixture(balance: 100)
        let reader = LedgerChangeReader(dbPath: fixture.path, me: "Synthetic")
        XCTAssertNotNil(try reader.poll())
        let directReader = try DB(path: fixture.path)
        XCTAssertEqual(try directReader.snapshots().count, 1)

        try fixture.writer.run("BEGIN EXCLUSIVE TRANSACTION")
        defer { try? fixture.writer.run("ROLLBACK") }
        XCTAssertThrowsError(try directReader.snapshots(), "SQLITE_BUSY must not be mistaken for zero observations")
        XCTAssertThrowsError(try reader.poll())
        try fixture.snapshot(balance: 300, minute: "01")
        try fixture.writer.run("COMMIT")

        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 300)
        XCTAssertNil(try reader.poll())
    }

    func testDatabaseReplacementAtTheSamePathReopensTheReader() throws {
        let original = try Fixture(balance: 100)
        let replacement = try Fixture(balance: 600)
        let reader = LedgerChangeReader(dbPath: original.path, me: "Synthetic")
        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 100)

        try FileManager.default.removeItem(atPath: original.path)
        try FileManager.default.copyItem(atPath: replacement.path, toPath: original.path)
        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 600)
        XCTAssertNil(try reader.poll())
    }

    func testMissingDatabaseIsNotCreatedAndIsReadWhenItArrives() throws {
        let fixture = try Fixture(balance: 100)
        let missing = fixture.directory.appendingPathComponent("later.db").path
        let reader = LedgerChangeReader(dbPath: missing, me: "Synthetic")
        XCTAssertThrowsError(try reader.poll())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        try FileManager.default.copyItem(atPath: fixture.path, toPath: missing)
        XCTAssertEqual(try reader.poll()?.total(at: .distantFuture).sum, 100)
    }

    @MainActor func testMonitorPublishesOnMainActorSupportsPathChangesAndStops() async throws {
        let first = try Fixture(balance: 100)
        let second = try Fixture(balance: 900)
        let initial = expectation(description: "Initial committed value")
        let changed = expectation(description: "Changed database path")
        let afterStop = expectation(description: "No values after stop")
        afterStop.isInverted = true
        var totals: [Int] = []
        var stopped = false
        let monitor = LedgerMonitor(pollInterval: 0.02, onUpdate: { ledger in
            XCTAssertTrue(Thread.isMainThread)
            let total = ledger.total(at: .distantFuture).sum
            totals.append(total)
            if stopped { afterStop.fulfill() }
            else if total == 100 { initial.fulfill() }
            else if total == 900 { changed.fulfill() }
        })
        defer { monitor.stop() }
        monitor.start(dbPath: first.path, me: "Synthetic")
        monitor.start(dbPath: first.path, me: "Synthetic")
        await fulfillment(of: [initial], timeout: 3)

        monitor.start(dbPath: second.path, me: "Synthetic")
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(totals, [100, 900])
        monitor.stop()
        stopped = true
        try second.snapshot(balance: 950, minute: "01")
        await fulfillment(of: [afterStop], timeout: 0.2)
        XCTAssertEqual(totals, [100, 900])
    }

    @MainActor func testMonitorReportsReadFailureAndClearsItAfterRecovery() async throws {
        let fixture = try Fixture(balance: 100)
        let missing = fixture.directory.appendingPathComponent("later.db").path
        let failed = expectation(description: "Read error")
        let recovered = expectation(description: "Error cleared")
        let updated = expectation(description: "Recovered snapshot")
        var errors = 0
        let monitor = LedgerMonitor(pollInterval: 0.02, onUpdate: { ledger in
            XCTAssertEqual(ledger.total(at: .distantFuture).sum, 100)
            updated.fulfill()
        }, onError: { error in
            if error != nil { errors += 1; failed.fulfill() }
            else { recovered.fulfill() }
        })
        defer { monitor.stop() }
        monitor.start(dbPath: missing, me: "Synthetic")
        await fulfillment(of: [failed], timeout: 3)
        try FileManager.default.copyItem(atPath: fixture.path, toPath: missing)
        await fulfillment(of: [recovered, updated], timeout: 3)
        XCTAssertEqual(errors, 1)
    }

    private final class Fixture {
        let directory: URL
        let path: String
        let writer: DB

        init(balance: Int) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiLedgerMonitor-" + UUID().uuidString)
            path = directory.appendingPathComponent("ledger.db").path
            writer = try DB(path: path, writable: true)
            try snapshot(balance: balance, minute: "00")
        }

        func snapshot(balance: Int, minute: String) throws {
            try writer.insertSnapshot(ts: "2026-09-02 12:\(minute)", app: "TEST", account: "Synthetic account",
                                      balance: balance, shot: "synthetic.png")
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}
