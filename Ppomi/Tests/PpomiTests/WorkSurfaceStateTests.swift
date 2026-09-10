import AppKit
import XCTest
@testable import Ppomi

final class WorkSurfaceStateTests: XCTestCase {
    @MainActor func testSurfaceSizesRemainIndependentAfterAndroidResizeAndSelection() {
        let state = AppState()
        let phone = state.phoneSize, windows = state.windowsSize
        let android = CGSize(width: 220, height: 464)
        state.setSize(android, for: .android)
        state.selectSurface(.android)
        XCTAssertEqual(state.surfaceSize, android)
        XCTAssertEqual(state.phoneSize, phone)
        XCTAssertEqual(state.windowsSize, windows)
        state.selectSurface(.windows)
        XCTAssertEqual(state.surfaceSize, windows)
        state.setSize(CGSize(width: 700, height: 500), for: .windows)
        state.selectSurface(.android)
        XCTAssertEqual(state.surfaceSize, android)
        state.setSize(CGSize(width: CGFloat.nan, height: 500), for: .android)
        XCTAssertEqual(state.surfaceSize, android)
    }

    @MainActor func testAndroidStatusReportsLaunchAndWindowStateWithoutPhoneConnectionClaims() {
        let state = AppState()
        state.selectSurface(.android)
        state.androidLaunching = true
        XCTAssertEqual(state.connectionHint(for: .android), "Android · 시작 중")
        state.androidLaunching = false
        state.androidLaunchError = "scrcpy 설치 필요"
        XCTAssertEqual(state.connectionHint(for: .android), "Android · 시작 실패")
        XCTAssertEqual(state.connectionHint(for: .iphone), "iPhone · 연결 끊김")
        state.androidLaunchError = nil
        state.androidWindowVisible = true
        XCTAssertEqual(state.size(for: .android), AndroidWindow.defaultSize)
        XCTAssertFalse(state.windowsWindowVisible)
    }

    @MainActor func testAndroidPreparationStatusRemainsVisibleWhileMirrorAlreadyRuns() {
        let state = AppState()
        state.selectSurface(.android)
        state.phase = .humanUse(onScreen: true)
        state.androidWindowVisible = true
        state.androidLaunching = true
        XCTAssertEqual(state.statusLine, "Android 에뮬레이터와 미러링을 시작하는 중…")
        state.androidLaunching = false
        state.androidLaunchError = "접근성 서비스 연결 실패"
        XCTAssertEqual(state.statusLine, "Android 시작 실패 · 접근성 서비스 연결 실패")
        state.androidLaunchError = nil
        XCTAssertEqual(state.statusLine, "Android 화면 표시 중 · 에뮬레이터 앱 제어")
    }

    @MainActor func testPendingIPhoneApprovalAlsoRejectsAndroidSelection() {
        let state = AppState()
        state.ask = (id: "approval", text: "계속할까요?", options: ["계속", "취소"])
        state.selectSurface(.android)
        XCTAssertEqual(state.workSurface, .iphone)
        XCTAssertEqual(state.ask?.id, "approval")
    }

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
}
