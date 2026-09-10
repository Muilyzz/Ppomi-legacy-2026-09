import AppKit
import XCTest
@testable import Ppomi

final class WorkSurfaceTests: XCTestCase {
    private let rect = CGRect(x: 130, y: 70, width: 900, height: 620)

    @MainActor func testSurfaceIdentityAndFallbackSizesDoNotRequireLaunchingApplications() {
        XCTAssertEqual(WorkSurface.allCases.map(\.id), ["iphone", "android", "windows"])
        XCTAssertEqual(WorkSurface.iphone.defaultSize, Mirroring.defaultSize)
        XCTAssertEqual(WorkSurface.android.defaultSize, AndroidWindow.defaultSize)
        XCTAssertEqual(WorkSurface.android.displayName, "Android")
        XCTAssertEqual(WorkSurface.windows.defaultSize, CGSize(width: 900, height: 620))
        XCTAssertEqual(WorkSurface.windows.displayName, "Windows")
    }

    func testCompactDesktopSizeKeepsAspectRatioInsideTheReservedArea() throws {
        let current = CGSize(width: 1276, height: 853)
        for available in [CGSize(width: 696, height: 484), CGSize(width: 540, height: 620)] {
            let target = try XCTUnwrap(WorkSurfaceCompactLayout.size(current: current, available: available))
            XCTAssertLessThanOrEqual(target.width, available.width - 16)
            XCTAssertLessThanOrEqual(target.height, available.height - 16)
            XCTAssertEqual(target.width / target.height, current.width / current.height, accuracy: 0.001)
            XCTAssertLessThanOrEqual(target.width, current.width)
            XCTAssertLessThanOrEqual(target.height, current.height)
        }
    }

    func testCompactDesktopSizeDoesNotEnlargeAnAlreadySmallWindow() {
        let small = CGSize(width: 320, height: 220)
        XCTAssertEqual(WorkSurfaceCompactLayout.size(current: small, available: CGSize(width: 700, height: 620)), small)
    }

    func testCompactDesktopSizeRejectsImpossibleOrInvalidAreas() {
        let current = CGSize(width: 900, height: 620)
        for available in [CGSize.zero, CGSize(width: 255, height: 200), CGSize(width: -1, height: 700),
                          CGSize(width: CGFloat.infinity, height: 700)] {
            XCTAssertNil(WorkSurfaceCompactLayout.size(current: current, available: available))
        }
        XCTAssertNil(WorkSurfaceCompactLayout.size(current: CGSize(width: CGFloat.nan, height: 620), available: current))
        XCTAssertNil(WorkSurfaceCompactLayout.size(current: current, available: current, margin: -1))
    }

    func testExactInstalledExecutableIdentityRejectsNamesakesAndMacGuests() {
        let host = "/Applications/Parallels Desktop.app/Contents/MacOS/prl_client_app"
        let vm = "/Applications/Parallels Desktop.app/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app"
        let hosts: Set<String> = [host], vms: Set<String> = [vm]
        XCTAssertEqual(ParallelsWindowPolicy.kind(executablePath: host, hostPaths: hosts, vmPaths: vms), .host)
        XCTAssertEqual(ParallelsWindowPolicy.kind(executablePath: vm, hostPaths: hosts, vmPaths: vms), .virtualMachine)
        for unrelated in [nil, "/tmp/prl_vm_app", "/Applications/Parallels Desktop.app/Contents/MacOS/Parallels Mac VM.app/Contents/MacOS/prl_macvm_app"] {
            XCTAssertNil(ParallelsWindowPolicy.kind(executablePath: unrelated, hostPaths: hosts, vmPaths: vms))
        }
    }

    func testRealVMSupersedesRememberedHostLoginWindow() {
        let host = candidate(10, kind: .host, main: true)
        let vm = candidate(20)
        XCTAssertEqual(ParallelsWindowPolicy.select([host, vm], preferredID: host.id)?.id, vm.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([vm, host], preferredID: host.id)?.id, vm.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([host], preferredID: vm.id)?.id, host.id)
    }

    func testLargestStandardWindowWinsAndMemoryOnlyBreaksTies() {
        let chosen = candidate(20)
        let larger = candidate(21, main: true, frame: rect.insetBy(dx: -50, dy: -30))
        let twin = candidate(22, main: true)
        XCTAssertEqual(ParallelsWindowPolicy.select([larger, chosen], preferredID: chosen.id)?.id, larger.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([chosen, twin], preferredID: chosen.id)?.id, chosen.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([chosen, twin], preferredID: nil)?.id, twin.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([larger], preferredID: chosen.id)?.id, larger.id)
    }

    func testExplicitCompactDesktopDoesNotBecomeAConfigurationDialogAfterShrinking() {
        let desktop = candidate(681, kind: .host, frame: CGRect(x: 100, y: 200, width: 600, height: 401))
        let config = candidate(677, kind: .host, main: true, frame: CGRect(x: 150, y: 150, width: 628, height: 538))
        XCTAssertEqual(ParallelsWindowPolicy.select([config, desktop], preferredID: desktop.id, compactID: desktop.id)?.id, desktop.id)
        let realVM = candidate(700)
        XCTAssertEqual(ParallelsWindowPolicy.select([config, desktop, realVM], preferredID: desktop.id,
                                                    vmWindowPresent: true, compactID: desktop.id)?.id, realVM.id)
    }

