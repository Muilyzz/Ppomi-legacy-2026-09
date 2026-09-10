import AppKit
import XCTest
@testable import Ppomi

final class WorkbenchSurfaceGeometryTests: XCTestCase {
    /// 제어 열 폭 = 대상 창 폭 + 간격 2; 대화 열이 나머지를 가진다. 대상이 없거나 작으면 작은 iPhone 폭이 바닥이다.
    func testDashboardSizesTheControlColumnFromTheSurfaceWidth() {
        for origin in [CGPoint.zero, CGPoint(x: -1728, y: 90)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1728, height: 1117))
            for (surfaceWidth, expected) in [(348, 348 + 24), (900, 900 + 24), (120, 232 + 24), (0, 232 + 24)] as [(CGFloat, CGFloat)] {
                let layout = WorkbenchLayout.dashboard(in: screen, controlWidth: surfaceWidth)
                XCTAssertEqual(layout.controlColumn.width, expected)
                XCTAssertEqual(layout.controlColumn.maxX, screen.maxX)
                XCTAssertEqual(layout.conversationColumn.minX, screen.minX)
                XCTAssertEqual(layout.conversationColumn.width, screen.width - expected)
                XCTAssertEqual(layout.conversationColumn.maxX, layout.controlColumn.minX)
                XCTAssertEqual(layout.workspace.maxY, screen.maxY - WorkbenchLayout.normalTop)
                XCTAssertEqual(layout.conversationColumn.height, layout.workspace.height)
                XCTAssertEqual(layout.controlColumn.height, layout.workspace.height)
                XCTAssertTrue(screen.contains(layout.controlColumn))
                XCTAssertTrue(screen.contains(layout.conversationColumn))
            }
            let narrow = WorkbenchLayout.dashboard(in: CGRect(origin: origin, size: CGSize(width: 300, height: 600)), controlWidth: 900)
            XCTAssertEqual(narrow.controlColumn.width, 300, "The column never exceeds the window")
            XCTAssertEqual(narrow.conversationColumn.width, 0)
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
        let column = content.dashboard.controlColumn
        XCTAssertEqual(content.controlAvailableArea.minY, column.minY + WorkbenchLayout.approvalBottom)
        XCTAssertEqual(WorkbenchLayout.pane(in: column).footer.height, 0)
        XCTAssertEqual(content.workbenchArea.frame.minY, column.minY + WorkbenchLayout.approvalBottom)
        let slotWithoutBand = content.phoneSlot.frame

