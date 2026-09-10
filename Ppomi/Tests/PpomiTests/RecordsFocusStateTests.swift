import XCTest
@testable import Ppomi

final class RecordsFocusStateTests: XCTestCase {
    /// Showing a tab asks the controller for the page; only the controller flips the page on and off.
    @MainActor func testShowingATabRequestsThePageOnceAndKeepsContext() {
        let state = AppState()
        state.showEvidence(day: Date(timeIntervalSince1970: 12345), uid: "saved-voucher")
        let evidence = state.evidenceFocus
        XCTAssertFalse(state.recordsFocused)
        XCTAssertEqual(state.recordsFocusRequest, 1)
        state.show(.timeline)
        XCTAssertEqual(state.recordsFocusRequest, 2, "Every request before the controller answers is one more request")
        state.beginRecordsFocus()
        XCTAssertTrue(state.recordsFocused)
        state.show(.spatial)
        XCTAssertEqual(state.recordsFocusRequest, 2, "Switching tabs on the page is not a request")
        state.toggleRecordsFocus()
        XCTAssertEqual(state.recordsFocusRequest, 3)
        state.endRecordsFocus()
        XCTAssertFalse(state.recordsFocused)
        XCTAssertEqual(state.tab, .spatial)
        XCTAssertEqual(state.evidenceFocus, evidence)
    }

    @MainActor func testFocusedSettingsChangeCannotSwitchScreenLockPath() async {
        let state = AppState()
        let original = AppSettings.dbPath
        state.beginRecordsFocus()
        do {
            try await state.applyLedgerSettings(dbPath: "/tmp/unopened-focus-test.db", me: "test")
            XCTFail("Changing the ledger must wait for window restoration")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("← 대화"))
        }
        XCTAssertEqual(AppSettings.dbPath, original)
        XCTAssertTrue(state.recordsFocused)
    }

    @MainActor func testFocusDoesNotAnswerOrDiscardApproval() {
        let state = AppState()
        state.beginRecordsFocus()
        state.ask = (id: "request", text: "승인 대기", options: ["확인", "취소"])
        state.phase = .humanTurn(reason: "승인 대기")
        state.endRecordsFocus()
        XCTAssertEqual(state.ask?.id, "request")
        XCTAssertEqual(state.ask?.options, ["확인", "취소"])
        XCTAssertEqual(state.phase, .humanTurn(reason: "승인 대기"))
    }
}
