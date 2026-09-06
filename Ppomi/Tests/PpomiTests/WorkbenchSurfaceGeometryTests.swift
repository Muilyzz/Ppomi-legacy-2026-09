import AppKit
import XCTest
@testable import Ppomi

final class WorkbenchSurfaceGeometryTests: XCTestCase {
    func testDefaultIPhoneSizeRetainsExistingMargins() {
        let phone = CGSize(width: 348, height: 766)
        XCTAssertEqual(WorkbenchContent.minimumBandWidth(for: .iphone), 560)
        XCTAssertEqual(WorkbenchContent.size(bandWidth: 560, phone: phone), CGSize(width: 940, height: 894))
        XCTAssertEqual(WorkbenchContent.size(bandWidth: 560, phone: phone, surface: .iphone),
                       WorkbenchContent.size(bandWidth: 560, phone: phone))
    }

    @MainActor func testLargeDesktopFitsDisplayWithWorkbenchChromeAndScreenMargins() {
        let desktop = CGSize(width: 1510, height: 1010)
        let available = CGSize(width: 1728, height: 1084)
        let chrome = CGSize(width: 0, height: 22)
        let fitted = KioskController.fittedDesktopSize(desktop, available: available, frameOverhead: chrome)
        let workbench = WorkbenchContent.size(bandWidth: WorkbenchContent.minimumBandWidth(for: .windows),
                                              phone: fitted, surface: .windows)

        XCTAssertEqual(fitted.width, 1276, accuracy: 1)
        XCTAssertEqual(fitted.height, desktop.height * fitted.width / desktop.width, accuracy: 1)
        XCTAssertLessThan(fitted.width, desktop.width)
        XCTAssertLessThan(fitted.height, desktop.height)
        XCTAssertLessThanOrEqual(workbench.width + chrome.width + 48, available.width)
        XCTAssertLessThanOrEqual(workbench.height + chrome.height + 48, available.height)
    }

    @MainActor func testDesktopFitDoesNotEnlargeAnAlreadyFittingWindow() {
        let desktop = CGSize(width: 900, height: 620)
        XCTAssertEqual(KioskController.fittedDesktopSize(desktop, available: CGSize(width: 1728, height: 1084),
                                                        frameOverhead: CGSize(width: 0, height: 22)), desktop)
    }

    @MainActor func testFittedDesktopCentersAndRestoresWithinOffsetDisplayMargins() {
        let visible = CGRect(x: -1728, y: 90, width: 1728, height: 1084)
        let chrome = CGSize(width: 0, height: 22)
        let fitted = KioskController.fittedDesktopSize(CGSize(width: 1510, height: 1010),
                                                       available: visible.size, frameOverhead: chrome)
        let workbench = WorkbenchContent.size(bandWidth: WorkbenchContent.minimumBandWidth(for: .windows),
                                              phone: fitted, surface: .windows)
        let frameSize = CGSize(width: workbench.width + chrome.width, height: workbench.height + chrome.height)
        let safeFrame = visible.insetBy(dx: 24, dy: 24)
        let centered = KioskController.centeredOrigin(for: frameSize, in: safeFrame)
        let restored = KioskController.clampedOrigin(CGPoint(x: 300, y: -200), size: frameSize, in: safeFrame)

        XCTAssertTrue(safeFrame.contains(CGRect(origin: centered, size: frameSize)))
        XCTAssertTrue(safeFrame.contains(CGRect(origin: restored, size: frameSize)))
        XCTAssertEqual(restored.x, safeFrame.maxX - frameSize.width, accuracy: 0.001)
        XCTAssertEqual(restored.y, safeFrame.minY)
    }

    /// The rectangular slot is the native window's actual size; approvals occupy the independent sidebar.
    @MainActor func testWindowsNativeSizeKeepsApprovalButtonsVisibleBesideWindow() {
        _ = NSApplication.shared
        let desktop = CGSize(width: 1024, height: 600)
        let size = WorkbenchContent.size(bandWidth: WorkbenchContent.minimumBandWidth(for: .windows),
                                         phone: desktop, surface: .windows)
        XCTAssertEqual(size, CGSize(width: 1428, height: 680))
        let content = WorkbenchContent(frame: CGRect(origin: .zero, size: size))
        content.surface = .windows
        content.phoneSize = desktop
        let state = AppState()
        state.ask = (id: "windows-layout", text: "이 작업을 진행할까요?", options: ["승인", "취소"])
        content.band.state = state
        content.band.sync()
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(content.phoneSlot.frame, CGRect(x: 380, y: 32, width: 1024, height: 600))
        XCTAssertEqual(content.phoneSlot.surface, .windows)
        XCTAssertTrue(content.bounds.contains(content.band.frame))
        XCTAssertFalse(content.band.frame.intersects(content.phoneSlot.frame))
        XCTAssertGreaterThan(content.workbenchArea.frame.minY, content.band.frame.maxY)
        let buttons = descendants(of: content.band).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
            XCTAssertFalse(button.convert(button.bounds, to: content).intersects(content.phoneSlot.frame))
        }
        XCTAssertEqual(state.ask?.id, "windows-layout")
    }

    /// A desktop moved left uses the clear right column; switching targets replaces stale instructions.
    @MainActor func testFollowedWindowsFrameMovesSidebarAndSwitchUpdatesNativePlaceholder() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: CGRect(x: 0, y: 0, width: 1440, height: 800))
        content.surface = .windows
        content.expanded = true
        let desktop = CGRect(x: 24, y: 80, width: 1000, height: 650)
        content.followedPhone = desktop
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.phoneSlot.frame, desktop)
        XCTAssertGreaterThanOrEqual(content.band.frame.minX, desktop.maxX)
        XCTAssertTrue(content.bounds.contains(content.band.frame))
        XCTAssertFalse(content.band.frame.intersects(desktop))
        XCTAssertTrue(descendants(of: content.phoneSlot).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Parallels") })

        content.phoneSlot.hint = "Windows 연결 확인 중"
        content.surface = .iphone
        XCTAssertEqual(content.phoneSlot.surface, .iphone)
        XCTAssertEqual(content.phoneSlot.hint, "")
        XCTAssertTrue(descendants(of: content.phoneSlot).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("iPhone 미러링") })
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