        state.ask = (id: "approval", text: "진행할까요?", options: ["승인", "취소"])
        content.band.sync()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.footerHeight, 0)
        XCTAssertFalse(content.band.isHidden)
        XCTAssertEqual(content.band.frame.height, content.footerHeight)
        XCTAssertEqual(content.band.frame.minY, column.minY + WorkbenchLayout.approvalBottom)
        XCTAssertGreaterThanOrEqual(content.band.frame.minX, column.minX)
        XCTAssertLessThanOrEqual(content.band.frame.maxX, column.maxX)
        XCTAssertFalse(content.band.frame.intersects(content.phoneSlot.frame))
        XCTAssertFalse(content.band.frame.intersects(content.workbenchArea.frame), "No footer under the conversation")
        XCTAssertEqual(content.phoneSlot.frame, slotWithoutBand, "A top-aligned slot keeps its place while the band appears")

        state.ask = nil
        content.band.sync()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.footerHeight, 0)
        XCTAssertTrue(content.band.isHidden)
    }

    @MainActor func testRecordsPageReplacesTheWorkspaceAndRestoresTheColumns() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        let editor = NSTextView(), records = NSView(), toolbar = NSView()
        content.mount(sidebar: editor, records: records, controlToolbar: toolbar)
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        editor.string = "Retained conversation"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        let workbenchFrame = content.workbenchArea.frame
        let toolbarFrame = content.controlToolbarArea.frame
        let phoneFrame = content.phoneSlot.frame
        XCTAssertTrue(content.recordsArea.isHidden)

        for focused in [true, false, true, false] {
            content.recordsFocused = focused
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.workbenchArea.isHidden, focused)
            XCTAssertEqual(content.controlToolbarArea.isHidden, focused)
            XCTAssertEqual(content.phoneSlot.isHidden, focused)
            XCTAssertEqual(content.recordsArea.isHidden, !focused)
            XCTAssertTrue(content.band.isHidden)
            XCTAssertTrue(editor.superview === content.workbenchArea)
            XCTAssertTrue(records.superview === content.recordsArea)
            XCTAssertTrue(toolbar.superview === content.controlToolbarArea)
            XCTAssertEqual(editor.string, "Retained conversation")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
            XCTAssertEqual(content.workbenchArea.frame, workbenchFrame)
            XCTAssertEqual(content.controlToolbarArea.frame, toolbarFrame)
            XCTAssertEqual(content.phoneSlot.frame, phoneFrame)
            XCTAssertEqual(content.nativeControlFits, !focused)
            if focused {
                let page = content.recordsArea.frame
                XCTAssertEqual(page.width, content.bounds.width - WorkbenchLayout.horizontalInset * 2)
                XCTAssertEqual(page.maxY, content.bounds.maxY - WorkbenchLayout.normalTop)
                XCTAssertEqual(page.minY, WorkbenchLayout.approvalBottom)
            }
        }
    }

    @MainActor func testNativeWindowUsesItsActualSizeInsideTheControlColumn() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.nativeControlFits)
        XCTAssertEqual(content.phoneSlot.frame.size, content.phoneSize)
        XCTAssertEqual(content.controlAvailableArea.width, 300)
        XCTAssertEqual(content.phoneSlot.frame.minX, content.controlAvailableArea.minX)
        XCTAssertEqual(content.phoneSlot.frame.maxY, content.controlAvailableArea.maxY)
        XCTAssertEqual(content.phoneSlot.frame.maxX, content.bounds.maxX - WorkbenchLayout.horizontalInset)
        XCTAssertTrue(content.controlAvailableArea.contains(content.phoneSlot.frame))
        XCTAssertEqual(content.controlToolbarArea.frame.width, 300)
        XCTAssertEqual(content.controlToolbarArea.frame.minY, content.controlAvailableArea.maxY + WorkbenchLayout.contentGap)
        XCTAssertEqual(content.workbenchArea.frame.maxX, content.controlToolbarArea.frame.minX - WorkbenchLayout.horizontalInset * 2)
        XCTAssertEqual(content.workbenchArea.frame.maxY, content.controlToolbarArea.frame.maxY, "The shell starts where the control header starts")
    }

    @MainActor func testOutOfAreaPhoneLeavesAContainedPlaceholderAndFixedColumns() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 1000))
        content.phoneSize = CGSize(width: 300, height: 540)
        content.layoutSubtreeIfNeeded()
        let conversation = content.workbenchArea.frame, toolbar = content.controlToolbarArea.frame
        let moved = CGRect(x: 24, y: 40, width: 300, height: 540)
        content.followedPhone = moved
        content.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(content.phoneSlot.frame, moved)
        XCTAssertTrue(content.controlAvailableArea.contains(content.phoneSlot.frame))
        XCTAssertFalse(content.phoneSlot.frame.intersects(content.workbenchArea.frame))
        XCTAssertEqual(content.workbenchArea.frame, conversation)
        XCTAssertEqual(content.controlToolbarArea.frame, toolbar)
    }

    @MainActor func testImpossibleNativeSizeLeavesAContainedPlaceholder() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
        content.phoneSize = CGSize(width: 900, height: 980)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.nativeControlFits)
        XCTAssertEqual(content.phoneSlot.frame, content.controlAvailableArea)
        XCTAssertEqual(content.controlAvailableArea.width, 900)
        XCTAssertTrue(content.bounds.contains(content.phoneSlot.frame))
        XCTAssertFalse(content.phoneSlot.frame.intersects(content.workbenchArea.frame))
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
