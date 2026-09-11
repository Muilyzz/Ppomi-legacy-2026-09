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
    @MainActor func testFirstFitUsesTheDisplayAndLaterFitsKeepThePersonsFrame() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let panel = makePanel(content)
        defer { panel.close() }
        let workbench = NSView(frame: .zero)
        content.workbenchArea.mount(workbench)

        let display = CGRect(x: 40, y: 30, width: 1440, height: 980)
        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 348, height: 540), in: display, initial: true)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, display)
        XCTAssertEqual(panel.contentMinSize, WorkbenchLayout.minimumContentSize)
        XCTAssertGreaterThan(panel.contentMaxSize.width, display.width)
        XCTAssertEqual(content.phoneSlot.bounds.size, CGSize(width: 348, height: 540))
        XCTAssertEqual(workbench.frame.width, WorkbenchLayout.conversationWidth - 24, "대화 열은 폰 폭으로 고정")
        XCTAssertGreaterThan(workbench.frame.height, 400)
        XCTAssertTrue(content.band.isHidden, "No footer without a question")
        XCTAssertFalse(content.phoneSlot.frame.intersects(content.workbenchArea.frame))

        // The person shrank and moved the workbench: a later fit keeps that frame and the layout follows it.
        let chosen = CGRect(x: 200, y: 60, width: 1100, height: 920)
        panel.setFrame(chosen, display: false)
        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 300, height: 520), in: display)
        XCTAssertEqual(panel.frame, chosen)
        XCTAssertEqual(content.phoneSlot.bounds.size, CGSize(width: 300, height: 520))
        XCTAssertGreaterThan(workbench.frame.height, 300)
        XCTAssertEqual(workbench.frame.width, WorkbenchLayout.conversationWidth - 24)
        XCTAssertTrue(content.bounds.contains(content.phoneSlot.frame))
    }

    /// A wide target pushes the window minimum out so the shell keeps `conversationWidth` beside it.
    @MainActor func testMinimumWidthFollowsAWideControlColumn() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 900, height: 620), in: display, initial: true)
        XCTAssertEqual(panel.contentMinSize.width, 900 + 24 + WorkbenchLayout.conversationWidth)
        XCTAssertEqual(panel.contentMinSize.height, WorkbenchLayout.minimumContentSize.height)
        KioskController.fitMain(panel, content: content, phoneSize: CGSize(width: 348, height: 540), in: display)
        XCTAssertEqual(panel.contentMinSize, WorkbenchLayout.minimumContentSize)
    }

    func testFittedFrameStaysOnTheDisplayAndAtLeastTheMinimum() {
        let display = CGRect(x: 0, y: 30, width: 1440, height: 1000)
        let minimum = CGSize(width: 1040, height: 640)
        XCTAssertEqual(KioskController.fitted(CGRect(x: 100, y: 60, width: 1200, height: 900), in: display, minimum: minimum),
                       CGRect(x: 100, y: 60, width: 1200, height: 900))
        // Too small grows to the minimum; too large shrinks to the display; off-display moves back on.
        XCTAssertEqual(KioskController.fitted(CGRect(x: 100, y: 60, width: 600, height: 500), in: display, minimum: minimum).size, minimum)
        XCTAssertEqual(KioskController.fitted(CGRect(x: -50, y: 0, width: 2000, height: 1500), in: display, minimum: minimum), display)
        XCTAssertEqual(KioskController.fitted(CGRect(x: 900, y: 700, width: 1100, height: 900), in: display, minimum: minimum),
                       CGRect(x: 340, y: 130, width: 1100, height: 900))
        // A display smaller than the minimum wins; nothing is placed off-screen.
        let small = CGRect(x: 140, y: 60, width: 960, height: 720)
        XCTAssertEqual(KioskController.fitted(CGRect(x: 0, y: 0, width: 1440, height: 1000), in: small, minimum: minimum), small)
    }

    /// A new display may be shorter than a large iPhone. Previous constraints must not prevent fitting it.
    @MainActor func testDisplayResizePreservesTheSamePanelAndContent() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        let workbench = NSView(frame: .zero)
        content.workbenchArea.mount(workbench)
        let phone = CGSize(width: 446, height: 978)
        let large = CGRect(x: 0, y: 30, width: 1440, height: 1000)
        KioskController.fitMain(panel, content: content, phoneSize: phone, in: large, initial: true)
        XCTAssertEqual(panel.frame, large)
        let panelIdentity = ObjectIdentifier(panel)
        let smallerDisplay = CGRect(x: 140, y: 60, width: 960, height: 600)
        XCTAssertGreaterThan(panel.contentMinSize.width, smallerDisplay.width)
        XCTAssertGreaterThan(panel.contentMinSize.height, smallerDisplay.height)

        KioskController.fitMain(panel, content: content, phoneSize: phone, in: smallerDisplay)
        XCTAssertEqual(panel.frame, smallerDisplay)
        XCTAssertEqual(panel.contentMinSize, smallerDisplay.size)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertEqual(ObjectIdentifier(panel), panelIdentity)
        XCTAssertTrue(panel.contentView === content)
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertFalse(panel.isVisible)

        // Back on the large display the frame grows only to the minimum; the display is not forced again.
        KioskController.fitMain(panel, content: content, phoneSize: phone, in: large)
        XCTAssertEqual(panel.frame.size, WorkbenchLayout.minimumContentSize)
        XCTAssertTrue(large.contains(panel.frame))
        XCTAssertEqual(panel.contentMinSize, WorkbenchLayout.minimumContentSize)
        XCTAssertEqual(ObjectIdentifier(panel), panelIdentity)
        XCTAssertTrue(panel.contentView === content)
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertFalse(panel.isVisible)
    }

    /// A native window that cannot fit must leave the 차례 띠 legible.
    @MainActor func testTallPhoneKeepsApprovalButtonsInVisibleControlFooter() throws {
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
        KioskController.fitMain(panel, content: content, phoneSize: content.phoneSize, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertFalse(content.nativeControlFits)
        XCTAssertFalse(content.band.isHidden)
        XCTAssertTrue(content.bounds.contains(content.band.frame))
        XCTAssertFalse(content.band.frame.intersects(content.phoneSlot.frame))
        XCTAssertFalse(content.band.frame.intersects(content.workbenchArea.frame))
        let buttons = descendants(of: content.band).compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), ["결제 승인", "취소"])
        for button in buttons {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)), button.title)
        }
        XCTAssertFalse(panel.isVisible)
    }

    /// An out-of-area native move leaves the placeholder and conversation inside their own columns.
    @MainActor func testPhoneMovementPreservesTheFixedColumns() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: .zero)
        let panel = makePanel(content)
        defer { panel.close() }
        content.phoneSize = CGSize(width: 348, height: 620)
        KioskController.fitMain(panel, content: content, phoneSize: content.phoneSize, in: CGRect(x: 0, y: 0, width: 1280, height: 760), initial: true)
        let originalSidebar = content.workbenchArea.frame
        let originalToolbar = content.controlToolbarArea.frame
        let movedPhone = CGRect(x: 24, y: 64, width: 348, height: 620)
        content.followedPhone = movedPhone
        content.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(content.phoneSlot.frame, movedPhone)
        XCTAssertTrue(content.controlAvailableArea.contains(content.phoneSlot.frame))
        XCTAssertEqual(content.workbenchArea.frame, originalSidebar)
        XCTAssertEqual(content.controlToolbarArea.frame, originalToolbar)
        XCTAssertTrue(content.bounds.contains(content.workbenchArea.frame))
        XCTAssertEqual(content.workbenchArea.frame.width, WorkbenchLayout.conversationWidth - 24)
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
