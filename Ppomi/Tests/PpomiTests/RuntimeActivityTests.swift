import Combine
import XCTest
@testable import Ppomi

final class RuntimeActivityTests: XCTestCase {
    @MainActor func testCommittedEventArrivesAndChangingLedgerDropsPreviousCalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-runtime-activity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPath = directory.appendingPathComponent("first.db").path
        let secondPath = directory.appendingPathComponent("second.db").path
        let first = try RuntimeEventStore(ledgerPath: firstPath)
        let activity = RuntimeActivity()
        defer { activity.stop() }
        let call = UUID()
        let started = RuntimeEvent(callID: call, tool: "windows_screen", kind: .reading, method: .ocr)
        let received = expectation(description: "committed observation reaches the workbench")
        var tokens = Set<AnyCancellable>()
        activity.$events.filter { $0.last?.id == started.id }.prefix(1).sink { _ in received.fulfill() }.store(in: &tokens)
        activity.start(ledgerPath: firstPath)
        try first.append(started)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(activity.events.last, started)

        activity.start(ledgerPath: secondPath)
        XCTAssertTrue(activity.events.isEmpty, "A different ledger must not show the previous work's runtime")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RuntimeEventStore.path(for: secondPath)))
        try first.append(RuntimeEvent(callID: call, tool: "windows_screen", kind: .returned, method: .tool))
        let second = try RuntimeEventStore(ledgerPath: secondPath)
        let newEvent = RuntimeEvent(callID: UUID(), tool: "sql", kind: .returned, method: .storage)
        let switched = expectation(description: "only the new ledger's event arrives")
        activity.$events.filter { $0.last?.id == newEvent.id }.prefix(1).sink { _ in switched.fulfill() }.store(in: &tokens)
        try second.append(newEvent)
        await fulfillment(of: [switched], timeout: 3)
        XCTAssertEqual(activity.events.map(\.callID), [newEvent.callID])
        activity.stop()
        XCTAssertTrue(activity.events.isEmpty)
    }
}
