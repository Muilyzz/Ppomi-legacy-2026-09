import Combine
import Foundation
import XCTest
@testable import Ppomi

final class LedgerSettingsTests: XCTestCase {
    @MainActor func testApplySwitchesNameLedgerMonitorAndApprovalConnectionTogether() async throws {
        guard ProcessInfo.processInfo.environment["PPOMI_DB"] == nil else { throw XCTSkip("PPOMI_DB fixes the active database") }
        let saved = SettingsBackup()
        defer { saved.restore() }
        let first = try Fixture(balance: 100)
        let second = try Fixture(balance: 900)
        try second.writer.exec("""
            INSERT INTO transactions(ts,kind,amount,merchant,source,uid)
            VALUES('2026-09-02 12:00','deposit',50,'New Owner','app:KAKAO','own-transfer')
            """, [])
        let state = AppState()
        try await state.applyLedgerSettings(dbPath: first.path, me: "Old Owner")
        try first.question(id: "shared-id")
        state.pollAsk()
        state.answer("보류")
        XCTAssertEqual(try first.writer.state("ask:answer:shared-id"), "보류")
        try await state.applyLedgerSettings(dbPath: first.path, me: "Edited Owner")
        state.pollAsk()
        XCTAssertNil(state.ask, "Changing only the name must not resurrect an already answered question")

        try await state.applyLedgerSettings(dbPath: "  \(second.path)  ", me: " New Owner ")
        XCTAssertEqual(AppSettings.dbPath, second.path)
        XCTAssertEqual(AppSettings.me, "New Owner")
        XCTAssertEqual(state.ledger?.total(at: .distantFuture).sum, 900)
        XCTAssertEqual(state.ledger?.lines.first(where: { $0.uid == "own-transfer" })?.cr, "내 다른 계좌(미확인)")
        XCTAssertNil(state.ledgerError)
        try second.question(id: "shared-id")
        state.pollAsk()
        XCTAssertEqual(state.ask?.id, "shared-id", "The previous database's answered IDs cannot suppress a new approval")
        state.answer("확인")
        XCTAssertEqual(try second.writer.state("ask:answer:shared-id"), "확인")
        XCTAssertEqual(try first.writer.state("ask:answer:shared-id"), "보류")

        let updated = expectation(description: "New database monitor follows committed values")
        let subscription = state.$ledger.compactMap { $0?.total(at: .distantFuture).sum }
            .filter { $0 == 1100 }.prefix(1).sink { _ in updated.fulfill() }
        try second.snapshot(balance: 1100)
        await fulfillment(of: [updated], timeout: 3)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testFailedValidationPreservesSettingsLedgerAndBothReaders() async throws {
        guard ProcessInfo.processInfo.environment["PPOMI_DB"] == nil else { throw XCTSkip("PPOMI_DB fixes the active database") }
        let saved = SettingsBackup()
        defer { saved.restore() }
        let original = try Fixture(balance: 400)
        let state = AppState()
        try await state.applyLedgerSettings(dbPath: original.path, me: "Original Owner")
        let missing = original.directory.appendingPathComponent("typo.db").path
        let corrupt = original.directory.appendingPathComponent("corrupt.db")
        try Data("not a SQLite database".utf8).write(to: corrupt)

        for candidate in [missing, corrupt.path] {
            do {
                try await state.applyLedgerSettings(dbPath: candidate, me: "Wrong Owner")
                XCTFail("Invalid database settings were applied")
            } catch {}
            XCTAssertEqual(AppSettings.dbPath, original.path)
            XCTAssertEqual(AppSettings.me, "Original Owner")
            XCTAssertEqual(state.ledger?.total(at: .distantFuture).sum, 400)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "Validation must not create an empty ledger at a mistyped path")
        try original.question(id: "still-original")
        state.pollAsk()
        XCTAssertEqual(state.ask?.id, "still-original")
        state.answer("확인")
        XCTAssertEqual(try original.writer.state("ask:answer:still-original"), "확인")

        let updated = expectation(description: "Previous monitor remains connected after failure")
        let subscription = state.$ledger.compactMap { $0?.total(at: .distantFuture).sum }
            .filter { $0 == 600 }.prefix(1).sink { _ in updated.fulfill() }
        try original.snapshot(balance: 600)
        await fulfillment(of: [updated], timeout: 3)
        withExtendedLifetime(subscription) {}
    }

    private final class Fixture {
        let directory: URL
        let path: String
        let writer: DB

        init(balance: Int) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiLedgerSettings-" + UUID().uuidString)
            path = directory.appendingPathComponent("ledger.db").path
            writer = try DB(path: path, writable: true)
            try writer.insertSnapshot(ts: "2026-09-02 12:00", app: "TEST", account: "Synthetic account",
                                      balance: balance, shot: "synthetic.png")
        }

        func snapshot(balance: Int) throws {
            try writer.insertSnapshot(ts: "2026-09-02 12:01", app: "TEST", account: "Synthetic account",
                                      balance: balance, shot: "synthetic.png")
        }

        func question(id: String) throws {
            let question: [String: Any] = ["id": id, "html": "Synthetic question", "options": ["확인", "보류"]]
            try writer.setState("ask:pending", String(decoding: JSONSerialization.data(withJSONObject: question), as: UTF8.self))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private struct SettingsBackup {
        private let path = UserDefaults.standard.object(forKey: "dbPath")
        private let name = UserDefaults.standard.object(forKey: "me")
        func restore() {
            if let path { UserDefaults.standard.set(path, forKey: "dbPath") }
            else { UserDefaults.standard.removeObject(forKey: "dbPath") }
            if let name { UserDefaults.standard.set(name, forKey: "me") }
            else { UserDefaults.standard.removeObject(forKey: "me") }
        }
    }
}
