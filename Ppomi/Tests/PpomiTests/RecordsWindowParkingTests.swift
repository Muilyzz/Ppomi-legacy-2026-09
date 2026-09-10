import AppKit
import XCTest
@testable import Ppomi

@MainActor
final class RecordsWindowParkingTests: XCTestCase {
    private final class Window {
        let target: RecordsWindowParking.Target
        var frame: CGRect
        var minimized = false
        var alive: Bool? = true
        var readable = true
        var supportsMinimize = true
        var failMinimize = false
        var partiallyMinimizeOnFailure = false
        var failRestore = false
        var failFrameRestore = false
        var revealedFrame: CGRect?
        var minimizationWrites: [Bool] = []
        var frameWrites: [CGRect] = []

        init(id: CGWindowID, minimized: Bool = false) {
            let frame = CGRect(x: CGFloat(id) * 20, y: -100, width: 500, height: 700)
            target = .init(pid: 42, id: id, frame: frame)
            self.frame = frame
            self.minimized = minimized
        }

        var handle: RecordsWindowParking.Handle {
            .init(isAlive: { self.alive }, read: {
                self.readable ? .init(frame: self.frame, isMinimized: self.minimized) : nil
            }, canMinimize: { self.supportsMinimize }, setMinimized: { minimized in
                self.minimizationWrites.append(minimized)
                if minimized && self.failMinimize {
                    if self.partiallyMinimizeOnFailure { self.minimized = true }
                    return false
                }
                if !minimized && self.failRestore { return false }
                self.minimized = minimized
                if !minimized, let revealedFrame = self.revealedFrame { self.frame = revealedFrame }
                return true
            }, setFrame: { frame in
                self.frameWrites.append(frame)
                if self.failFrameRestore { return false }
                self.frame = frame
                return true
            })
        }
    }

    private func parking(_ windows: [Window]) throws -> RecordsWindowParking {
        try RecordsWindowParking(targets: windows.map(\.target)) { target in
            try XCTUnwrap(windows.first { $0.target == target }).handle
        }
    }

    func testCapturePreflightsEveryWindowBeforeAnyMinimization() {
        let first = Window(id: 1), unsupported = Window(id: 2)
        unsupported.supportsMinimize = false
        XCTAssertThrowsError(try parking([first, unsupported]))
        XCTAssertTrue(first.minimizationWrites.isEmpty)
        XCTAssertTrue(unsupported.minimizationWrites.isEmpty)
        XCTAssertFalse(first.minimized)
    }

    func testParkRechecksAllCapturedStatesBeforeItsFirstMutation() throws {
        let first = Window(id: 1), moved = Window(id: 2)
        let parking = try parking([first, moved])
        moved.frame.origin.x += 100
        XCTAssertThrowsError(try parking.park())
        XCTAssertTrue(first.minimizationWrites.isEmpty)
        XCTAssertTrue(moved.minimizationWrites.isEmpty)
        XCTAssertEqual(moved.frame.minX, moved.target.frame.minX + 100)
    }

    func testParkingPreservesOriginallyMinimizedWindowsAndRestoresSavedGeometry() throws {
        let visible = Window(id: 1), alreadyMinimized = Window(id: 2, minimized: true)
        let parking = try parking([visible, alreadyMinimized])
        XCTAssertTrue(visible.minimizationWrites.isEmpty)
        try parking.park()
        try parking.park()
        XCTAssertEqual(visible.minimizationWrites, [true])
        XCTAssertTrue(alreadyMinimized.minimizationWrites.isEmpty)
        XCTAssertFalse(parking.wasRevealedExternally)
        visible.revealedFrame = CGRect(x: 400, y: 200, width: 600, height: 800)

        XCTAssertTrue(parking.restore())
        XCTAssertFalse(visible.minimized)
        XCTAssertEqual(visible.frame, visible.target.frame)
        XCTAssertEqual(visible.frameWrites, [visible.target.frame])
        XCTAssertTrue(alreadyMinimized.minimized)
        XCTAssertTrue(alreadyMinimized.minimizationWrites.isEmpty)
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(visible.minimizationWrites, [true, false])
    }

