import AppKit
import XCTest
@testable import Ppomi

final class WorkSurfaceStateTests: XCTestCase {
    @MainActor func testPhoneJobResumesAfterReconnectWhileWindowsIsSelected() {
        let state = AppState()
        state.phase = .agent(job: "테스트 작업")
        state.mirroring(.inUse)
        XCTAssertEqual(state.phase, .humanUse(onScreen: false))
        XCTAssertEqual(state.pendingJob, "테스트 작업")

        state.selectSurface(.windows)
        state.mirroring(.connected)

        XCTAssertEqual(state.workSurface, .windows)
        XCTAssertEqual(state.mirror, .connected)
        XCTAssertEqual(state.phase, .agent(job: "테스트 작업"))
        XCTAssertNil(state.pendingJob)

        state.selectSurface(.iphone)
        XCTAssertEqual(state.phase, .agent(job: "테스트 작업"))
        XCTAssertNil(state.pendingJob)
    }

    @MainActor func testPendingApprovalRejectsWindowsSelectionAndSurvivesReconnect() {
        let state = AppState()
        let waiting = Phase.humanTurn(reason: "테스트 승인 대기")
        state.ask = (id: "surface-approval", text: "테스트 작업을 승인할까요?", options: ["승인", "취소"])
        state.phase = waiting
        state.pendingJob = "승인 이후 작업"
        let shown = state.shown

        state.selectSurface(.windows)
        XCTAssertEqual(state.workSurface, .iphone)
        XCTAssertEqual(state.shown, shown)
        XCTAssertEqual(state.phase, waiting)

        state.mirroring(.connected)
        XCTAssertEqual(state.mirror, .connected)
        XCTAssertEqual(state.phase, waiting)
        XCTAssertEqual(state.pendingJob, "승인 이후 작업")
        XCTAssertEqual(state.ask?.id, "surface-approval")
        XCTAssertEqual(state.ask?.options, ["승인", "취소"])
    }

    @MainActor func testCenteredOversizedNativeWindowKeepsBottomOnScreen() {
        let visible = CGRect(x: 0, y: 24, width: 1728, height: 1065)
        let nativeWorkbench = CGSize(width: 1038, height: 1134)
        let origin = KioskController.centeredOrigin(for: nativeWorkbench, in: visible)

        XCTAssertEqual(origin.x, visible.midX - nativeWorkbench.width / 2)
        XCTAssertEqual(origin.y, visible.minY)
        XCTAssertTrue(visible.contains(CGPoint(x: origin.x, y: origin.y)))
    }

    @MainActor func testCenteredWindowUsesOffsetDisplayCoordinates() {
        let visible = CGRect(x: -1728, y: 100, width: 1728, height: 1000)
        let size = CGSize(width: 1200, height: 800)
        let origin = KioskController.centeredOrigin(for: size, in: visible)

        XCTAssertEqual(origin, CGPoint(x: -1464, y: 200))
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: size)))
    }

    @MainActor func testRestoredOriginIsPreservedOrClampedToItsDisplay() {
        let visible = CGRect(x: -1728, y: 100, width: 1728, height: 1000)
        let size = CGSize(width: 1200, height: 800)
        let saved = CGPoint(x: -1500, y: 200)

        XCTAssertEqual(KioskController.clampedOrigin(saved, size: size, in: visible), saved)
        XCTAssertEqual(KioskController.clampedOrigin(CGPoint(x: -2000, y: 0), size: size, in: visible),
                       CGPoint(x: visible.minX, y: visible.minY))
        XCTAssertEqual(KioskController.clampedOrigin(CGPoint(x: 100, y: 1400), size: size, in: visible),
                       CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height))

        let oversized = CGSize(width: 1900, height: 1134)
        XCTAssertEqual(KioskController.clampedOrigin(saved, size: oversized, in: visible), visible.origin)
    }
}