    /// Measured on the App Store edition (2026-09-07): the host process owns the 1276x853 display, the 628x538 구성 dialog
    /// and 제어 센터, all AXStandardWindow; prl_vm_app owns nothing. The dialog was the last clicked (main) window.
    func testAppStoreEditionHostPeersSelectTheDisplayNotTheClickedConfigDialog() {
        let display = candidate(681, kind: .host, main: false, frame: CGRect(x: 428, y: 149, width: 1276, height: 853))
        let config = candidate(677, kind: .host, main: true, frame: CGRect(x: 554, y: 302, width: 628, height: 538))
        let control = candidate(673, kind: .host, main: false, frame: CGRect(x: 218, y: 33, width: 540, height: 164))
        XCTAssertEqual(ParallelsWindowPolicy.select([config, control, display], preferredID: nil)?.id, display.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([config, display], preferredID: config.id)?.id, display.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([config, control], preferredID: nil)?.id, config.id)
    }

    func testVMDialogAndSmallPopupCannotReplaceDesktopButHostLoginCanBeShown() {
        let desktop = candidate(20)
        let dialog = candidate(21, standard: false, main: true)
        let popup = candidate(22, main: true, frame: CGRect(x: 100, y: 50, width: 100, height: 80))
        let hostLogin = candidate(10, kind: .host, standard: false, main: true)
        XCTAssertEqual(ParallelsWindowPolicy.select([dialog, popup, desktop], preferredID: dialog.id)?.id, desktop.id)
        XCTAssertEqual(ParallelsWindowPolicy.select([dialog, popup, hostLogin], preferredID: nil)?.id, hostLogin.id)
        XCTAssertNil(ParallelsWindowPolicy.select([dialog, popup], preferredID: nil))
    }

    func testUnsettledAXCGGeometryAndNonNormalLayersAreNotDocked() {
        let movedAX = candidate(20, axFrame: rect.offsetBy(dx: 10, dy: 0))
        let resizedAX = candidate(21, axFrame: rect.insetBy(dx: 0, dy: 10))
        let overlay = candidate(22, layer: 3)
        XCTAssertNil(ParallelsWindowPolicy.select([movedAX, resizedAX, overlay], preferredID: 20))
        XCTAssertTrue(ParallelsWindowPolicy.framesMatch(rect, rect.offsetBy(dx: 1, dy: -1)))
        XCTAssertFalse(ParallelsWindowPolicy.framesMatch(rect, CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 620)))
        XCTAssertFalse(ParallelsWindowPolicy.framesMatch(rect, CGRect(x: 130, y: 70, width: -900, height: 620)))
    }

    func testAmbiguousAXElementsSharingOneCGFrameCannotBeMoved() {
        let sameID = candidate(20)
        let fallback = candidate(10, kind: .host)
        XCTAssertNil(ParallelsWindowPolicy.select([sameID, sameID], preferredID: sameID.id))
        XCTAssertEqual(ParallelsWindowPolicy.select([sameID, sameID, fallback], preferredID: sameID.id)?.id, fallback.id)
    }

    func testUnsettledVMDoesNotRedirectPlacementToTheHost() {
        let host = candidate(10, kind: .host)
        let resizingVM = candidate(20, axFrame: rect.insetBy(dx: 80, dy: 40))
        XCTAssertNil(ParallelsWindowPolicy.select([host, resizingVM], preferredID: 20, vmWindowPresent: true))
        XCTAssertNil(ParallelsWindowPolicy.select([host], preferredID: 20, vmWindowPresent: true))
        XCTAssertEqual(ParallelsWindowPolicy.select([host], preferredID: 20, vmWindowPresent: false)?.id, host.id)
    }

    func testParkedVMRemainsExplicitRevealTargetInsteadOfSwitchingToVisibleHost() {
        let vm = candidate(20, onScreen: false)
        let host = candidate(10, kind: .host, onScreen: true)
        let target = ParallelsWindowPolicy.select([host, vm], preferredID: vm.id)
        XCTAssertEqual(target?.id, vm.id)
        XCTAssertEqual(target?.isOnScreen, false)
    }

    private func candidate(_ id: CGWindowID, kind: ParallelsWindowPolicy.Kind = .virtualMachine,
                           standard: Bool = true, main: Bool = false, onScreen: Bool = true,
                           layer: Int = 0, frame: CGRect? = nil, axFrame: CGRect? = nil) -> ParallelsWindowPolicy.Candidate {
        .init(id: id, pid: kind == .host ? 100 : 200, kind: kind, rect: frame ?? rect,
              axRect: axFrame ?? frame ?? rect, isStandard: standard, isMain: main, isOnScreen: onScreen, layer: layer)
    }
}
