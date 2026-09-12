import XCTest
@testable import Ppomi

final class PermissionUXTests: XCTestCase {
    func testNeedPromptsUntilEachMissingGrantHasBeenAsked() {
        XCTAssertEqual(Permissions.need(accessibility: true, screen: true, askedAX: false, askedScreen: false), .ready)
        XCTAssertEqual(Permissions.need(accessibility: false, screen: true, askedAX: false, askedScreen: false), .prompt)
        XCTAssertEqual(Permissions.need(accessibility: true, screen: false, askedAX: true, askedScreen: false), .prompt)
        XCTAssertEqual(Permissions.need(accessibility: false, screen: false, askedAX: true, askedScreen: false), .prompt)
        XCTAssertEqual(Permissions.need(accessibility: false, screen: false, askedAX: true, askedScreen: true), .settings)
        XCTAssertEqual(Permissions.need(accessibility: false, screen: true, askedAX: true, askedScreen: false), .settings)
        XCTAssertEqual(Permissions.need(accessibility: true, screen: false, askedAX: false, askedScreen: true), .settings)
    }

    func testAllowClickOpensBothMissingPrivacyPanesUntilReady() {
        XCTAssertEqual(Permissions.missingPrivacyPanes(accessibility: true, screen: true), [])
        XCTAssertEqual(Permissions.missingPrivacyPanes(accessibility: false, screen: true), ["Privacy_Accessibility"])
        XCTAssertEqual(Permissions.missingPrivacyPanes(accessibility: true, screen: false), ["Privacy_ScreenCapture"])
        XCTAssertEqual(Permissions.missingPrivacyPanes(accessibility: false, screen: false),
                       ["Privacy_Accessibility", "Privacy_ScreenCapture"])
    }

    func testStartupRowsKeepMicOptionalAndNameTheTwoRequiredPanes() {
        let items = Permissions.items()
        XCTAssertEqual(items.map(\.id), ["ax", "screen", "mic", "mirror", "relaunch", "lock"])
        XCTAssertTrue(items.first { $0.id == "ax" }?.note.contains("손쉬운 사용") == true)
        XCTAssertTrue(items.first { $0.id == "screen" }?.note.contains("화면 기록") == true)
        XCTAssertTrue(items.first { $0.id == "screen" }?.note.contains("다시 실행") == true)
        XCTAssertTrue(items.first { $0.id == "mic" }?.note.contains("선택") == true)
    }

    @MainActor func testPollAskPromptDoesNotOpenSettingsSignal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ledger.db").path
        let db = try DB(path: path, writable: true)
        let state = AppState()
        state.watchAsks(dbPath: path)
        try db.setState("setup:prompt", "1")
        state.pollAsk()
        XCTAssertEqual(state.permissionPrompt, 1)
        XCTAssertEqual(state.setupNeeded, 0)
        XCTAssertNil(try db.state("setup:prompt"))
        try db.setState("setup:needed", "1")
        state.pollAsk()
        XCTAssertEqual(state.setupNeeded, 1)
        XCTAssertEqual(state.permissionPrompt, 1)
        XCTAssertNil(try db.state("setup:needed"))
    }
}
