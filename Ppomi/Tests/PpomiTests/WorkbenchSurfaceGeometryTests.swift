import AppKit
import XCTest
@testable import Ppomi

final class WorkbenchSurfaceGeometryTests: XCTestCase {
    @MainActor func testCompactContentAndApprovalOverlayPreservesMountedConversation() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let editor = NSTextView(), records = NSView(), toolbar = NSView(), topBar = NSView()
        content.mount(topBar: topBar, sidebar: editor, records: records, controlToolbar: toolbar)
        let state = AppState()
        state.ask = (id: "compact-review", text: "내용을 확인해 주세요", options: ["확인", "취소"])
        content.band.state = state
        content.band.sync()
        content.recordsFocused = true
        content.dockedPhone = true
        content.followedPhone = CGRect(x: 20, y: 100, width: 240, height: 300)
        content.layoutSubtreeIfNeeded()
        editor.string = "Retained conversation"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        let viewport = editor.frame
        XCTAssertEqual(content.conversationArea.frame, WorkbenchLayout.pane(in: content.dashboard.workspace).content)
        XCTAssertTrue(content.contentArea.isHidden)
        XCTAssertTrue(content.band.isHiddenOrHasHiddenAncestor, "No approval panel below compact chat")
        for presented in [true, false, true, false] {
            content.compactContentPresented = presented
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.contentArea.isHidden, !presented)
            XCTAssertEqual(content.band.isHiddenOrHasHiddenAncestor, !presented)
            XCTAssertEqual(records.isHiddenOrHasHiddenAncestor, !presented)
            XCTAssertTrue(content.contentArea.isOpaque)
            XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(topBar.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(editor.superview === content.conversationArea)
            XCTAssertTrue(records.superview === content.recordsArea)
            XCTAssertTrue(content.band.superview === content.contentArea)
            XCTAssertEqual(editor.frame, viewport)
            XCTAssertEqual(editor.string, "Retained conversation")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
            XCTAssertTrue(content.recordsFocused)
            XCTAssertNil(content.nativeHoleRect)
            XCTAssertFalse(content.nativeControlFits)
            XCTAssertTrue(content.controlAvailableArea.isEmpty)
            XCTAssertEqual(state.ask?.id, "compact-review")
            let page = content.recordsArea.convert(content.recordsArea.bounds, to: content)
            let band = content.band.convert(content.band.bounds, to: content)
            XCTAssertTrue(content.dashboard.workspace.contains(page))
            XCTAssertTrue(content.dashboard.workspace.contains(band))
            XCTAssertFalse(page.intersects(band))
            XCTAssertNil(editor.window)
        }
    }

    /// The top bar spans both columns; native target width never changes their ownership.
    func testDashboardKeepsANarrowConversationAndGivesTheRestToContent() {
        for origin in [CGPoint.zero, CGPoint(x: -1728, y: 90)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1728, height: 1117))
            let layout = WorkbenchLayout.dashboard(in: screen)
            XCTAssertEqual(layout.conversationColumn.width, WorkbenchLayout.conversationWidth)
            XCTAssertEqual(layout.conversationColumn.maxX, screen.maxX)
            XCTAssertEqual(layout.contentColumn.width, screen.width - WorkbenchLayout.conversationWidth)
            XCTAssertEqual(layout.contentColumn.minX, screen.minX)
            XCTAssertEqual(layout.contentColumn.maxX, layout.conversationColumn.minX)
            XCTAssertFalse(layout.isCompact)
            XCTAssertEqual(layout.topBar.maxY, screen.maxY - WorkbenchLayout.normalTop)
            XCTAssertEqual(layout.topBar.height, WorkbenchLayout.toolbarHeight)
            XCTAssertEqual(layout.topBar.minX, screen.minX)
            XCTAssertEqual(layout.topBar.maxX, screen.maxX)
            XCTAssertEqual(layout.workspace.maxY, layout.topBar.minY)
            XCTAssertEqual(layout.conversationColumn.height, layout.workspace.height)
            XCTAssertEqual(layout.contentColumn.height, layout.workspace.height)
            XCTAssertTrue(screen.contains(layout.contentColumn))
            XCTAssertTrue(screen.contains(layout.conversationColumn))
        }
    }

    func testCompactDashboardKeepsFullChatViewportForExplicitContentOverlay() {
        for origin in [CGPoint.zero, CGPoint(x: -900, y: 70)] {
            for width in [300, 599] as [CGFloat] {
                let bounds = CGRect(origin: origin, size: CGSize(width: width, height: 800))
                let layout = WorkbenchLayout.dashboard(in: bounds)
                XCTAssertEqual(layout.topBar.maxY, bounds.maxY - WorkbenchLayout.normalTop)
                XCTAssertEqual(layout.topBar.width, width)
                XCTAssertEqual(layout.conversationColumn.width, width)
                XCTAssertEqual(layout.contentColumn.width, width)
                XCTAssertEqual(layout.conversationColumn.maxY, layout.topBar.minY)
                XCTAssertTrue(layout.isCompact)
                XCTAssertEqual(layout.conversationColumn, layout.workspace)
                XCTAssertEqual(layout.contentColumn, layout.workspace)
                XCTAssertEqual(layout.contentColumn.minY, bounds.minY)
                XCTAssertEqual(layout.contentColumn.height, layout.conversationColumn.height)
                XCTAssertGreaterThan(layout.conversationColumn.height, 0)
                XCTAssertTrue(bounds.contains(layout.topBar))
                XCTAssertTrue(bounds.contains(layout.conversationColumn))
                XCTAssertTrue(bounds.contains(layout.contentColumn))
            }
            let wide = WorkbenchLayout.dashboard(in: CGRect(origin: origin, size: CGSize(width: 600, height: 800)))
            XCTAssertFalse(wide.isCompact)
            XCTAssertEqual(wide.contentColumn.maxX, wide.conversationColumn.minX)
            XCTAssertEqual(wide.conversationColumn.minY, wide.contentColumn.minY)
            XCTAssertEqual(wide.conversationColumn.maxY, wide.contentColumn.maxY)
            XCTAssertGreaterThan(wide.contentColumn.width, 0)
        }
    }

    /// 차례 띠 has height only while a question is pending; without it the slot reaches the bottom inset.
    @MainActor func testFooterIsAbsentWithoutABand() {
        _ = NSApplication.shared
        let state = AppState()
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        content.band.state = state
        content.phoneSize = CGSize(width: 300, height: 440)
        content.band.sync()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.footerHeight, 0)
        XCTAssertTrue(content.band.isHidden)
        let column = content.dashboard.contentColumn
        XCTAssertEqual(content.controlAvailableArea.minY, column.minY + WorkbenchLayout.approvalBottom)
        XCTAssertEqual(WorkbenchLayout.pane(in: column).footer.height, 0)
        XCTAssertEqual(content.conversationArea.convert(content.conversationArea.bounds, to: content).minY, column.minY + WorkbenchLayout.approvalBottom)
        let slotWithoutBand = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)

        state.ask = (id: "approval", text: "진행할까요?", options: ["승인", "취소"])
        content.band.sync()
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.footerHeight, 0)
        XCTAssertFalse(content.band.isHidden)
        let band = content.band.convert(content.band.bounds, to: content)
        let slot = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        let conversation = content.conversationArea.convert(content.conversationArea.bounds, to: content)
        XCTAssertEqual(band.height, content.footerHeight)
        XCTAssertEqual(band.minY, column.minY + WorkbenchLayout.approvalBottom)
        XCTAssertGreaterThanOrEqual(band.minX, column.minX)
        XCTAssertLessThanOrEqual(band.maxX, column.maxX)
        XCTAssertFalse(band.intersects(slot))
        XCTAssertFalse(band.intersects(conversation), "No footer under the conversation")
        XCTAssertEqual(slot, slotWithoutBand, "A top-aligned slot keeps its place while the band appears")

        state.ask = nil
        content.band.sync()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.footerHeight, 0)
        XCTAssertTrue(content.band.isHidden)
    }

    @MainActor func testRecordsReplaceOnlyTheLeftPaneAndPreserveChatTopBarAndApproval() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        let editor = NSTextView(), records = NSView(), toolbar = NSView(), topBar = NSView()
        content.mount(topBar: topBar, sidebar: editor, records: records, controlToolbar: toolbar)
        let state = AppState()
        state.ask = (id: "review", text: "기록을 확인해 주세요", options: ["확인", "취소"])
        content.band.state = state
        content.band.sync()
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        editor.string = "Retained conversation"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        let workbenchFrame = content.conversationArea.convert(content.conversationArea.bounds, to: content)
        let topBarFrame = content.topBarArea.convert(content.topBarArea.bounds, to: content)
        let toolbarFrame = content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content)
        let phoneFrame = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        let approvalFrame = content.band.convert(content.band.bounds, to: content)
        XCTAssertTrue(content.recordsArea.isHidden)

        for focused in [true, false, true, false] {
            content.recordsFocused = focused
            content.layoutSubtreeIfNeeded()
            XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(topBar.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(content.controlToolbarArea.isHidden, focused)
            XCTAssertEqual(content.phoneSlot.isHidden, focused)
            XCTAssertEqual(content.recordsArea.isHidden, !focused)
            XCTAssertFalse(content.band.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(state.ask?.id, "review")
            XCTAssertTrue(topBar.superview === content.topBarArea)
            XCTAssertTrue(editor.superview === content.conversationArea)
            XCTAssertTrue(records.superview === content.recordsArea)
            XCTAssertTrue(toolbar.superview === content.controlToolbarArea)
            XCTAssertEqual(editor.string, "Retained conversation")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
            XCTAssertEqual(content.conversationArea.convert(content.conversationArea.bounds, to: content), workbenchFrame)
            XCTAssertEqual(content.topBarArea.convert(content.topBarArea.bounds, to: content), topBarFrame)
            XCTAssertEqual(content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content), toolbarFrame)
            XCTAssertEqual(content.phoneSlot.convert(content.phoneSlot.bounds, to: content), phoneFrame)
            XCTAssertEqual(content.band.convert(content.band.bounds, to: content), approvalFrame)
            XCTAssertEqual(content.nativeControlFits, !focused)
            if focused {
                let page = content.recordsArea.convert(content.recordsArea.bounds, to: content)
                XCTAssertEqual(page.width, content.dashboard.contentColumn.width - WorkbenchLayout.horizontalInset * 2)
                XCTAssertEqual(page.maxY, content.dashboard.workspace.maxY - WorkbenchLayout.immersiveTop)
                XCTAssertEqual(page.minY, approvalFrame.maxY + WorkbenchLayout.contentGap)
                XCTAssertTrue(content.dashboard.contentColumn.contains(page))
                XCTAssertFalse(page.intersects(workbenchFrame))
                XCTAssertFalse(page.intersects(topBarFrame))
                XCTAssertFalse(page.intersects(approvalFrame))
            }
        }
    }

    @MainActor func testNativeWindowUsesItsActualSizeInsideTheControlColumn() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        let slot = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        let toolbar = content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content)
        let conversation = content.conversationArea.convert(content.conversationArea.bounds, to: content)
        let topBar = content.topBarArea.convert(content.topBarArea.bounds, to: content)
        XCTAssertTrue(content.nativeControlFits)
        XCTAssertEqual(slot.size, content.phoneSize)
        XCTAssertEqual(content.controlAvailableArea.width, 1440 - WorkbenchLayout.conversationWidth - 24)
        XCTAssertEqual(slot.midX, content.controlAvailableArea.midX, "대상 창은 넓은 제어 열 위쪽 가운데에 제 크기로")
        XCTAssertEqual(slot.maxY, content.controlAvailableArea.maxY)
        XCTAssertEqual(slot.width, 300)
        XCTAssertTrue(content.controlAvailableArea.contains(slot))
        XCTAssertEqual(toolbar.width, 1440 - WorkbenchLayout.conversationWidth - 24)
        XCTAssertEqual(toolbar.minY, content.controlAvailableArea.maxY + WorkbenchLayout.contentGap)
        XCTAssertEqual(toolbar.maxX, conversation.minX - WorkbenchLayout.horizontalInset * 2)
        XCTAssertEqual(conversation.maxY, toolbar.maxY, "The shell starts where the control header starts")
        XCTAssertEqual(conversation.maxY, topBar.minY - WorkbenchLayout.immersiveTop)
    }

    @MainActor func testOutOfAreaPhoneLeavesAContainedPlaceholderAndFixedColumns() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        let conversation = content.conversationArea.convert(content.conversationArea.bounds, to: content)
        let toolbar = content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content)
        let moved = CGRect(x: conversation.minX + 12, y: 40, width: 300, height: 540)
        content.followedPhone = moved
        content.layoutSubtreeIfNeeded()
        let slot = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        XCTAssertNotEqual(slot, moved)
        XCTAssertTrue(content.controlAvailableArea.contains(slot))
        XCTAssertFalse(slot.intersects(conversation))
        XCTAssertEqual(content.conversationArea.convert(content.conversationArea.bounds, to: content), conversation)
        XCTAssertEqual(content.controlToolbarArea.convert(content.controlToolbarArea.bounds, to: content), toolbar)
    }

    @MainActor func testImpossibleNativeSizeLeavesAContainedPlaceholder() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
        content.phoneSize = CGSize(width: 900, height: 980)
        content.layoutSubtreeIfNeeded()
        let slot = content.phoneSlot.convert(content.phoneSlot.bounds, to: content)
        XCTAssertFalse(content.nativeControlFits)
        XCTAssertEqual(slot, content.controlAvailableArea)
        XCTAssertEqual(content.controlAvailableArea.width, 1100 - WorkbenchLayout.conversationWidth - 24, "제어 열 = 창의 나머지")
        XCTAssertTrue(content.bounds.contains(slot))
        XCTAssertFalse(slot.intersects(content.conversationArea.convert(content.conversationArea.bounds, to: content)))
        XCTAssertFalse(slot.intersects(content.topBarArea.convert(content.topBarArea.bounds, to: content)))
    }

    @MainActor func testNativeHoleUsesRootCoordinatesAndPreservesValidFollowedFrames() throws {
        _ = NSApplication.shared
        for width in [760, 1440] as [CGFloat] {
            let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
            content.phoneSize = CGSize(width: 240, height: 300)
            content.dockedPhone = true
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(content.nativeControlFits)
            let conversation = content.conversationArea.convert(content.conversationArea.bounds, to: content)
            let topBar = content.topBarArea.convert(content.topBarArea.bounds, to: content)
            let initial = try XCTUnwrap(content.nativeHoleRect)
            XCTAssertEqual(initial, content.phoneSlot.convert(content.phoneSlot.bounds, to: content))
            XCTAssertTrue(content.controlAvailableArea.contains(initial))
            XCTAssertFalse(initial.intersects(conversation))
            XCTAssertFalse(initial.intersects(topBar))

            let followed = CGRect(x: content.controlAvailableArea.minX + 20,
                                  y: content.controlAvailableArea.minY + 24, width: 240, height: 300)
            XCTAssertTrue(content.controlAvailableArea.contains(followed))
            content.followedPhone = followed
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.phoneSlot.convert(content.phoneSlot.bounds, to: content), followed)
            XCTAssertEqual(content.nativeHoleRect, followed)
            XCTAssertFalse(followed.intersects(conversation))
            XCTAssertFalse(followed.intersects(topBar))

            content.recordsFocused = true
            content.layoutSubtreeIfNeeded()
            XCTAssertNil(content.nativeHoleRect)
            content.recordsFocused = false
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.nativeHoleRect, followed)

            let borrower = NSView(frame: content.bounds)
            borrower.addSubview(content.phoneSlot)
            XCTAssertNil(content.nativeHoleRect, "A lent slot cannot cut a hole in its former parent")
            content.reclaimContent()
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(content.phoneSlot.superview === content.contentArea)
            XCTAssertEqual(content.nativeHoleRect, followed)

            content.dockedPhone = false
            content.layoutSubtreeIfNeeded()
            XCTAssertNil(content.nativeHoleRect)
        }
    }

    /// The empty slot says one thing: the target and its connection, or the controller's hint.
    @MainActor func testEmptySlotShowsOneLine() {
        _ = NSApplication.shared
        let slot = DockView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        XCTAssertEqual(slot.text, "iPhone · 연결 끊김")
        slot.surface = .windows
        XCTAssertEqual(slot.text, "Windows · 연결 끊김")
        slot.hint = "제어 자리 밖"
        XCTAssertEqual(slot.text, "제어 자리 밖")
        slot.hint = ""
        XCTAssertEqual(slot.text, "Windows · 연결 끊김")
        slot.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot.subviews.count, 1)
        XCTAssertTrue(slot.bounds.contains(slot.subviews[0].frame))
    }
}
