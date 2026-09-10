import AppKit
import XCTest
@testable import Ppomi

final class AppDelegateTests: XCTestCase {
    /// Settings and workbench windows do not replace the app's default conversation entry.
    @MainActor func testReopenOpensChatRegardlessOfVisibleWindows() {
        for visible in [false, true] {
            let state = AppState()
            state.show(.playbooks)
            let delegate = AppDelegate()
            delegate.state = state

            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible))
            XCTAssertEqual(state.chatOpen, 1)
            XCTAssertEqual(state.shown, 0)
            XCTAssertEqual(state.tab, .playbooks)
        }
    }

    /// Reopening chat does not change an explicitly selected workbench size or record tab.
    @MainActor func testReopenOpensChatAndPreservesKiosk() {
        for visible in [false, true] {
            let state = AppState()
            state.show(.playbooks)
            state.toggleKiosk()
            let delegate = AppDelegate()
            delegate.state = state

            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible))
            XCTAssertEqual(state.chatOpen, 1)
            XCTAssertEqual(state.shown, 0)
            XCTAssertTrue(state.kioskOn)
            XCTAssertEqual(state.phase, .humanUse(onScreen: true))
            XCTAssertEqual(state.tab, .playbooks)
        }
    }

    @MainActor func testReopenUsesPendingStateBeforeLaunchDelegateReceivesIt() {
        let previous = AppDelegate.pendingState
        defer { AppDelegate.pendingState = previous }
        let state = AppState()
        AppDelegate.pendingState = state

        XCTAssertFalse(AppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(state.chatOpen, 1)
        XCTAssertEqual(state.shown, 0)
    }
}
