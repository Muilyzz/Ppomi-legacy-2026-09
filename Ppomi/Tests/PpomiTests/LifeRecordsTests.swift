import XCTest
@testable import Ppomi

final class LifeRecordsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-records-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func store(_ name: String = "records") throws -> LifeStore { try LifeStore(path: folder.appendingPathComponent(name + ".sqlite").path) }
    private func measurement(_ person: LifeEntity, sourceID: String? = "measurement-001", weight: Double = 72.3) -> LifeRecord {
        LifeRecord(subjectID: person.id, kind: .measurement,
                   occurredAt: LifeJSON.parseTimestamp("2026-09-06T08:00:00+09:00")!,
                   sourceName: "Synthetic InBody", sourceRecordID: sourceID, method: .ocr,
                   metrics: [.init(code: "weight", title: "체중", value: weight, unit: "kg")], device: "Synthetic H20")
    }

    func testSelfIdentityPersistsAndNamesDoNotMergeAccountsOrCorporations() throws {
        let first = try store(); let person = try first.ensureSelfEntity()
        let second = try store()
        XCTAssertEqual(try second.ensureSelfEntity(), person)
        let business = LifeEntity(kind: .organization, name: "나")
        let a = LifeEntity(kind: .account, name: "주거래"), b = LifeEntity(kind: .account, name: "주거래")
        try first.save(entity: business); try first.save(entity: a); try first.save(entity: b)
        XCTAssertEqual(try second.entities().count, 4)
        XCTAssertNotEqual(person.id, business.id); XCTAssertNotEqual(a.id, b.id)
    }

    func testSourceDuplicatePreservesReviewAndChangedFactConflicts() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let initial = measurement(person)
        XCTAssertEqual(try db.save(initial), .inserted(initial.id))
        try db.markReviewed(id: initial.id)
        let repeated = measurement(person)
        XCTAssertEqual(try db.save(repeated), .duplicate(initial.id))
        XCTAssertEqual(try db.record(id: initial.id)?.review, .userConfirmed)
        XCTAssertThrowsError(try db.save(measurement(person, weight: 73.1)))
        let anotherPerson = LifeEntity(kind: .person, name: "다른 사람")
        try db.save(entity: anotherPerson)
        XCTAssertThrowsError(try db.save(measurement(anotherPerson)))
        XCTAssertEqual(try db.allRecords().count, 1)
    }

    func testNoSourceIdentityDoesNotCollapseManualMeasurements() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let first = measurement(person, sourceID: nil), second = measurement(person, sourceID: nil)
        try db.save(first); try db.save(second)
        XCTAssertEqual(try db.allRecords().count, 2)
        XCTAssertEqual(try db.save(first), .duplicate(first.id))
    }

    func testMissingMetricIsNotConvertedToZeroAndUnitsAreChecked() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let record = measurement(person)
        try db.save(record)
        let read = try XCTUnwrap(db.allRecords().first)
        XCTAssertNil(read.metrics.first { $0.code == "bodyFatPercent" })
        XCTAssertThrowsError(try LifeMetric(code: "weight", title: "체중", value: 72.3, unit: "lb").validate())
        XCTAssertThrowsError(try LifeMetric(code: "weight", title: "체중", value: .nan, unit: "kg").validate())
        XCTAssertThrowsError(try LifeMetric(code: "weight", title: "체중", value: 0, unit: "kg").validate())
        XCTAssertNoThrow(try LifeMetric(code: "balance", title: "잔액", value: 0, unit: "KRW").validate())
        XCTAssertThrowsError(try LifeMetric(code: "extracellularWaterRatio", title: "세포외수분비", value: 1.2, unit: "ratio").validate())
        XCTAssertNoThrow(try LifeMetric(code: "extracellularWaterRatio", title: "세포외수분비", value: 0.38, unit: "ratio").validate())
    }

    func testDatesRequireTimezoneAndRejectCalendarRollovers() throws {
        XCTAssertEqual(LifeJSON.parseTimestamp("2026-09-06T08:00:00+09:00"), LifeJSON.parseTimestamp("2026-09-05T23:00:00Z"))
        for invalid in ["2026-09-06", "2026-09-06T08:00:00", "2026-02-30T08:00:00Z", "2026-09-06T25:00:00Z", "2026-09-06T08:00:00+15:00"] {
            XCTAssertNil(LifeJSON.parseTimestamp(invalid), invalid)
        }
        let text = String(decoding: try LifeExamples.importTemplate(), as: UTF8.self)
        let invalid = text.replacingOccurrences(of: "2026-09-05T23:00:00.000Z", with: "2026-09-06T08:00:00")
        XCTAssertThrowsError(try store().importJSON(Data(invalid.utf8)))
    }

    func testRevisionAndProvenanceSurviveExportRoundtrip() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let initial = measurement(person); try db.save(initial)
        var revised = try XCTUnwrap(db.record(id: initial.id))
        revised.metrics[0].value = 72.8; revised.review = .userConfirmed
        try db.revise(revised, reason: "결과지와 대조해 OCR 오독 수정")
        let target = try store("import")
        let result = try target.importJSON(db.exportJSON())
        XCTAssertEqual(result, LifeImportResult(inserted: 1, duplicates: 0))
        XCTAssertEqual(try target.allRecords(), try db.allRecords())
        let revisions = try target.revisions(recordID: initial.id)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.previous.metrics.first?.value, 72.3)
        XCTAssertEqual(revisions.first?.previous.review, .unreviewed)
        XCTAssertEqual(revisions.first?.previous.device, "Synthetic H20")
        XCTAssertEqual(try target.importJSON(db.exportJSON()), LifeImportResult(inserted: 0, duplicates: 1))
    }

    func testImportConflictRollsBackEveryRowAndUnknownSubjectsAreRejected() throws {
        let db = try store(); let person = try db.ensureSelfEntity(); try db.save(measurement(person))
        let extra = LifeEntity(kind: .person, name: "롤백 대상")
        let good = measurement(extra, sourceID: "another")
        let conflict = measurement(person, weight: 80)
        let data = try LifeJSON.encoder().encode(LifeArchive(entities: [extra], records: [good, conflict]))
        XCTAssertThrowsError(try db.importJSON(data))
        XCTAssertEqual(try db.allRecords().count, 1)
        XCTAssertNil(try db.entity(id: extra.id))
        XCTAssertThrowsError(try db.save(measurement(LifeEntity(kind: .person, name: "미등록"))))
    }

    func testEvidenceIsCopiedPrivatelyAndExportCannotOpenSourcePaths() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        let source = folder.appendingPathComponent("synthetic-note.txt")
        try Data("Synthetic local evidence".utf8).write(to: source)
        let evidence = try db.addEvidence(from: source)
        var record = measurement(person); record.evidenceIDs = [evidence.id]
        try db.save(record)
        try FileManager.default.removeItem(at: source)
        let managed = try XCTUnwrap(db.managedEvidenceURL(id: evidence.id))
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "Synthetic local evidence")
        let exported = try db.exportJSON()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(folder.path))
        let target = try LifeStore(path: folder.appendingPathComponent("separate/records.sqlite").path)
        _ = try target.importJSON(exported)
        XCTAssertNil(try target.managedEvidenceURL(id: evidence.id))
        XCTAssertEqual(try target.evidence().count, 1)
    }

    func testSchemaExportSeparatesSourceMethodFromMeasurementMeaning() throws {
        let db = try store(); let person = try db.ensureSelfEntity()
        try db.save(measurement(person))
        let meal = LifeRecord(subjectID: person.id, kind: .meal, occurredAt: Date(), sourceName: "직접 기록", method: .aiEstimate,
                              metrics: [.init(code: "energy", title: "추정 열량", value: 550, unit: "kcal")], note: "가상 식사")
        try db.save(meal)
        let exercise = LifeRecord(subjectID: person.id, kind: .exercise, occurredAt: Date(), sourceName: "직접 기록", method: .manual,
                                  metrics: [.init(code: "duration", title: "시간", value: 30, unit: "min")], note: "가상 걷기")
        try db.save(exercise)
        let export = try XCTUnwrap(JSONSerialization.jsonObject(with: db.exportJSONLD()) as? [String: Any])
        let graph = try XCTUnwrap(export["@graph"] as? [[String: Any]])
        let observations = graph.filter { $0["@type"] as? String == "Observation" }
        XCTAssertEqual(observations.count, 3)
        XCTAssertEqual(observations.first { $0["name"] as? String == "체중" }?["unitText"] as? String, "kg")
        XCTAssertTrue(graph.contains { ($0["@type"] as? [String])?.contains("EatAction") == true })
        XCTAssertTrue(graph.contains { ($0["@type"] as? [String])?.contains("ExerciseAction") == true })
        XCTAssertFalse(graph.contains { $0["measurementMethod"] != nil })
        XCTAssertEqual(observations.first { $0["name"] as? String == "추정 열량" }?["ppomi:acquisitionMethod"] as? String, "aiEstimate")
        XCTAssertFalse(String(decoding: try db.exportJSONLD(), as: UTF8.self).contains("paymentApproval"))
    }

    func testDocumentedFixtureImportsWithoutInventingPersonalIdentity() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("docs/schemas/life-records.example.json"))
        let db = try store(); let selfEntity = try db.ensureSelfEntity()
        XCTAssertEqual(try db.importJSON(data), LifeImportResult(inserted: 1, duplicates: 0))
        XCTAssertNotEqual(try db.allRecords().first?.subjectID, selfEntity.id)
        XCTAssertEqual(try db.allRecords().first?.metrics.count, 3)
    }

    func testStaleEditorAndReviewCannotOverwriteOrCertifyAnotherWritersChange() throws {
        let a = try store(), b = try store()
        let person = try a.ensureSelfEntity(); let initial = measurement(person)
        try a.save(initial)
        let displayed = try XCTUnwrap(a.record(id: initial.id))
        var changed = displayed; changed.metrics[0].value = 73
        try b.revise(changed, reason: "다른 수집 작업의 수정", expectedPrevious: displayed)
        var staleEdit = displayed; staleEdit.note = "이전 화면을 보고 작성한 메모"
        XCTAssertThrowsError(try a.revise(staleEdit, reason: "오래된 편집창", expectedPrevious: displayed))
        XCTAssertThrowsError(try a.markReviewed(id: initial.id, expectedPrevious: displayed))
        let current = try XCTUnwrap(a.record(id: initial.id))
        XCTAssertEqual(current.metrics[0].value, 73)
        XCTAssertEqual(current.review, .unreviewed)
        XCTAssertEqual(try a.revisions(recordID: initial.id).count, 1)
        try a.markReviewed(id: initial.id, expectedPrevious: current)
        XCTAssertEqual(try a.record(id: initial.id)?.review, .userConfirmed)
    }
}