    func testPartialFailureRollsBackEveryAttemptedWindow() throws {
        let first = Window(id: 1), failing = Window(id: 2), untouched = Window(id: 3)
        failing.failMinimize = true
        failing.partiallyMinimizeOnFailure = true
        let parking = try parking([first, failing, untouched])
        XCTAssertThrowsError(try parking.park())
        XCTAssertFalse(first.minimized)
        XCTAssertFalse(failing.minimized)
        XCTAssertEqual(first.minimizationWrites, [true, false])
        XCTAssertEqual(failing.minimizationWrites, [true, false])
        XCTAssertTrue(untouched.minimizationWrites.isEmpty)
        XCTAssertTrue(parking.restore())
    }

    func testFailedRollbackRetainsTheOriginalHandleForRestoreRetry() throws {
        let first = Window(id: 1), failing = Window(id: 2), replacement = Window(id: 1)
        first.failRestore = true
        failing.failMinimize = true
        var selected = [first, failing]
        var captureCount = 0
        let parking = try RecordsWindowParking(targets: selected.map(\.target)) { target in
            captureCount += 1
            return try XCTUnwrap(selected.first { $0.target == target }).handle
        }
        XCTAssertThrowsError(try parking.park())
        XCTAssertTrue(first.minimized)
        selected = [replacement, failing]
        XCTAssertFalse(parking.restore())
        first.failRestore = false
        XCTAssertTrue(parking.restore())
        XCTAssertFalse(first.minimized)
        XCTAssertEqual(captureCount, 2, "A retry must not resolve a new window for an old target")
        XCTAssertTrue(replacement.minimizationWrites.isEmpty)
        XCTAssertTrue(replacement.frameWrites.isEmpty)
    }

    func testClosedWindowIsSkippedWithoutRestoringItsReplacement() throws {
        let original = Window(id: 1), replacement = Window(id: 1)
        var selected = original
        let parking = try RecordsWindowParking(targets: [original.target]) { _ in selected.handle }
        try parking.park()
        original.alive = false
        selected = replacement
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(original.minimizationWrites, [true])
        XCTAssertTrue(replacement.minimizationWrites.isEmpty)
        XCTAssertTrue(replacement.frameWrites.isEmpty)
    }

    func testExternalRevealPreservesTheUsersNewPositionAndSize() throws {
        let window = Window(id: 1)
        let parking = try parking([window])
        try parking.park()
        window.minimized = false
        let manualFrame = CGRect(x: -800, y: 40, width: 800, height: 600)
        window.frame = manualFrame
        XCTAssertTrue(parking.wasRevealedExternally)
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(window.frame, manualFrame)
        XCTAssertTrue(window.frameWrites.isEmpty)
        XCTAssertEqual(window.minimizationWrites, [true])
        XCTAssertFalse(parking.wasRevealedExternally)
    }

    func testTemporarilyUnverifiableOriginalHandleRemainsAvailableForRetry() throws {
        let window = Window(id: 1)
        let parking = try parking([window])
        try parking.park()
        window.alive = nil
        XCTAssertFalse(parking.restore())
        XCTAssertTrue(window.minimized)
        XCTAssertEqual(window.minimizationWrites, [true])
        window.alive = true
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(window.minimizationWrites, [true, false])
    }

    func testOurOwnRevealWithFailedGeometryWriteRetriesTheSavedFrame() throws {
        let window = Window(id: 1)
        let parking = try parking([window])
        try parking.park()
        window.revealedFrame = CGRect(x: 80, y: 300, width: 600, height: 750)
        window.failFrameRestore = true
        XCTAssertFalse(parking.restore())
        XCTAssertFalse(window.minimized)
        XCTAssertFalse(parking.wasRevealedExternally, "A reveal performed by restore is not an external reveal")
        XCTAssertNotEqual(window.frame, window.target.frame)

        window.failFrameRestore = false
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(window.frame, window.target.frame)
        XCTAssertEqual(window.frameWrites, [window.target.frame, window.target.frame])
        XCTAssertEqual(window.minimizationWrites, [true, false])
    }

    func testManualMoveAfterFailedAutomaticGeometryRestoreIsPreserved() throws {
        let window = Window(id: 1)
        let parking = try parking([window])
        try parking.park()
        window.revealedFrame = CGRect(x: 80, y: 300, width: 600, height: 750)
        window.failFrameRestore = true
        XCTAssertFalse(parking.restore())
        let manualFrame = CGRect(x: -500, y: 80, width: 720, height: 900)
        window.frame = manualFrame
        window.failFrameRestore = false
        XCTAssertTrue(parking.wasRevealedExternally)
        XCTAssertTrue(parking.restore())
        XCTAssertEqual(window.frame, manualFrame)
        XCTAssertEqual(window.frameWrites.count, 1)
    }
}
