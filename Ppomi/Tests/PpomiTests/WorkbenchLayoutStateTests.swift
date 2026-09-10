import AppKit
import XCTest
@testable import Ppomi

final class WorkbenchLayoutStateTests: XCTestCase {
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

    /// The conversation column is the shell alone; the control column is header, slot and (with a question) the band.
    @MainActor func testWorkspaceMountsOnlyTheTreeViews() {
        _ = NSApplication.shared
        let state = AppState()
        state.ask = (id: "review", text: "내용을 확인해 주세요", options: ["확인", "취소"])
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        let sidebar = AgentSidebar(state: state), records = NSView(), toolbar = NSView()
        content.mount(sidebar: sidebar, records: records, controlToolbar: toolbar)
        content.band.state = state
        content.band.sync()
        content.phoneSize = CGSize(width: 300, height: 420)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(Set(content.subviews.map { ObjectIdentifier($0) }),
                       Set([content.phoneSlot, content.workbenchArea, content.recordsArea, content.controlToolbarArea, content.band].map { ObjectIdentifier($0) }))
        XCTAssertTrue(sidebar.superview === content.workbenchArea)
        XCTAssertTrue(records.superview === content.recordsArea)
        XCTAssertTrue(toolbar.superview === content.controlToolbarArea)
        XCTAssertFalse(content.phoneSlot.isHidden)
        XCTAssertTrue(content.recordsArea.isHidden)
        XCTAssertFalse(content.band.isHidden)
        XCTAssertLessThanOrEqual(content.workbenchArea.frame.maxX, content.phoneSlot.frame.minX)
        XCTAssertLessThanOrEqual(content.workbenchArea.frame.maxX, content.band.frame.minX)
        XCTAssertEqual(content.band.frame.width, content.controlToolbarArea.frame.width)
        XCTAssertEqual(state.ask?.id, "review")
    }
}
