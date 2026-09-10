import XCTest
@testable import Ppomi

final class InBodyImportTests: XCTestCase {
    // All dates, numbers, and labels below are synthetic fixtures, not user readings.
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-inbody-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func store() throws -> LifeStore { try LifeStore(path: folder.appendingPathComponent("records.sqlite").path) }
    private let list = """
        인바디 결과관리 — 가상 테스트
        2026.09.06 (일) 08:00
        체중 72.3 kg
        체지방률 20.1 %
        2026.09.05 (토) 08:10
        체중 72.5 kg
        골격근량 31.0 kg
        InBody 970S
        """
    private let detail = """
        인바디 결과 상세 — 가상 테스트
        2026.09.06 08:00
        체중 72.3 kg
        골격근량 31.2 kg
        체지방량 14.5 kg
        체지방률 20.1 %
        세포외수분비 0.380
        BMI 23.2
        내장지방레벨 7
        InBody Dial H20
        """

    func testListKeepsEachDatesMetricsAndDeviceSeparate() throws {
        let values = try InBodyImport.parse(list)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].date, LifeJSON.parseTimestamp("2026-09-05T23:00:00Z"))
        XCTAssertNil(values[0].device)
        XCTAssertNil(values[0].metrics.first { $0.code == "skeletalMuscleMass" })
        XCTAssertEqual(values[1].device, "InBody 970S")
        XCTAssertEqual(values[1].metrics.first { $0.code == "weight" }?.value, 72.5)
    }

    func testDetailReadsCanonicalUnitsAndRetainsVisibleSeconds() throws {
        let value = try XCTUnwrap(InBodyImport.parse(detail).first)
        XCTAssertEqual(value.metrics.count, 7)
        XCTAssertEqual(value.device, "InBody H20")
        XCTAssertEqual(value.metrics.first { $0.code == "extracellularWaterRatio" }?.unit, "ratio")
        XCTAssertEqual(value.metrics.first { $0.code == "bmi" }?.unit, "kg/m2")
        let seconds = try XCTUnwrap(InBodyImport.parse(detail.replacingOccurrences(of: "08:00", with: "08:00:42")).first)
        XCTAssertEqual(seconds.date, value.date.addingTimeInterval(42))
    }

    func testWrongScreensMissingDatesAndConflictingNumbersAreRejected() {
        for wrong in ["은행 2026.09.06 08:00 체중 72.3", "인바디 체중 72.3", "인바디 2026.02.30 08:00 체중 72.3",
                      "인바디 2026.09.06 25:00 체중 72.3", "인바디 2026.09.06 08:00 체중 72.3 체중 81.0",
                      "인바디 2026.09.06 08:00 세포외수분비 1.8"] {
            XCTAssertThrowsError(try InBodyImport.parse(wrong), wrong)
        }
    }

    func testRepeatAndDetailEnrichmentUseOneSourceRecordAndRevision() throws {
        let db = try store()
        let first = try XCTUnwrap(InBodyImport.parse(list).first)
        let richer = try XCTUnwrap(InBodyImport.parse(detail).first)
        XCTAssertEqual(first.sourceID, richer.sourceID)
        XCTAssertTrue(try InBodyImport.save([first], evidenceIDs: [], to: db).contains("새 측정 1건"))
        XCTAssertTrue(try InBodyImport.save([first], evidenceIDs: [], to: db).contains("기존 기록 1건"))
        XCTAssertTrue(try InBodyImport.save([richer], evidenceIDs: [], to: db).contains("항목 보완 1건"))
        let all = try db.allRecords(); XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].device, "InBody H20")
        XCTAssertEqual(all[0].metrics.count, 7)
        let revisions = try db.revisions(recordID: all[0].id)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertNil(revisions[0].previous.device)
        XCTAssertEqual(revisions[0].previous.metrics.count, 2)
        XCTAssertTrue(try InBodyImport.save([first], evidenceIDs: [], to: db).contains("기존 기록 1건"))
        XCTAssertEqual(try db.revisions().count, 1)
    }

    func testDeviceOnlyEnrichmentAndConflictsNeverOverwriteConfirmedFact() throws {
        let db = try store(); var value = try XCTUnwrap(InBodyImport.parse(list).first)
        _ = try InBodyImport.save([value], evidenceIDs: [], to: db)
        value.device = "InBody H20"
        XCTAssertTrue(try InBodyImport.save([value], evidenceIDs: [], to: db).contains("항목 보완 1건"))
        let id = try XCTUnwrap(db.allRecords().first?.id)
        try db.markReviewed(id: id)
        var differentDevice = value; differentDevice.device = "InBody 970S"
        XCTAssertTrue(try InBodyImport.save([differentDevice], evidenceIDs: [], to: db).contains("값 충돌 1건"))
        var differentValue = value; differentValue.metrics[0].value = 99
        XCTAssertTrue(try InBodyImport.save([differentValue], evidenceIDs: [], to: db).contains("값 충돌 1건"))
        XCTAssertEqual(try db.allRecords().count, 1)
        XCTAssertEqual(try db.record(id: id)?.review, .userConfirmed)
        XCTAssertEqual(try db.record(id: id)?.device, "InBody H20")
        XCTAssertEqual(try db.record(id: id)?.metrics.first?.value, 72.3)
    }

    func testLegacyDeviceSuffixedSourceCanEnrichWithoutDuplicating() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let value = try XCTUnwrap(InBodyImport.parse(list).first)
        let legacy = LifeRecord(subjectID: person.id, kind: .measurement, occurredAt: value.date,
                                sourceName: "InBody", sourceRecordID: value.sourceID + ":unknown", method: .ocr, metrics: value.metrics)
        try db.save(legacy)
        let richer = try XCTUnwrap(InBodyImport.parse(detail).first)
        XCTAssertTrue(try InBodyImport.save([richer], evidenceIDs: [], to: db).contains("항목 보완 1건"))
        XCTAssertEqual(try db.allRecords().count, 1)
        XCTAssertEqual(try db.allRecords().first?.id, legacy.id)
    }

    func testExistingPrivateCaptureDirectoryAndFilePermissionsAreTightened() throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let staging = folder.appendingPathComponent("capture-staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let db = try store()
        let result = try InBodyImport.prepareCaptureDirectory(for: db)
        XCTAssertEqual(result.standardizedFileURL, staging.standardizedFileURL)
        let file = result.appendingPathComponent("synthetic.png")
        try Data("synthetic screenshot".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try InBodyImport.protectCaptureFile(file)
        XCTAssertEqual((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath: staging.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: db.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
