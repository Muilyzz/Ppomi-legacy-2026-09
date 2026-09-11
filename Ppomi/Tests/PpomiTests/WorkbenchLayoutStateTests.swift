import AppKit
import XCTest
@testable import Ppomi

final class WorkbenchLayoutStateTests: XCTestCase {
    @MainActor func testCompactContentEntryRetainsApprovalAndParkingWhenClosed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-compact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        let db = try DB(path: path, writable: true)
        let pending: [String: Any] = ["id": "compact-approval", "html": "내용을 확인해 주세요", "options": ["확인", "취소"]]
        try db.setState("ask:pending", String(decoding: JSONSerialization.data(withJSONObject: pending), as: UTF8.self))
        let state = AppState()
        state.watchAsks(dbPath: path)
        state.pollAsk()
        state.beginRecordsFocus()
        state.setCompactWorkbench(true)
        XCTAssertFalse(state.compactContentPresented)
        XCTAssertFalse(state.recordsPageVisible, "A parked window does not make hidden compact records active")
        XCTAssertEqual(state.compactContentActionTitle, "승인 요청", "The top bar keeps a reachable approval entry")
        let phase = state.phase
        for _ in 0..<2 {
            state.presentCompactContent()
            XCTAssertTrue(state.compactContentPresented)
            state.dismissCompactContent()
            XCTAssertFalse(state.compactContentPresented)
            XCTAssertTrue(state.recordsFocused, "Closing content never restores windows or releases their lease")
            XCTAssertEqual(state.recordsFocusRequest, 0)
            XCTAssertEqual(state.ask?.id, "compact-approval")
            XCTAssertEqual(state.ask?.options, ["확인", "취소"])
            XCTAssertEqual(state.phase, phase)
            XCTAssertNil(try db.state("ask:answer:compact-approval"))
        }
        state.show(.health)
        XCTAssertTrue(state.compactContentPresented)
        state.openChat()
        XCTAssertFalse(state.compactContentPresented)
        XCTAssertEqual(state.tab, .health)
        XCTAssertEqual(state.compactContentActionTitle, "승인 요청")
        XCTAssertNil(try db.state("ask:answer:compact-approval"))
    }

    @MainActor func testReturningToCompactStartsWithChatAndRetainsContentContext() {
        let state = AppState()
        state.setCompactWorkbench(true)
        XCTAssertEqual(state.compactContentActionTitle, "기록")
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        let focus = state.evidenceFocus
        XCTAssertTrue(state.compactContentPresented)
        state.setCompactWorkbench(false)
        state.setCompactWorkbench(true)
        XCTAssertFalse(state.compactContentPresented)
        XCTAssertEqual(state.evidenceFocus, focus)
        XCTAssertEqual(state.tab, .evidence)
        XCTAssertEqual(state.recordsFocusRequest, 0)
    }

    @MainActor func testNewApprovalKeepsTheRecordTabAndShowsRequiredTarget() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        let db = try DB(path: path, writable: true)
        let pending: [String: Any] = ["id": "layout-approval", "html": "내용을 확인해 주세요", "options": ["확인", "취소"]]
        try db.setState("ask:pending", String(decoding: JSONSerialization.data(withJSONObject: pending), as: UTF8.self))
        let state = AppState()
        state.selectSurface(.windows)
        state.show(.timeline)
        state.watchAsks(dbPath: path)
        state.pollAsk()
        XCTAssertEqual(state.workSurface, .iphone)
        XCTAssertEqual(state.ask?.id, "layout-approval")

        state.show(.health)
        state.pollAsk()
        XCTAssertEqual(state.tab, .health)
        XCTAssertEqual(state.ask?.id, "layout-approval")
        XCTAssertEqual(state.recordsFocusRequest, 0)
        XCTAssertFalse(state.recordsFocused)
        XCTAssertNil(try db.state("ask:answer:layout-approval"))
    }

    @MainActor func testChatAndTargetChangesPreserveRecordContext() {
        let state = AppState()
        state.selectSurface(.windows)
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        let focus = state.evidenceFocus
        XCTAssertEqual(state.workSurface, .windows)
        XCTAssertEqual(state.tab, .evidence)

        state.openChat()
        XCTAssertEqual(state.evidenceFocus, focus)
        state.selectSurface(.windows)
        XCTAssertEqual(state.tab, .evidence)
        XCTAssertEqual(state.evidenceFocus, focus)
        XCTAssertEqual(state.recordsFocusRequest, 0)
        XCTAssertFalse(state.recordsFocused)
    }

    @MainActor func testPendingApprovalRemainsAvailableWhileReviewingRecords() {
        let state = AppState()
        state.ask = (id: "approval", text: "확인해 주세요", options: ["승인", "취소"])
        state.phase = .humanTurn(reason: "승인 대기")
        state.show(.health)
        state.selectSurface(.windows)

        XCTAssertEqual(state.workSurface, .iphone)
        XCTAssertEqual(state.tab, .health)
        XCTAssertEqual(state.ask?.id, "approval")
        XCTAssertEqual(state.phase, .humanTurn(reason: "승인 대기"))
    }

    /// Only three regions belong to the root. Record/control details and approval belong to the left region.
    @MainActor func testWorkspaceMountsOnlyTheTreeViews() {
        _ = NSApplication.shared
        let state = AppState()
        state.ask = (id: "review", text: "내용을 확인해 주세요", options: ["확인", "취소"])
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        let sidebar = AgentSidebar(state: state), records = NSView(), toolbar = NSView(), topBar = NSView()
        content.mount(topBar: topBar, sidebar: sidebar, records: records, controlToolbar: toolbar)
        content.band.state = state
        content.band.sync()
        content.phoneSize = CGSize(width: 300, height: 420)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(Set(content.subviews.map { ObjectIdentifier($0) }),
                       Set([content.topBarArea, content.conversationArea, content.contentArea].map { ObjectIdentifier($0) }))
        XCTAssertEqual(Set(content.contentArea.subviews.map { ObjectIdentifier($0) }),
                       Set([content.phoneSlot, content.recordsArea, content.controlToolbarArea, content.band, content.overlay].map { ObjectIdentifier($0) }))
        XCTAssertTrue(topBar.superview === content.topBarArea)
        XCTAssertTrue(sidebar.superview === content.conversationArea)
        XCTAssertTrue(records.superview === content.recordsArea)
        XCTAssertTrue(toolbar.superview === content.controlToolbarArea)
        XCTAssertFalse(content.phoneSlot.isHidden)
        XCTAssertTrue(content.recordsArea.isHidden)
        XCTAssertFalse(content.band.isHidden)
        let conversation = content.conversationArea.convert(content.conversationArea.bounds, to: content)
        let slot = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        let band = content.band.convert(content.band.bounds, to: content)
        let toolbarFrame = content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content)
        let topBarFrame = content.topBarArea.convert(content.topBarArea.bounds, to: content)
        XCTAssertLessThanOrEqual(slot.maxX, conversation.minX)
        XCTAssertLessThanOrEqual(band.maxX, conversation.minX)
        XCTAssertEqual(band.width, toolbarFrame.width)
        XCTAssertLessThanOrEqual(conversation.maxY, topBarFrame.minY)
        XCTAssertLessThanOrEqual(toolbarFrame.maxY, topBarFrame.minY)
        XCTAssertEqual(state.ask?.id, "review")
    }
}
