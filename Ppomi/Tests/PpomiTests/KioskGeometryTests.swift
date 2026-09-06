import AppKit
import XCTest
@testable import Ppomi

final class KioskGeometryTests: XCTestCase {
    /// Accessibility activation does not emit mouseDown. Both ways must invoke the actual green-button action.
    @MainActor func testGreenButtonUsesKioskActionForClickAndAccessibilityPress() throws {
        _ = NSApplication.shared
        let panel = MainPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 894),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var toggles = 0
        panel.bindKioskButton { toggles += 1 }
        let button = try XCTUnwrap(panel.standardWindowButton(.zoomButton))
        let originalFrame = panel.frame
        button.performClick(nil)
        XCTAssertEqual(toggles, 1)
        _ = button.accessibilityPerformPress() // an unshown accessibility element may report false after sending its action
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertFalse(panel.isVisible)
    }

    /// Configure an unshown native panel: the first layout must already provide room for content and approvals.
    @MainActor func testFullWindowStaysFixedAcrossPhoneSizesWithoutShowingAWindow() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let panel = makePanel(content)
        defer { panel.close() }
        let workbench = NSView(frame: .zero)
        content.workbench = workbench
        content.workbenchArea.addSubview(workbench)

        let display = CGRect(x: 40, y: 30, width: 1440, height: 980)
        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 348, height: 766), in: display)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, display)
        XCTAssertEqual(panel.contentMinSize, display.size)
        XCTAssertEqual(panel.contentMaxSize, display.size)
        XCTAssertEqual(content.phoneSlot.bounds.size, CGSize(width: 348, height: 766))
        XCTAssertGreaterThanOrEqual(workbench.frame.width, 536)
        XCTAssertGreaterThan(workbench.frame.height, 600)
        XCTAssertGreaterThan(content.workbenchArea.frame.minY, content.band.frame.maxY)
        XCTAssertFalse(content.band.frame.intersects(content.phoneSlot.frame))
        XCTAssertTrue(content.bounds.contains(content.band.frame))

        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 300, height: 650), in: display)
        XCTAssertEqual(panel.frame, display)
        XCTAssertEqual(panel.contentMinSize, display.size)
        XCTAssertEqual(content.phoneSlot.bounds.size, CGSize(width: 300, height: 650))
        XCTAssertGreaterThan(workbench.frame.height, 500)
        XCTAssertTrue(content.bounds.contains(content.band.frame))
    }

    /// An expanded display may be shorter than a large iPhone. Its previous minimum must not prevent fitting the display.
    @MainActor func testExpansionFitsSmallerVisibleFrameAndRestoresSamePanelAndContent() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        let workbench = NSView(frame: .zero)
        content.workbench = workbench
        content.workbenchArea.addSubview(workbench)
        let phone = CGSize(width: 446, height: 978)
        KioskController.fitMain(panel, content: content, phoneSize: phone, in: CGRect(x: 0, y: 30, width: 1440, height: 1000))
        let savedFrame = panel.frame
        let panelIdentity = ObjectIdentifier(panel)
        let smallerDisplay = CGRect(x: 140, y: 60, width: 960, height: 720)
        XCTAssertGreaterThan(panel.contentMinSize.width, smallerDisplay.width)
        XCTAssertGreaterThan(panel.contentMinSize.height, smallerDisplay.height)

        KioskController.fitExpanded(panel, content: content, in: smallerDisplay)
        XCTAssertEqual(panel.frame, smallerDisplay)
        XCTAssertTrue(content.expanded)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertEqual(ObjectIdentifier(panel), panelIdentity)
        XCTAssertTrue(panel.contentView === content)
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertFalse(panel.isVisible)

        // The controller restores its saved frame before applying the normal workbench constraints.
        content.expanded = false
        content.followedPhone = nil
        panel.contentMinSize = .zero
        panel.contentMaxSize = CGSize(width: 10000, height: 10000)
        panel.setFrame(savedFrame, display: true)
        KioskController.fitMain(panel, content: content, phoneSize: phone, in: CGRect(x: 0, y: 30, width: 1440, height: 1000))
        XCTAssertEqual(panel.frame, savedFrame)
        XCTAssertFalse(content.expanded)
        XCTAssertEqual(ObjectIdentifier(panel), panelIdentity)
        XCTAssertTrue(panel.contentView === content)
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertFalse(panel.isVisible)
    }

    /// The phone may extend beyond a short display, but the human approval buttons must remain visible beside it.
    @MainActor func testTallPhoneKeepsApprovalButtonsInVisibleSidebar() throws {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        let state = AppState()
        state.phase = .humanTurn(reason: "승인 대기")
        state.ask = (id: "layout-check", text: "진행할까요?", options: ["결제 승인", "취소"])
        content.band.state = state
        content.band.sync()
        content.phoneSize = CGSize(width: 446, height: 978)
        KioskController.fitExpanded(panel, content: content, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertGreaterThan(content.phoneSlot.frame.maxY, content.bounds.maxY)
        XCTAssertTrue(content.bounds.contains(content.band.frame))
        XCTAssertFalse(content.band.frame.intersects(content.phoneSlot.frame))
        XCTAssertGreaterThan(content.workbenchArea.frame.minY, content.band.frame.maxY)
        let buttons = descendants(of: content.band).compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), ["결제 승인", "취소"])
        for button in buttons {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)), button.title)
        }
        XCTAssertFalse(panel.isVisible)
    }

    /// Moving Mirroring to the left in expanded mode puts the workbench and approvals in the clear space on its right.
    @MainActor func testPhoneOnLeftMovesExpandedSidebarToRight() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        content.phoneSize = CGSize(width: 348, height: 620)
        KioskController.fitExpanded(panel, content: content, in: CGRect(x: 0, y: 0, width: 1280, height: 760))
        let movedPhone = CGRect(x: 24, y: 64, width: 348, height: 620)
        content.followedPhone = movedPhone
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.phoneSlot.frame, movedPhone)
        XCTAssertGreaterThanOrEqual(content.workbenchArea.frame.minX, movedPhone.maxX)
        XCTAssertGreaterThanOrEqual(content.band.frame.minX, movedPhone.maxX)
        XCTAssertTrue(content.bounds.contains(content.workbenchArea.frame))
        XCTAssertTrue(content.bounds.contains(content.band.frame))
        XCTAssertGreaterThan(content.workbenchArea.frame.width, 800)
        XCTAssertFalse(panel.isVisible)
    }

    /// Tab/focus updates are stable; phone drags are followed and deliberate workbench moves align once.
    func testDockSnapshotsDistinguishPhoneAndWorkbenchMovementWithoutRepeatingAlignment() {
        let start = DockSnapshot(phoneID: 31,
                                 panel: CGRect(x: 100, y: 60, width: 940, height: 894),
                                 phone: CGRect(x: 660, y: 92, width: 348, height: 766))
        XCTAssertEqual(DockChange.between(nil, and: start, explicitLayout: false), .followPhone)
        XCTAssertEqual(DockChange.between(start, and: start, explicitLayout: false), .none)
        XCTAssertEqual(DockChange.between(start, and: start, explicitLayout: false), .none)
        let phoneMoved = DockSnapshot(phoneID: start.phoneID, panel: start.panel,
                                      phone: start.phone.offsetBy(dx: -80, dy: 40))
        XCTAssertEqual(DockChange.between(start, and: phoneMoved, explicitLayout: false), .followPhone)
        let panelMoved = DockSnapshot(phoneID: start.phoneID,
                                      panel: start.panel.offsetBy(dx: 60, dy: 25), phone: start.phone)
        XCTAssertEqual(DockChange.between(start, and: panelMoved, explicitLayout: false), .alignPhone)
        let aligned = DockSnapshot(phoneID: start.phoneID, panel: panelMoved.panel,
                                   phone: start.phone.offsetBy(dx: 60, dy: 25))
        XCTAssertEqual(DockChange.between(aligned, and: aligned, explicitLayout: false), .none)
        let reopenedPhone = DockSnapshot(phoneID: 99, panel: aligned.panel, phone: aligned.phone)
        XCTAssertEqual(DockChange.between(aligned, and: reopenedPhone, explicitLayout: false), .followPhone)
        XCTAssertEqual(DockChange.between(aligned, and: aligned, explicitLayout: true), .alignPhone)
    }

    @MainActor private func makePanel(_ content: WorkbenchContent) -> NSPanel {
        let panel = NSPanel(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        return panel
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
