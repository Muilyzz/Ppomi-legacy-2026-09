import Combine
import Foundation
import XCTest
@testable import Ppomi

final class RecordsFocusStateTests: XCTestCase {
    @MainActor func testSelectingTabsKeepsContextWithoutRequestingParking() {
        let state = AppState()
        let day = Date(timeIntervalSince1970: 12345)
        state.selectedDay = day
        state.showEvidence(day: day, uid: "saved-voucher")
        let evidence = state.evidenceFocus
        XCTAssertEqual(evidence, EvidenceFocus(day: day, uid: "saved-voucher"))
        XCTAssertEqual(state.tab, .evidence)
        state.show(.timeline)
        state.show(.spatial)
        XCTAssertFalse(state.recordsFocused)
        XCTAssertEqual(state.recordsFocusRequest, 0)
        XCTAssertEqual(state.tab, .spatial)
        XCTAssertEqual(state.selectedDay, day)
        XCTAssertEqual(state.evidenceFocus, evidence)

        state.show(.evidence)
        XCTAssertEqual(state.tab, .evidence)
        XCTAssertEqual(state.evidenceFocus, EvidenceFocus(day: day, uid: nil))
        XCTAssertEqual(state.recordsFocusRequest, 0)
    }

    @MainActor func testExplicitParkingRequestsAreSeparateFromTabSelection() {
        let state = AppState()
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        let evidence = state.evidenceFocus
        state.toggleRecordsFocus()
        XCTAssertEqual(state.recordsFocusRequest, 1)
        XCTAssertFalse(state.recordsFocused, "Only the controller confirms that windows are parked")
        state.show(.timeline)
        XCTAssertEqual(state.recordsFocusRequest, 1)
        state.beginRecordsFocus()
        XCTAssertTrue(state.recordsFocused)
        state.recordsFocusMessage = "창 복원을 다시 시도해 주세요."
        state.show(.spatial)
        XCTAssertEqual(state.recordsFocusRequest, 1)
        XCTAssertEqual(state.recordsFocusMessage, "창 복원을 다시 시도해 주세요.")
        state.toggleRecordsFocus()
        XCTAssertEqual(state.recordsFocusRequest, 2)
        XCTAssertTrue(state.recordsFocused, "A restoration request must keep protection until the controller succeeds")
        state.endRecordsFocus()
        XCTAssertFalse(state.recordsFocused)
        XCTAssertEqual(state.tab, .spatial)
        XCTAssertEqual(state.evidenceFocus, evidence)
    }

    @MainActor func testOrdinaryRecordNavigationLeavesScreenControlAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiRecordNavigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerPath = directory.appendingPathComponent("ledger.db").path
        let state = AppState()

        // Model only the controller's request-to-lease boundary, without touching any device windows.
        var focusLease: ScreenControlLease?
        let requests = state.$recordsFocusRequest.dropFirst().sink { _ in
            focusLease = try? ScreenControlLease.beginFocus(ledgerPath: ledgerPath)
        }
        defer { requests.cancel(); focusLease?.release() }

        state.show(.accounting)
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        state.show(.timeline)
        XCTAssertEqual(state.recordsFocusRequest, 0)
        XCTAssertNil(focusLease)
        let control = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        control.release()

        state.toggleRecordsFocus()
        XCTAssertNotNil(focusLease, "An explicit parking request still owns the exclusive lease")
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: ledgerPath))
    }

    @MainActor func testFocusedSettingsChangeCannotSwitchScreenLockPath() async {
        let state = AppState()
        let original = AppSettings.dbPath
        state.beginRecordsFocus()
        state.toggleRecordsFocus()
        do {
            try await state.applyLedgerSettings(dbPath: "/tmp/unopened-focus-test.db", me: "test")
            XCTFail("Changing the ledger must wait for window restoration")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("제어로 돌아가기"))
        }
        XCTAssertEqual(AppSettings.dbPath, original)
        XCTAssertTrue(state.recordsFocused)
    }

    @MainActor func testNavigationAndFocusDoNotAnswerOrDiscardApproval() {
        let state = AppState()
        state.ask = (id: "request", text: "승인 대기", options: ["확인", "취소"])
        state.phase = .humanTurn(reason: "승인 대기")
        state.show(.health)
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        XCTAssertEqual(state.recordsFocusRequest, 0)
        XCTAssertFalse(state.recordsFocused)
        state.beginRecordsFocus()
        state.endRecordsFocus()
        XCTAssertEqual(state.ask?.id, "request")
        XCTAssertEqual(state.ask?.options, ["확인", "취소"])
        XCTAssertEqual(state.phase, .humanTurn(reason: "승인 대기"))
    }
}
