import AppKit
import XCTest
@testable import Ppomi

final class ChatNavigationTests: XCTestCase {
    @MainActor func testOrdinaryLaunchAndDockReopenShowChatWithoutRequestingWorkbenchPlacement() throws {
        let state = AppState(), panel = ConversationProbe()
        let host = try VoiceSession(state: state, panel: panel, monitorKeys: false)
        state.openInitialScreen(kiosk: false)
        XCTAssertEqual(panel.presentations, 1)
        XCTAssertEqual(state.shown, 0)
        XCTAssertFalse(state.kioskOn)
        let delegate = AppDelegate()
        delegate.state = state
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(panel.presentations, 2)
        XCTAssertEqual(panel.closes, 0)
        XCTAssertEqual(state.shown, 0)
        XCTAssertFalse(state.listening, "Opening a chat must not start a native session")
        withExtendedLifetime(host) {}
    }

    @MainActor func testExplicitKioskAndDeviceNavigationKeepTheirWorkbenchRoute() throws {
        let state = AppState(), panel = ConversationProbe()
        let host = try VoiceSession(state: state, panel: panel, monitorKeys: false)
        state.openInitialScreen(kiosk: true)
        XCTAssertTrue(state.kioskOn)
        XCTAssertEqual(panel.presentations, 0)
        state.selectSurface(.windows)
        XCTAssertEqual(state.shown, 1)
        XCTAssertEqual(state.workSurface, .windows)
        state.show(.playbooks); state.reveal()
        XCTAssertEqual(state.shown, 2)
        XCTAssertEqual(state.tab, .playbooks)
        XCTAssertEqual(panel.presentations, 0)
        withExtendedLifetime(host) {}
    }

    @MainActor func testDisablingWakePreservesAnActiveConversationButExplicitCloseStillEndsIt() throws {
        let state = AppState(), panel = ConversationProbe()
        let host = try VoiceSession(state: state, panel: panel, monitorKeys: false)
        state.openChat()
        panel.onActive?(true)
        XCTAssertTrue(state.listening)
        host.setVoice(false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(state.listening)
        XCTAssertEqual(panel.closes, 0)
        state.talk()
        XCTAssertEqual(panel.closes, 1)
        XCTAssertFalse(state.listening)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor private final class ConversationProbe: AgentConversationWindow {
        var onActive: ((Bool) -> Void)?
        var onClose: (() -> Void)?
        var isVisible = false
        var presentations = 0
        var closes = 0
        func present() { presentations += 1; isVisible = true }
        func close() { closes += 1; isVisible = false; onActive?(false); onClose?() }
    }
}
