import Foundation
import XCTest
@testable import Ppomi

final class RuntimeEventMonitorTests: XCTestCase {
    func testMissingFileIsEmptyWithoutCreationThenArrivingEventsAreObservedOnce() throws {
        let fixture = Fixture()
        let reader = RuntimeEventChangeReader(ledgerPath: fixture.path)
        XCTAssertEqual(try reader.poll(), [])
        XCTAssertNil(try reader.poll())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        let store = try RuntimeEventStore(ledgerPath: fixture.path)
        let event = RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .read, method: .ocr)
        try store.append(event)
        XCTAssertEqual(try reader.poll(), [event])
        XCTAssertNil(try reader.poll())
        try store.append(event)
        XCTAssertNil(try reader.poll(), "A redundant commit must not republish the same events")
    }

    func testUncommittedEventsStayHiddenAndChangedStoreAtSamePathReopens() throws {
        let fixture = Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.path)
        let reader = RuntimeEventChangeReader(ledgerPath: fixture.path)
        XCTAssertEqual(try reader.poll(), [])
        let raw = try DB(path: store.path, writable: true, initializeLedgerSchema: false)
        let id = UUID(), callID = UUID()
        try raw.run("BEGIN IMMEDIATE TRANSACTION")
        defer { try? raw.run("ROLLBACK") }
        try raw.exec("""
            INSERT INTO runtime_events(id,call_id,timestamp,tool,kind,method) VALUES(?,?,1,'phone_screen','read','ocr')
            """, [id.uuidString, callID.uuidString])
        XCTAssertNil(try reader.poll())
        try raw.run("COMMIT")
        XCTAssertEqual(try reader.poll()?.map(\.id), [id])

        let replacement = Fixture()
        let replacementStore = try RuntimeEventStore(ledgerPath: replacement.path)
        let event = RuntimeEvent(callID: UUID(), tool: "screen_inspect", kind: .observed, method: .vlm)
        try replacementStore.append(event)
        try FileManager.default.removeItem(atPath: store.path)
        try FileManager.default.copyItem(atPath: replacementStore.path, toPath: store.path)
        XCTAssertEqual(try reader.poll(), [event])
        XCTAssertNil(try reader.poll())
    }

    func testMalformedStoredNamesAreNotPublishedAndReaderRecoversWithLastGoodHistory() throws {
        let fixture = Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.path)
        let event = RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .read, method: .ocr)
        try store.append(event)
        let reader = RuntimeEventChangeReader(ledgerPath: fixture.path)
        XCTAssertEqual(try reader.poll(), [event])
        let raw = try DB(path: store.path, writable: true, initializeLedgerSchema: false)
        let invalidID = UUID().uuidString
        try raw.exec("""
            INSERT INTO runtime_events(id,call_id,timestamp,tool,kind,method) VALUES(?,?,1,?,'read','ocr')
            """, [invalidID, UUID().uuidString, "synthetic private text"])
        XCTAssertThrowsError(try reader.poll())
        try raw.exec("DELETE FROM runtime_events WHERE id=?", [invalidID])
        XCTAssertNil(try reader.poll(), "Recovery to the last good history does not duplicate UI updates")
        let next = RuntimeEvent(callID: event.callID, tool: "phone_screen", kind: .returned, method: .tool)
        try store.append(next)
        XCTAssertEqual(try reader.poll(), [event, next])
    }

    @MainActor func testMonitorPublishesOnMainActorSwitchesPathsAndStops() async throws {
        let first = Fixture(), second = Fixture()
        let firstStore = try RuntimeEventStore(ledgerPath: first.path)
        let secondStore = try RuntimeEventStore(ledgerPath: second.path)
        let firstEvent = RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .reading, method: .ocr)
        let secondEvent = RuntimeEvent(callID: UUID(), tool: "screen_inspect", kind: .observing, method: .vlm)
        try firstStore.append(firstEvent)
        try secondStore.append(secondEvent)
        let initial = expectation(description: "Initial history")
        let switched = expectation(description: "New path history")
        let stoppedUpdate = expectation(description: "No update after stop")
        stoppedUpdate.isInverted = true
        var snapshots: [[RuntimeEvent]] = []
        var stopped = false
        let monitor = RuntimeEventMonitor(pollInterval: 0.02, onUpdate: { events in
            XCTAssertTrue(Thread.isMainThread)
            snapshots.append(events)
            if stopped { stoppedUpdate.fulfill() }
            else if events == [firstEvent] { initial.fulfill() }
            else if events == [secondEvent] { switched.fulfill() }
        })
        defer { monitor.stop() }
        monitor.start(ledgerPath: first.path)
        monitor.start(ledgerPath: first.path)
        await fulfillment(of: [initial], timeout: 3)
        monitor.start(ledgerPath: second.path)
        await fulfillment(of: [switched], timeout: 3)
        monitor.stop()
        stopped = true
        try secondStore.append(RuntimeEvent(callID: secondEvent.callID, tool: secondEvent.tool, kind: .returned, method: .tool))
        await fulfillment(of: [stoppedUpdate], timeout: 0.15)
        XCTAssertEqual(snapshots, [[firstEvent], [secondEvent]])
    }

    @MainActor func testMonitorKeepsLastGoodEventsOnErrorsAndClearsUnavailableOnRecovery() async throws {
        let fixture = Fixture()
        let store = try RuntimeEventStore(ledgerPath: fixture.path)
        let event = RuntimeEvent(callID: UUID(), tool: "balances", kind: .returned, method: .storage)
        try store.append(event)
        let initial = expectation(description: "Valid initial history")
        let failed = expectation(description: "Unavailable")
        let recovered = expectation(description: "Available again")
        var snapshots: [[RuntimeEvent]] = []
        var errors: [Bool] = []
        let monitor = RuntimeEventMonitor(pollInterval: 0.02, onUpdate: { events in
            snapshots.append(events)
            if snapshots.count == 1 { initial.fulfill() }
        }, onError: { unavailable in
            errors.append(unavailable)
            if unavailable { failed.fulfill() } else { recovered.fulfill() }
        })
        defer { monitor.stop() }
        monitor.start(ledgerPath: fixture.path)
        await fulfillment(of: [initial], timeout: 3)
        let raw = try DB(path: store.path, writable: true, initializeLedgerSchema: false)
        try raw.exec("UPDATE runtime_events SET kind='unknown'", [])
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(snapshots, [[event]], "An unreadable snapshot must not blank the visible history")
        try raw.exec("UPDATE runtime_events SET kind='returned'", [])
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(errors, [true, false])
        XCTAssertEqual(snapshots, [[event]])
    }

    @MainActor func testStaleQueuedResultCannotOverwriteNewPath() async throws {
        let first = Fixture(), second = Fixture()
        let firstStore = try RuntimeEventStore(ledgerPath: first.path)
        let secondStore = try RuntimeEventStore(ledgerPath: second.path)
        try firstStore.append(RuntimeEvent(callID: UUID(), tool: "phone_screen", kind: .reading, method: .ocr))
        let event = RuntimeEvent(callID: UUID(), tool: "screen_inspect", kind: .observing, method: .vlm)
        try secondStore.append(event)
        let updated = expectation(description: "Only latest configuration publishes")
        var snapshots: [[RuntimeEvent]] = []
        let monitor = RuntimeEventMonitor(pollInterval: 0.02, onUpdate: { events in snapshots.append(events); updated.fulfill() })
        defer { monitor.stop() }
        monitor.start(ledgerPath: first.path)
        // While the main actor is held, a first-path result may be queued but cannot publish.
        occupyMainActorForBackgroundPoll()
        monitor.start(ledgerPath: second.path)
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(snapshots, [[event]])
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiRuntimeMonitor-" + UUID().uuidString)
        var path: String { directory.appendingPathComponent("ledger.db").path }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Deliberately synchronous: a queued publication must wait until the configuration is replaced.
    private func occupyMainActorForBackgroundPoll() { Thread.sleep(forTimeInterval: 0.05) }
}
