import AppKit
import XCTest
@testable import Ppomi

final class ImmersiveKioskTests: XCTestCase {
    func testBandsCoverExactlyTheScreenOutsideThePhone() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let phone = CGRect(x: 1020, y: 90, width: 348, height: 720)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone)
        assertCoverage(layout)
        XCTAssertGreaterThan(layout.sidebar.width, 600)
        XCTAssertEqual(layout.sidebar, layout.bands[layout.sidebarIndex])
    }

    func testClampedTallPhoneWithNegativeScreenOriginKeepsAllMasksOnScreen() {
        let screen = CGRect(x: -1440, y: -180, width: 1440, height: 900)
        let phone = CGRect(x: -440, y: -250, width: 348, height: 1100)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
        XCTAssertEqual(layout.phone?.height, screen.height)
        XCTAssertGreaterThan(layout.sidebar.width, 900)
    }

    func testPartlyOffscreenPhoneOnOffsetDisplayLeavesNoMaskGaps() {
        let screen = CGRect(x: 240, y: 120, width: 1280, height: 720)
        let phone = CGRect(x: 1450, y: 180, width: 348, height: 650)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
    }

    func testAbsentOrEntirelyOffscreenPhoneProducesFullCoverAndUsableSidebar() {
        let screen = CGRect(x: 300, y: -700, width: 1200, height: 700)
        for phone in [nil, CGRect(x: -900, y: 600, width: 348, height: 720)] as [CGRect?] {
            let layout = ImmersiveLayout(screen: screen, phone: phone)
            XCTAssertNil(layout.phone)
            assertCoverage(layout)
            XCTAssertEqual(layout.sidebar, screen)
        }
    }

    func testExitTargetRemainsFullSizeWhenGapAbovePhoneIsShort() {
        let screen = CGRect(x: 180, y: 220, width: 1280, height: 720)
        let phone = CGRect(x: 1060, y: 230, width: 348, height: 700)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertLessThan(screen.maxY - phone.maxY, 48)
        XCTAssertEqual(layout.exitFrame.size, CGSize(width: 48, height: 48))
        XCTAssertTrue(screen.contains(layout.exitFrame))
        assertCoverage(layout)
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

    func testAgentBandsCoverOnlyTheSidebarOutsideTheSecondHole() throws {
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: -180), CGPoint(x: 240, y: 120)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
            let phone = CGRect(x: screen.minX + 1050, y: screen.minY + 80, width: 300, height: 740)
            let phoneLayout = ImmersiveLayout(screen: screen, phone: phone)
            let available = ImmersiveAgentLayout.availableArea(in: phoneLayout.sidebar, bandHeight: 116, toolbarHeight: 40)
            let agent = available.insetBy(dx: 20, dy: 30)
            let agentLayout = try XCTUnwrap(ImmersiveAgentLayout(sidebar: phoneLayout.sidebar, agent: agent,
                                                                bandHeight: 116, toolbarHeight: 40))
            XCTAssertEqual(agentLayout.agent, agent)
            let covers = phoneLayout.bands.enumerated().compactMap { $0.offset == phoneLayout.sidebarIndex ? nil : $0.element }
                + agentLayout.bands
            assertCoverage(screen: screen, covers: covers, holes: [phone, agent])
        }
    }

    func testAgentCanUseTheFullScreenSidebarWhenThereIsNoPhone() throws {
        let screen = CGRect(x: -800, y: 240, width: 1200, height: 800)
        let phoneLayout = ImmersiveLayout(screen: screen, phone: nil)
        let agent = ImmersiveAgentLayout.availableArea(in: phoneLayout.sidebar, bandHeight: 116, toolbarHeight: 40)
        let layout = try XCTUnwrap(ImmersiveAgentLayout(sidebar: phoneLayout.sidebar, agent: agent,
                                                       bandHeight: 116, toolbarHeight: 40))
        assertCoverage(screen: screen, covers: layout.bands, holes: [agent])
    }

    @MainActor func testAgentAvailableAreaMatchesToolbarAndApprovalReservations() throws {
        let sidebar = CGRect(x: -980, y: -120, width: 800, height: 820)
        let available = ImmersiveKiosk.agentAvailableArea(in: sidebar, bandHeight: 116)
        XCTAssertEqual(available, CGRect(x: -968, y: 16, width: 776, height: 632))
        let layout = try XCTUnwrap(ImmersiveAgentLayout(sidebar: sidebar, agent: available,
                                                       bandHeight: 116, toolbarHeight: AgentSidebar.toolbarHeight))
        XCTAssertEqual(layout.bands[0].height, 52)
        XCTAssertEqual(layout.bands[1].height, 136)
        XCTAssertEqual(layout.bands[2].width, 12)
        XCTAssertEqual(layout.bands[3].width, 12)
        assertCoverage(screen: sidebar, covers: layout.bands, holes: [available])
    }

    func testAgentMustFitEntirelyInsideTheReservedArea() {
        let sidebar = CGRect(x: 40, y: -600, width: 780, height: 900)
        let available = ImmersiveAgentLayout.availableArea(in: sidebar, bandHeight: 116, toolbarHeight: 40)
        for agent in [available.offsetBy(dx: -1, dy: 0), available.offsetBy(dx: 1, dy: 0),
                      available.offsetBy(dx: 0, dy: -1), available.offsetBy(dx: 0, dy: 1), sidebar,
                      CGRect(origin: available.origin, size: .zero)] {
            XCTAssertNil(ImmersiveAgentLayout(sidebar: sidebar, agent: agent, bandHeight: 116, toolbarHeight: 40))
        }
    }

    func testExpandedApprovalBandCanInvalidateAnExistingAgentHole() throws {
        let sidebar = CGRect(x: 0, y: 0, width: 600, height: 800)
        let agent = ImmersiveAgentLayout.availableArea(in: sidebar, bandHeight: 116, toolbarHeight: 40)
        XCTAssertNotNil(ImmersiveAgentLayout(sidebar: sidebar, agent: agent, bandHeight: 116, toolbarHeight: 40))
        XCTAssertNil(ImmersiveAgentLayout(sidebar: sidebar, agent: agent, bandHeight: 180, toolbarHeight: 40))
        let resizedAgent = ImmersiveAgentLayout.availableArea(in: sidebar, bandHeight: 180, toolbarHeight: 40)
        let resized = try XCTUnwrap(ImmersiveAgentLayout(sidebar: sidebar, agent: resizedAgent,
                                                        bandHeight: 180, toolbarHeight: 40))
        assertCoverage(screen: sidebar, covers: resized.bands, holes: [resizedAgent])
    }

    func testTooSmallSidebarHasNoAgentOpening() {
        for sidebar in [CGRect(x: 0, y: 0, width: 24, height: 900), CGRect(x: 0, y: 0, width: 700, height: 188)] {
            let available = ImmersiveAgentLayout.availableArea(in: sidebar, bandHeight: 116, toolbarHeight: 40)
            XCTAssertTrue(available.isEmpty)
            XCTAssertNil(ImmersiveAgentLayout(sidebar: sidebar, agent: available, bandHeight: 116, toolbarHeight: 40))
        }
    }

    @MainActor func testAgentToolbarAndApprovalViewsReturnToTheOriginalSidebar() throws {
        _ = NSApplication.shared
        let sidebar = AgentSidebar(records: NSView(), state: AppState())
        let toolbar = sidebar.toolbar
        let band = PhoneBand()
        let fullHost = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 820))
        ImmersiveKiosk.mount(workbench: sidebar, band: band, in: fullHost)
        sidebar.layoutSubtreeIfNeeded()
        let available = ImmersiveKiosk.agentAvailableArea(in: fullHost.bounds, bandHeight: band.preferredHeight(for: 776))
        let layout = try XCTUnwrap(ImmersiveAgentLayout(sidebar: fullHost.bounds, agent: available,
                                                       bandHeight: band.preferredHeight(for: 776), toolbarHeight: AgentSidebar.toolbarHeight))
        let top = NSView(frame: CGRect(origin: .zero, size: layout.bands[0].size))
        let bottom = NSView(frame: CGRect(origin: .zero, size: layout.bands[1].size))

        for _ in 0..<2 {
            ImmersiveKiosk.mountAgentControls(toolbar: toolbar, band: band, top: top, bottom: bottom,
                                              toolbarHeight: AgentSidebar.toolbarHeight)
            XCTAssertTrue(sidebar.toolbar === toolbar)
            XCTAssertTrue(toolbar.superview === top)
            XCTAssertTrue(band.superview === bottom)
            XCTAssertTrue(top.bounds.contains(toolbar.frame))
            XCTAssertTrue(bottom.bounds.contains(band.frame))
            let borrowedToolbarFrame = toolbar.frame
            sidebar.frame.size = CGSize(width: 480, height: 500)
            sidebar.layout()
            XCTAssertEqual(toolbar.frame, borrowedToolbarFrame, "The hidden sidebar must not reposition its lent toolbar")

            ImmersiveKiosk.mount(workbench: sidebar, band: band, in: fullHost)
            sidebar.layoutSubtreeIfNeeded()
            XCTAssertTrue(sidebar.superview === fullHost)
            XCTAssertTrue(toolbar.superview === sidebar)
            XCTAssertTrue(band.superview === fullHost)
            XCTAssertFalse(top.subviews.contains { $0 === toolbar })
            XCTAssertFalse(bottom.subviews.contains { $0 === band })
            XCTAssertEqual(sidebar.subviews.filter { $0 === toolbar }.count, 1)
            XCTAssertNil(toolbar.window)
            XCTAssertNil(band.window)
        }
    }

    @MainActor func testMountingRetainsTheSameWorkbenchAndApprovalViewsWithoutShowingWindows() {
        _ = NSApplication.shared
        let workbench = NSView()
        let band = PhoneBand()
        let originalHost = NSView(frame: CGRect(x: 0, y: 0, width: 620, height: 900))
        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))

        for host in [originalHost, immersiveHost, originalHost] {
            ImmersiveKiosk.mount(workbench: workbench, band: band, in: host)
            ImmersiveKiosk.layoutContent(workbench: workbench, band: band, in: host.bounds)
            XCTAssertTrue(workbench.superview === host)
            XCTAssertTrue(band.superview === host)
            XCTAssertEqual(host.subviews.filter { $0 === workbench }.count, 1)
            XCTAssertEqual(host.subviews.filter { $0 === band }.count, 1)
            XCTAssertTrue(host.bounds.contains(workbench.frame))
            XCTAssertTrue(host.bounds.contains(band.frame))
            XCTAssertFalse(workbench.frame.intersects(band.frame))
            XCTAssertGreaterThan(workbench.frame.height, 0)
            XCTAssertGreaterThan(band.frame.height, 0)
            XCTAssertNil(workbench.window)
            XCTAssertNil(band.window)
        }
        XCTAssertFalse(immersiveHost.subviews.contains { $0 === workbench || $0 === band })
    }

    @MainActor func testSuspendedNormalLayoutCannotResizeViewsLentToImmersiveHost() {
        _ = NSApplication.shared
        let originalFrame = CGRect(x: 0, y: 0, width: 940, height: 894)
        let content = WorkbenchContent(frame: originalFrame)
        let workbench = NSView()
        content.workbench = workbench
        content.workbenchArea.addSubview(workbench)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        let normalWorkbenchFrame = workbench.frame
        let normalBandFrame = content.band.frame
        XCTAssertGreaterThan(normalWorkbenchFrame.height, 0)

        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))
        content.layoutSuspended = true
        ImmersiveKiosk.mount(workbench: workbench, band: content.band, in: immersiveHost)
        let immersiveWorkbenchFrame = workbench.frame
        let immersiveBandFrame = content.band.frame
        XCTAssertNotEqual(immersiveWorkbenchFrame, normalWorkbenchFrame)

        // A hidden normal host can still receive layout while its existing views belong to another window.
        content.frame.size = CGSize(width: 1240, height: 1080)
        content.layout()
        XCTAssertTrue(workbench.superview === immersiveHost)
        XCTAssertTrue(content.band.superview === immersiveHost)
        XCTAssertEqual(workbench.frame, immersiveWorkbenchFrame)
        XCTAssertEqual(content.band.frame, immersiveBandFrame)

        content.frame = originalFrame
        content.workbenchArea.addSubview(workbench)
        content.addSubview(content.band)
        content.layoutSuspended = false
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertTrue(content.band.superview === content)
        XCTAssertEqual(workbench.frame, normalWorkbenchFrame)
        XCTAssertEqual(content.band.frame, normalBandFrame)
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
