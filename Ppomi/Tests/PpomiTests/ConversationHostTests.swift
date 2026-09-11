import AppKit
import XCTest
@testable import Ppomi

final class ConversationHostTests: XCTestCase {
    @MainActor func testOpenChatAndShowWorkbenchAreSeparateSignalsThatNeverRequestPlacement() {
        let state = AppState()
        state.openChat()
        XCTAssertEqual(state.chatOpen, 1)
        XCTAssertTrue(state.fleetLine.contains("macos"))
        XCTAssertTrue(state.fleetLine.contains("온라인"))
        XCTAssertEqual(state.workbenchShown, 0)
        state.showWorkbench()
        XCTAssertEqual(state.chatOpen, 1)
        XCTAssertEqual(state.workbenchShown, 1)
        XCTAssertEqual(state.shown, 0)
    }

    @MainActor func testSidebarMountsTheConversationInItsAgentAreaAndShowsAPlaceholderWhenClosed() {
        let state = AppState()
        let sidebar = AgentSidebar(state: state)
        sidebar.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertFalse(sidebar.placeholderHidden)
        let view = NSView()
        sidebar.mount(conversation: view)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame, sidebar.agentArea)
        XCTAssertTrue(sidebar.placeholderHidden)
        XCTAssertEqual(sidebar.agentArea, sidebar.bounds, "The conversation column is the shell alone")
        sidebar.unmount(conversation: view)
        XCTAssertNil(view.superview)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertFalse(sidebar.placeholderHidden)
        // The embedded conversation asks for its window through the host, without reopening the chat.
        sidebar.revealConversation()
        XCTAssertEqual(state.workbenchShown, 1)
        XCTAssertEqual(state.chatOpen, 0)
    }

    @MainActor func testEmbeddedConversationMountsIntoTheHostAndCloseUnmountsIt() {
        final class Host: NSView, ConversationHost {
            var mounted: NSView?
            var reveals = 0
            func mount(conversation: NSView) { mounted = conversation; addSubview(conversation) }
            func unmount(conversation: NSView) { mounted = nil; conversation.removeFromSuperview() }
            func revealConversation() { reveals += 1 }
        }
        let host = Host(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let panel = AgentVoicePanel(defaults: UserDefaults(suiteName: "ppomi-conversation-host-tests")!)
        var closes = 0
        panel.onClose = { closes += 1 }
        panel.host = { host }
        panel.present()
        XCTAssertNotNil(host.mounted)
        XCTAssertTrue(panel.isEmbedded)
        XCTAssertNil(panel.window)
        panel.present()
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(host.reveals, 2, "every present asks the host to show its window")
        panel.close()
        XCTAssertNil(host.mounted)
        XCTAssertFalse(panel.isEmbedded)
        XCTAssertEqual(closes, 1)
    }
}
