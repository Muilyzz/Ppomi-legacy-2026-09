import Foundation
import XCTest
@testable import Ppomi

final class DBConcurrencyTests: XCTestCase {
    func testWriterWaitsForShortReadSnapshotAndCommitsWithoutRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiDBConcurrency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        do {
            let setup = try DB(path: path, writable: true)
            try setup.insertSnapshot(ts: "2026-09-02 12:00", app: "TEST", account: "Synthetic", balance: 100, shot: "test.png")
        }
        let readStarted = expectation(description: "Read snapshot acquires its shared lock")
        let started = expectation(description: "Writer starts while the read snapshot is open")
        let committed = expectation(description: "Writer commits after the snapshot is released")
        let verified = expectation(description: "The same reader observes the writer's committed value")
        let releaseRead = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "PpomiDBConcurrency.reader").async {
            do {
                // Each connection is created, used, and closed on its owner queue, as in LedgerMonitor.
                let reader = try DB(path: path)
                try reader.withReadTransaction { snapshot in
                    XCTAssertEqual(try snapshot.snapshots().map(\.balance), [100])
                    readStarted.fulfill()
                    XCTAssertEqual(releaseRead.wait(timeout: .now() + 3), .success)
                    XCTAssertEqual(try snapshot.snapshots().map(\.balance), [100], "The active read snapshot stays consistent")
                }
                XCTAssertEqual(writeFinished.wait(timeout: .now() + 3), .success)
                XCTAssertEqual(try reader.snapshots().map(\.balance), [100, 200])
            } catch { XCTFail("Read snapshot failed: \(error)") }
            verified.fulfill()
        }
        wait(for: [readStarted], timeout: 1)
        DispatchQueue(label: "PpomiDBConcurrency.writer").async {
            started.fulfill()
            do {
                let writer = try DB(path: path, writable: true)
                // One attempt: this must wait for the read lock rather than throwing SQLITE_BUSY.
                try writer.insertSnapshot(ts: "2026-09-02 12:01", app: "TEST", account: "Synthetic", balance: 200, shot: "next.png")
            } catch { XCTFail("The writer should wait for a short reader: \(error)") }
            writeFinished.signal()
            committed.fulfill()
        }
        wait(for: [started], timeout: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            releaseRead.signal()
        }
        wait(for: [committed, verified], timeout: 3)
    }
}
