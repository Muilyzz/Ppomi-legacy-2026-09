import AppKit
import XCTest
@testable import Ppomi

final class ImmersiveKioskTests: XCTestCase {
    @MainActor func testCompactContentUsesOneWindowHostAndKeepsChatAndRecordsMounted() {
        _ = NSApplication.shared
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 760))
        let editor = NSTextView(), records = NSView(), footer = NSView(), overlay = NSView()
        ImmersiveKiosk.mountConversation(workbench: editor, in: host)
        editor.string = "Retained conversation"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        let viewport = editor.frame
        for presented in [false, true, false, true, false] {
            ImmersiveKiosk.mountCompactContent(records, footer: footer, footerHeight: 116, presented: presented,
                                              in: overlay, over: host, conversation: editor)
            XCTAssertTrue(editor.superview === host)
            XCTAssertTrue(overlay.superview === host)
            XCTAssertTrue(records.superview === overlay)
            XCTAssertTrue(footer.superview === overlay)
            XCTAssertEqual(host.subviews.count, 2)
            XCTAssertTrue(host.subviews.last === overlay)
            XCTAssertEqual(overlay.subviews.count, 2)
            XCTAssertEqual(overlay.isHidden, !presented)
            XCTAssertEqual(footer.isHiddenOrHasHiddenAncestor, !presented)
            XCTAssertFalse(editor.isHidden)
            XCTAssertEqual(editor.frame, viewport)
            XCTAssertEqual(editor.string, "Retained conversation")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
            XCTAssertEqual(overlay.frame, host.bounds)
            XCTAssertTrue(overlay.bounds.contains(records.frame))
            XCTAssertTrue(overlay.bounds.contains(footer.frame))
            XCTAssertFalse(records.frame.intersects(footer.frame))
            XCTAssertNil(editor.window)
            XCTAssertNil(records.window)
        }
        // Lending and returning chat can change sibling order; the overlay must still cover that same chat.
        let borrower = NSView()
        borrower.addSubview(editor)
        ImmersiveKiosk.mountConversation(workbench: editor, in: host)
        ImmersiveKiosk.mountCompactContent(records, footer: footer, footerHeight: 116, presented: true,
                                          in: overlay, over: host, conversation: editor)
        XCTAssertTrue(host.subviews.last === overlay)
        XCTAssertTrue(editor.superview === host)
        XCTAssertTrue(records.superview === overlay)
        XCTAssertEqual(editor.string, "Retained conversation")
    }

    func testBandsCoverExactlyTheScreenOutsideThePhone() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let phone = CGRect(x: 1020, y: 90, width: 348, height: 720)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone)
        assertCoverage(layout)
    }

    func testClampedTallPhoneWithNegativeScreenOriginKeepsAllMasksOnScreen() {
        let screen = CGRect(x: -1440, y: -180, width: 1440, height: 900)
        let phone = CGRect(x: -440, y: -250, width: 348, height: 1100)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
        XCTAssertEqual(layout.phone?.height, screen.height)
    }

    func testPartlyOffscreenPhoneOnOffsetDisplayLeavesNoMaskGaps() {
        let screen = CGRect(x: 240, y: 120, width: 1280, height: 720)
        let phone = CGRect(x: 1450, y: 180, width: 348, height: 650)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
    }

    func testAbsentOrEntirelyOffscreenPhoneProducesFullCover() {
        let screen = CGRect(x: 300, y: -700, width: 1200, height: 700)
        for phone in [nil, CGRect(x: -900, y: 600, width: 348, height: 720)] as [CGRect?] {
            let layout = ImmersiveLayout(screen: screen, phone: phone)
            XCTAssertNil(layout.phone)
            assertCoverage(layout)
            XCTAssertEqual(layout.bands[2], screen)
        }
    }

    @MainActor func testRecordsCoverOnlyTheLeftSideWhileTopBarAndConversationStayVisible() {
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: -180), CGPoint(x: 240, y: 120)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 1000))
            let normal = ImmersiveKiosk.layout(screen: screen, phone: nil)
            let phone = WorkbenchLayout.topAlignedWindow(size: CGSize(width: 300, height: 350), in: normal.controlArea)
            let records = ImmersiveKiosk.layout(screen: screen, phone: phone, showsRecords: true, footerHeight: 116)
            XCTAssertNil(records.controls.phone)
            XCTAssertTrue(records.controlArea.isEmpty)
            XCTAssertEqual(records.sidebar, normal.sidebar)
            XCTAssertEqual(records.topBar, normal.topBar)
            XCTAssertFalse(records.sidebar.isEmpty)
            XCTAssertEqual(records.recordsCover, records.dashboard.contentColumn)
            XCTAssertTrue(normal.recordsCover.isEmpty)
            assertCoverage(screen: screen, covers: [records.topBar, records.recordsCover, records.sidebar] + records.controls.bands, holes: [])
        }
    }

    @MainActor func testRecordsAndControlKeepTheSameVisibleConversation() {
        _ = NSApplication.shared
        let sidebar = AgentSidebar(state: AppState())
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        ImmersiveKiosk.mountConversation(workbench: sidebar, in: host)
        let conversationFrame = sidebar.frame
        XCTAssertEqual(conversationFrame, WorkbenchLayout.pane(in: host.bounds).content)

        for showsRecords in [true, false, true, false] {
            let layout = ImmersiveKiosk.layout(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                              phone: nil, showsRecords: showsRecords)
            XCTAssertGreaterThan(layout.sidebar.height, 0)
            ImmersiveKiosk.mountConversation(workbench: sidebar, in: host)
            XCTAssertFalse(sidebar.isHidden)
            XCTAssertTrue(sidebar.superview === host)
            XCTAssertEqual(sidebar.frame, conversationFrame, "Content navigation leaves conversation geometry intact")
            XCTAssertEqual(host.subviews.count, 1)
        }
    }

    func testConversationAndControlColumnsCoverTheScreenAroundThePhone() {
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: -180), CGPoint(x: 240, y: 120)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 1000))
            for footer in [CGFloat(0), 116] {
                let base = ImmersiveDashboardLayout(screen: screen, phone: nil, footerHeight: footer)
                let phone = WorkbenchLayout.topAlignedWindow(size: CGSize(width: 300, height: 440), in: base.controlArea)
                let layout = ImmersiveDashboardLayout(screen: screen, phone: phone, footerHeight: footer)
                XCTAssertEqual(layout.controls.phone, phone)
                XCTAssertEqual(layout.sidebar.maxX, screen.maxX)
                XCTAssertEqual(layout.sidebar.width, WorkbenchLayout.conversationWidth, "대화 열은 폰 폭으로 고정")
                XCTAssertEqual(layout.controlArea.width, screen.width - WorkbenchLayout.conversationWidth - WorkbenchLayout.horizontalInset * 2)
                XCTAssertTrue(layout.recordsCover.isEmpty)
                assertCoverage(screen: screen, covers: [layout.topBar, layout.sidebar] + layout.controls.bands, holes: [phone])
            }
        }
    }

    func testMovedOrAbsentPhoneCannotChangeTheConversationColumn() {
        let screen = CGRect(x: -1280, y: 80, width: 1280, height: 900)
        let absent = ImmersiveDashboardLayout(screen: screen, phone: nil)
        let movedPhone = CGRect(x: absent.sidebar.minX + 20, y: screen.minY + 20, width: 300, height: 700)
        let moved = ImmersiveDashboardLayout(screen: screen, phone: movedPhone)
        XCTAssertNil(absent.controls.phone)
        XCTAssertNil(moved.controls.phone)
        XCTAssertEqual(moved.sidebar, absent.sidebar)
        XCTAssertEqual(moved.topBar, absent.topBar)
        assertCoverage(screen: screen, covers: [moved.topBar, moved.sidebar] + moved.controls.bands, holes: [])
    }

    func testPartlyOutOfAreaSmallPhoneNeverCreatesAPartialHole() {
        let screen = CGRect(x: -1440, y: 80, width: 1440, height: 1000)
        let base = ImmersiveDashboardLayout(screen: screen, phone: nil)
        let area = base.controlArea
        let outsideFrames = [
            CGRect(x: area.minX - 20, y: area.minY + 20, width: 300, height: 400),
            CGRect(x: area.minX + 20, y: area.maxY - 380, width: 300, height: 400),
        ]
        for phone in outsideFrames {
            XCTAssertTrue(area.intersects(phone))
            let layout = ImmersiveDashboardLayout(screen: screen, phone: phone)
            XCTAssertNil(layout.controls.phone)
            XCTAssertEqual(layout.sidebar, base.sidebar)
            assertCoverage(screen: screen, covers: [layout.topBar, layout.sidebar] + layout.controls.bands, holes: [])
        }
    }

    func testExitTargetStaysInsideTheTopBar() {
        let screen = CGRect(x: 180, y: 220, width: 1280, height: 720)
        let layout = ImmersiveDashboardLayout(screen: screen, phone: nil)
        XCTAssertEqual(layout.exitFrame.size, CGSize(width: 48, height: min(48, layout.topBar.height)))
        XCTAssertTrue(layout.topBar.contains(layout.exitFrame))
        XCTAssertEqual(layout.exitFrame.maxX, screen.maxX)
        XCTAssertEqual(layout.exitFrame.maxY, screen.maxY)
    }

    func testCompactLayoutDefaultsToChatAndOnlyExplicitlyCoversItWithContent() {
        let screen = CGRect(x: -500, y: 80, width: 400, height: 800)
        for showsRecords in [true, false] {
            let base = ImmersiveDashboardLayout(screen: screen, phone: nil, showsRecords: showsRecords)
            XCTAssertEqual(base.topBar.width, screen.width)
            XCTAssertEqual(base.sidebar.width, screen.width)
            XCTAssertEqual(base.dashboard.contentColumn.width, screen.width)
            XCTAssertEqual(base.sidebar.maxY, base.topBar.minY)
            XCTAssertTrue(base.dashboard.isCompact)
            XCTAssertEqual(base.sidebar, base.dashboard.workspace)
            XCTAssertTrue(base.recordsCover.isEmpty, "Idle status and parking do not open compact content")
            XCTAssertFalse(base.showsRecords)
            XCTAssertTrue(base.controlArea.isEmpty)
            XCTAssertTrue(base.controls.bands.allSatisfy(\.isEmpty))
            // Compact mode never exposes even a small native hole over the conversation.
            let phone = CGRect(x: screen.minX + 20, y: screen.minY + 20, width: 300, height: 540)
            let layout = ImmersiveDashboardLayout(screen: screen, phone: phone, showsRecords: showsRecords)
            XCTAssertNil(layout.controls.phone)
            assertCoverage(screen: screen, covers: [layout.topBar, layout.sidebar, layout.recordsCover] + layout.controls.bands, holes: [])
            let opened = ImmersiveDashboardLayout(screen: screen, phone: phone,
                                                   showsRecords: showsRecords, footerHeight: 116, compactContentPresented: true)
            XCTAssertEqual(opened.sidebar, base.sidebar, "The covered chat keeps its full viewport")
            XCTAssertEqual(opened.recordsCover, base.sidebar)
            XCTAssertTrue(opened.showsRecords)
            XCTAssertNil(opened.controls.phone)
            XCTAssertTrue(opened.controlArea.isEmpty)
            assertCoverage(screen: screen, covers: [opened.topBar, opened.recordsCover], holes: [])
        }
    }

    func testKeyboardRevealsExitAndEscapeRequiresTwoDistinctPresses() {
        var state = ImmersiveExitState()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.keyPressed(isEscape: false, isRepeat: false))
        XCTAssertTrue(state.isVisible)

        state.reset()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.keyPressed(isEscape: true, isRepeat: false))
        XCTAssertTrue(state.isVisible)
        for _ in 0..<5 { XCTAssertFalse(state.keyPressed(isEscape: true, isRepeat: true)) }
        XCTAssertTrue(state.keyPressed(isEscape: true, isRepeat: false))

        state.reset()
        state.reveal()
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.keyPressed(isEscape: true, isRepeat: false))
    }

    @MainActor func testMountingRetainsTheSameConversationWithoutShowingWindows() {
        _ = NSApplication.shared
        let workbench = NSView()
        let originalHost = NSView(frame: CGRect(x: 0, y: 0, width: 620, height: 900))
        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))

        for host in [originalHost, immersiveHost, originalHost] {
            ImmersiveKiosk.mountConversation(workbench: workbench, in: host)
            ImmersiveKiosk.layoutConversation(workbench: workbench, in: host.bounds)
            XCTAssertTrue(workbench.superview === host)
            XCTAssertEqual(host.subviews.filter { $0 === workbench }.count, 1)
            XCTAssertTrue(host.bounds.contains(workbench.frame))
            XCTAssertEqual(workbench.frame.minY, WorkbenchLayout.approvalBottom, "No footer under the conversation")
            XCTAssertGreaterThan(workbench.frame.height, 0)
            XCTAssertNil(workbench.window)
        }
        XCTAssertFalse(immersiveHost.subviews.contains { $0 === workbench })
    }

    @MainActor func testRecordViewReturnsBetweenHostsWithItsSelectionAndPadding() {
        _ = NSApplication.shared
        let records = NSTabView()
        let first = NSTabViewItem(identifier: "timeline")
        let selected = NSTabViewItem(identifier: "evidence")
        records.addTabViewItem(first)
        records.addTabViewItem(selected)
        records.selectTabViewItem(selected)
        let normalHost = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 880))
        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))

        for host in [normalHost, immersiveHost, normalHost] {
            ImmersiveKiosk.mountRecords(records, in: host)
            ImmersiveKiosk.mountRecords(records, in: host)
            XCTAssertTrue(records.superview === host)
            XCTAssertEqual(host.subviews.filter { $0 === records }.count, 1)
            XCTAssertTrue(records.selectedTabViewItem === selected)
            XCTAssertEqual(records.frame.minX, 12)
            XCTAssertEqual(records.frame.minY, 8)
            XCTAssertEqual(host.bounds.maxX - records.frame.maxX, 12)
            XCTAssertEqual(host.bounds.maxY - records.frame.maxY, 12)
            XCTAssertTrue(host.bounds.contains(records.frame))
            XCTAssertNil(records.window)
        }
        XCTAssertFalse(immersiveHost.subviews.contains { $0 === records })
    }

    @MainActor func testApprovalStaysUnderRecordsWithinTheRightHost() {
        _ = NSApplication.shared
        let records = NSView(), band = NSView()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 800))
        for footerHeight in [CGFloat(116), 0, 116] {
            ImmersiveKiosk.mountRecords(records, footer: band, footerHeight: footerHeight, in: host)
            XCTAssertTrue(records.superview === host)
            XCTAssertTrue(band.superview === host)
            XCTAssertEqual(band.isHidden, footerHeight == 0)
            XCTAssertEqual(band.frame.height, footerHeight)
            XCTAssertTrue(host.bounds.contains(records.frame))
            XCTAssertGreaterThan(records.frame.height, 0)
            if footerHeight > 0 {
                XCTAssertTrue(host.bounds.contains(band.frame))
                XCTAssertEqual(records.frame.minY, band.frame.maxY + WorkbenchLayout.contentGap)
                XCTAssertFalse(records.frame.intersects(band.frame))
            }
        }
    }

    @MainActor func testTopBarReservesExitSpaceAndRetainsTheSameAccountView() {
        _ = NSApplication.shared
        let topBar = NSTextView()
        topBar.string = "Retained account view"
        let first = NSView(frame: CGRect(x: 0, y: 0, width: 1440, height: 40))
        let second = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        for host in [first, second, first] {
            ImmersiveKiosk.mountTopBar(topBar, in: host)
            XCTAssertTrue(topBar.superview === host)
            XCTAssertEqual(host.subviews.filter { $0 === topBar }.count, 1)
            XCTAssertEqual(topBar.string, "Retained account view")
            XCTAssertFalse(topBar.isHidden)
            XCTAssertTrue(host.bounds.contains(topBar.frame))
            XCTAssertEqual(topBar.frame.minX, WorkbenchLayout.horizontalInset)
            XCTAssertEqual(host.bounds.maxX - topBar.frame.maxX, WorkbenchLayout.horizontalInset + 48)
            XCTAssertEqual(topBar.frame.height, host.bounds.height)
        }
        XCTAssertTrue(second.subviews.isEmpty)
    }

    @MainActor func testNormalParentsCannotResizeLentViewsAndReclaimTheSameContent() {
        _ = NSApplication.shared
        let originalFrame = CGRect(x: 0, y: 0, width: 940, height: 894)
        let content = WorkbenchContent(frame: originalFrame)
        let topBar = NSView(), workbench = NSView(), records = NSView(), controlToolbar = NSView()
        content.mount(topBar: topBar, sidebar: workbench, records: records, controlToolbar: controlToolbar)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        let normalWorkbenchFrame = workbench.frame
        let normalTopBarFrame = topBar.frame
        let normalBandFrame = content.band.frame
        let normalRecordsFrame = records.frame
        let normalToolbarFrame = controlToolbar.frame
        XCTAssertGreaterThan(normalWorkbenchFrame.height, 0)

        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))
        let topBarHost = NSView(frame: CGRect(x: 0, y: 0, width: 1240, height: 40))
        let recordsHost = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        let controlTop = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 64))
        let controlBottom = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 200))
        ImmersiveKiosk.mountTopBar(topBar, in: topBarHost)
        ImmersiveKiosk.mountConversation(workbench: workbench, in: immersiveHost)
        ImmersiveKiosk.mountPaneControls(toolbar: controlToolbar, footer: content.band, footerHeight: 116,
                                        top: controlTop, bottom: controlBottom)
        ImmersiveKiosk.mountRecords(records, in: recordsHost)
        let immersiveWorkbenchFrame = workbench.frame
        let immersiveTopBarFrame = topBar.frame
        let immersiveBandFrame = content.band.frame
        let immersiveRecordsFrame = records.frame
        let immersiveToolbarFrame = controlToolbar.frame
        XCTAssertNotEqual(immersiveWorkbenchFrame, normalWorkbenchFrame)
        XCTAssertNotEqual(immersiveBandFrame, normalBandFrame)

        // A hidden normal host can still receive layout while its existing views belong to another window.
        content.frame.size = CGSize(width: 1240, height: 1080)
        content.layout()
        content.conversationArea.layout()
        content.topBarArea.layout()
        content.contentArea.layout()
        content.recordsArea.layout()
        content.controlToolbarArea.layout()
        XCTAssertTrue(workbench.superview === immersiveHost)
        XCTAssertTrue(topBar.superview === topBarHost)
        XCTAssertTrue(content.band.superview === controlBottom)
        XCTAssertTrue(controlToolbar.superview === controlTop)
        XCTAssertTrue(records.superview === recordsHost)
        XCTAssertEqual(workbench.frame, immersiveWorkbenchFrame)
        XCTAssertEqual(topBar.frame, immersiveTopBarFrame)
        XCTAssertEqual(content.band.frame, immersiveBandFrame)
        XCTAssertEqual(records.frame, immersiveRecordsFrame)
        XCTAssertEqual(controlToolbar.frame, immersiveToolbarFrame)

        content.frame = originalFrame
        content.reclaimContent()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(workbench.superview === content.conversationArea)
        XCTAssertTrue(topBar.superview === content.topBarArea)
        XCTAssertTrue(content.band.superview === content.contentArea)
        XCTAssertTrue(records.superview === content.recordsArea)
        XCTAssertTrue(controlToolbar.superview === content.controlToolbarArea)
        XCTAssertEqual(workbench.frame, normalWorkbenchFrame)
        XCTAssertEqual(topBar.frame, normalTopBarFrame)
        XCTAssertEqual(content.band.frame, normalBandFrame)
        XCTAssertEqual(records.frame, normalRecordsFrame)
        XCTAssertEqual(controlToolbar.frame, normalToolbarFrame)
        XCTAssertTrue(immersiveHost.subviews.isEmpty)
        XCTAssertTrue(topBarHost.subviews.isEmpty)
        XCTAssertTrue(recordsHost.subviews.isEmpty)
        XCTAssertTrue(controlTop.subviews.isEmpty)
        XCTAssertTrue(controlBottom.subviews.isEmpty)
        XCTAssertNil(workbench.window)
        XCTAssertNil(content.band.window)
    }

    private func assertCoverage(_ layout: ImmersiveLayout, file: StaticString = #filePath, line: UInt = #line) {
        let masks = layout.bands.filter { $0.width > 0 && $0.height > 0 }
        let hole = layout.phone
        for (index, mask) in masks.enumerated() {
            XCTAssertTrue(layout.screen.contains(mask), "A mask extends outside the display", file: file, line: line)
            if let hole {
                XCTAssertEqual(area(mask.intersection(hole)), 0, accuracy: 0.001,
                               "A mask obscures the phone", file: file, line: line)
            }
            for other in masks.dropFirst(index + 1) {
                XCTAssertEqual(area(mask.intersection(other)), 0, accuracy: 0.001,
                               "Masks overlap", file: file, line: line)
            }
        }
        XCTAssertEqual(masks.reduce(0) { $0 + area($1) } + (hole.map(area) ?? 0), area(layout.screen),
                       accuracy: 0.001, "The screen has an uncovered gap", file: file, line: line)
    }

    private func assertCoverage(screen: CGRect, covers: [CGRect], holes: [CGRect],
                                file: StaticString = #filePath, line: UInt = #line) {
        let masks = covers.filter { !$0.isEmpty }
        for (index, mask) in masks.enumerated() {
            XCTAssertTrue(screen.contains(mask), "A cover extends outside the display", file: file, line: line)
            for hole in holes {
                XCTAssertEqual(area(mask.intersection(hole)), 0, accuracy: 0.001,
                               "A cover obscures a native window", file: file, line: line)
            }
            for other in masks.dropFirst(index + 1) {
                XCTAssertEqual(area(mask.intersection(other)), 0, accuracy: 0.001,
                               "Covers overlap", file: file, line: line)
            }
        }
        for (index, hole) in holes.enumerated() {
            XCTAssertTrue(screen.contains(hole), file: file, line: line)
            for other in holes.dropFirst(index + 1) {
                XCTAssertEqual(area(hole.intersection(other)), 0, accuracy: 0.001,
                               "Native window openings overlap", file: file, line: line)
            }
        }
        XCTAssertEqual(masks.reduce(0) { $0 + area($1) } + holes.reduce(0) { $0 + area($1) }, area(screen),
                       accuracy: 0.001, "The display has an extra uncovered gap", file: file, line: line)
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
