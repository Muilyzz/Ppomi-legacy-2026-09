import XCTest
@testable import Ppomi

final class LifeFinanceImportTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-finance-projection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private var ledgerURL: URL { folder.appendingPathComponent("ledger.sqlite") }
    private func target() throws -> LifeStore { try LifeStore(path: folder.appendingPathComponent("private/records.sqlite").path) }
    private func populate() throws {
        let db = try DB(path: ledgerURL.path, writable: true)
        try db.insertSnapshot(ts: "2026-09-06 08:00", app: "SYNTHETIC", account: "동일한 표시 이름", balance: 123_456, shot: "snapshot.png")
        try db.exec("INSERT INTO transactions(ts,kind,amount,merchant,card,source,status,uid) VALUES(?,?,?,?,?,?,?,?)",
                    ["2026-09-06 08:03:12", "withdrawal", -2500, "예시 상점", "동일한 표시 이름", "app:SYNTHETIC", "confirmed", "synthetic-uid"])
    }

    func testReadonlyProjectionPreservesProvenanceAndDoesNotInferAccountsOrReview() throws {
        try populate(); let originalBytes = try Data(contentsOf: ledgerURL); let destination = try target()
        let message = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        XCTAssertTrue(message.contains("2건 추가"))
        XCTAssertEqual(try Data(contentsOf: ledgerURL), originalBytes)
        let rows = try destination.allRecords()
        let balance = try XCTUnwrap(rows.first { $0.kind == .financialSnapshot })
        let transaction = try XCTUnwrap(rows.first { $0.kind == .financialTransaction })
        XCTAssertNotEqual(balance.subjectID, transaction.subjectID)
        XCTAssertEqual(balance.metrics.first?.value, 123_456)
        XCTAssertEqual(transaction.metrics.first?.value, -2500)
        XCTAssertEqual(rows.map(\.review), [.unreviewed, .unreviewed])
        XCTAssertTrue(rows.allSatisfy { $0.method == .legacyImport })
        XCTAssertTrue(transaction.note?.contains("confirmed") == true)
        XCTAssertTrue(transaction.note?.contains("withdrawal") == true)
        XCTAssertTrue(transaction.note?.contains("app:SYNTHETIC") == true)
        XCTAssertEqual(balance.occurredAt, LifeJSON.parseTimestamp("2026-09-05T23:00:00Z"))
        XCTAssertEqual(transaction.occurredAt, LifeJSON.parseTimestamp("2026-09-05T23:03:12Z"))
        XCTAssertTrue(try destination.entities().allSatisfy { $0.kind == .account })
        let export = String(decoding: try destination.exportJSON(), as: UTF8.self)
        XCTAssertFalse(export.contains(folder.path))
        XCTAssertFalse(balance.subjectID.contains("동일한"))
    }

    func testStableNamespacesMakeRerunIdempotentAndChangedSourceConflicts() throws {
        try populate(); let destination = try target()
        _ = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        let ids = Set(try destination.allRecords().map(\.id))
        let again = try LifeFinanceImport.run(to: target(), dbPath: ledgerURL.path)
        XCTAssertTrue(again.contains("기존 2건"))
        XCTAssertEqual(Set(try destination.allRecords().map(\.id)), ids)
        do {
            let db = try DB(path: ledgerURL.path, writable: true)
            try db.exec("UPDATE snapshots SET balance=? WHERE id=?", [999, 1])
        }
        let conflict = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        XCTAssertTrue(conflict.contains("값 충돌 1건"))
        XCTAssertEqual(try destination.allRecords().first { $0.kind == .financialSnapshot }?.metrics.first?.value, 123_456)
    }

    func testMissingAndMalformedValuesAreSkippedWithoutInventingZero() throws {
        let db = try DB(path: ledgerURL.path, writable: true)
        try db.insertSnapshot(ts: "2026-02-30 08:00", app: "SYNTHETIC", account: "예시", balance: 10, shot: "")
        try db.insertSnapshot(ts: "2026-09-06 08:00", app: "SYNTHETIC", account: "예시", balance: 0, shot: "")
        try db.exec("INSERT INTO transactions(ts,kind,amount) VALUES(?,?,?)", ["시각 미상", "approval", 100])
        let destination = try target()
        let result = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        XCTAssertTrue(result.contains("형식 미확인 2건"))
        XCTAssertEqual(try destination.allRecords().count, 1)
        XCTAssertEqual(try destination.allRecords().first?.metrics.first?.value, 0)
        XCTAssertNil(LifeFinanceImport.parseLegacyTimestamp("2026-09-06"))
    }

    func testOnlyAdjacentRegularEvidenceIsCopiedAndRerunsReuseIt() throws {
        try populate()
        let shots = folder.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let safe = shots.appendingPathComponent("snapshot.png")
        try Data("synthetic evidence bytes".utf8).write(to: safe)
        let outside = folder.appendingPathComponent("outside.png")
        try Data("must not copy".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: shots.appendingPathComponent("linked.png"), withDestinationURL: outside)
        XCTAssertNotNil(LifeFinanceImport.safeEvidenceURL(shot: "snapshot.png", sourceURL: ledgerURL))
        for unsafe in ["../outside.png", outside.path, "linked.png", "missing.png", "..\\outside.png"] {
            XCTAssertNil(LifeFinanceImport.safeEvidenceURL(shot: unsafe, sourceURL: ledgerURL), unsafe)
        }
        let destination = try target()
        _ = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        _ = try LifeFinanceImport.run(to: destination, dbPath: ledgerURL.path)
        XCTAssertEqual(try destination.evidence().count, 1)
        let id = try XCTUnwrap(destination.evidence().first?.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(destination.managedEvidenceURL(id: id))), Data("synthetic evidence bytes".utf8))
    }
}
