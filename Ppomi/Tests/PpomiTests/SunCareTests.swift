import XCTest
@testable import Ppomi

final class SunCareTests: XCTestCase {
    // Synthetic habit confirmations only. No production store or real completion is created.
    private var folder: URL!
    private var store: LifeStore!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-suncare-tests-" + UUID().uuidString)
        let testClock = LifeJSON.parseTimestamp("2026-09-30T12:00:00+09:00")!
        store = try LifeStore(path: folder.appendingPathComponent("records.sqlite").path, now: { testClock })
    }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
    private let now = LifeJSON.parseTimestamp("2026-09-06T12:00:00+09:00")!
    private func confirmation(person: String, at: Date, activity: String = "sunscreen", status: LifeRecord.ActivityStatus = .completed) -> LifeRecord {
        LifeRecord(subjectID: person, kind: .habit, occurredAt: at, sourceName: "Synthetic habit", method: .manual,
                   activityID: activity, activityStatus: status,
                   activityDay: SunCare.dayKey(at), activityTimeZone: "Asia/Seoul")
    }

    func testRepeatedClickRecordsOneDayAndNeverInventsApplicationTime() throws {
        let person = try store.ensureSelfEntity()
        let first = try SunCare.logApplication(subjectID: person.id, at: now, to: store)
        let record = try XCTUnwrap(store.allRecords().first)
        XCTAssertEqual(first, .recorded(record.id))
        XCTAssertEqual(try SunCare.logApplication(subjectID: person.id, at: now.addingTimeInterval(3600), to: store), .alreadyRecorded(record.id))
        XCTAssertEqual(try store.allRecords().count, 1)
        XCTAssertEqual(record.activityID, "sunscreen")
        XCTAssertEqual(record.activityStatus, .completed)
        XCTAssertEqual(record.method, .manual)
        XCTAssertEqual(record.review, .unreviewed)
        XCTAssertTrue(record.note?.contains("표시 시각은 확인 시각") == true)
        XCTAssertTrue(record.metrics.isEmpty)
    }

    func testUnrecordedDaysStayUnknownAndWindowsCountUniqueDatesOnly() throws {
        let person = try store.ensureSelfEntity(), other = LifeEntity(kind: .person, name: "가상 다른 사람")
        try store.save(entity: other)
        let cal = SunCare.defaultCalendar
        var records = [0, -1, -6, -7, -27, -28].map { offset in
            confirmation(person: person.id, at: cal.date(byAdding: .day, value: offset, to: now)!)
        }
        records += [confirmation(person: person.id, at: now), confirmation(person: person.id, at: now, activity: "water"),
                    confirmation(person: other.id, at: cal.date(byAdding: .day, value: -2, to: now)!),
                    confirmation(person: person.id, at: now.addingTimeInterval(86_400)),
                    confirmation(person: person.id, at: cal.date(byAdding: .day, value: -3, to: now)!, status: .retracted)]
        let summary = SunCare.summary(records: records, subjectID: person.id, now: now)
        XCTAssertEqual(summary.last7DaysCount, 3)
        XCTAssertEqual(summary.last28DaysCount, 5)
        XCTAssertTrue(summary.todayCompleted)
        XCTAssertEqual(summary.cells.count, 28)
        XCTAssertEqual(summary.cells.first?.dayKey, "2026-08-10")
        XCTAssertEqual(summary.cells.last?.dayKey, "2026-09-06")
        XCTAssertEqual(summary.cells.filter { $0.status == .unrecorded }.count, 23)
        XCTAssertTrue(try store.allRecords().isEmpty, "Computing a calendar must not create any completion")
    }

    func testExplicitTimeZoneControlsDayBoundaryIncludingDST() throws {
        let person = try store.ensureSelfEntity()
        let at = LifeJSON.parseTimestamp("2026-09-06T23:30:00Z")!
        _ = try SunCare.logApplication(subjectID: person.id, at: at, to: store)
        let korean = SunCare.summary(records: try store.allRecords(), subjectID: person.id, now: at)
        XCTAssertEqual(korean.cells.last?.dayKey, "2026-09-07")
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let american = SunCare.summary(records: try store.allRecords(), subjectID: person.id, now: at, calendar: la)
        XCTAssertEqual(american.cells.last?.dayKey, "2026-09-06")
        XCTAssertFalse(american.todayCompleted, "The originally reported activity date must not be rewritten after a timezone change")
        XCTAssertEqual(try store.allRecords().first?.activityDay, "2026-09-07")
        let dst = SunCare.summary(records: [], subjectID: person.id, now: LifeJSON.parseTimestamp("2026-03-09T08:00:00Z")!, calendar: la)
        XCTAssertEqual(dst.cells.count, 28)
        XCTAssertEqual(Set(dst.cells.map(\.dayKey)).count, 28)
        XCTAssertEqual(dst.cells.last?.dayKey, "2026-03-09")
    }

    func testSpokenAndButtonReportsCountOneDayAndRetractionKeepsRevisions() throws {
        let person = try store.ensureSelfEntity()
        _ = try SunCare.logApplication(subjectID: person.id, at: now, to: store)
        let buttonID = try XCTUnwrap(store.allRecords().first?.id)
        _ = try HealthTools.record(["kind": "habit", "activityID": "sunscreen", "occurredAt": LifeJSON.timestamp(now),
                                    "sourceID": "synthetic-spoken-report", "attribution": "reported",
                                    "activityDay": "2026-09-06", "activityTimeZone": "Asia/Seoul"], store: store)
        XCTAssertEqual(try store.allRecords().count, 2)
        XCTAssertEqual(SunCare.summary(records: try store.allRecords(), subjectID: person.id, now: now).last7DaysCount, 1)
        XCTAssertEqual(try SunCare.retractApplication(subjectID: person.id, on: now, to: store), 2)
        XCTAssertEqual(try store.revisions().count, 2)
        XCTAssertFalse(SunCare.summary(records: try store.allRecords(), subjectID: person.id, now: now).todayCompleted)
        XCTAssertEqual(try SunCare.retractApplication(subjectID: person.id, on: now, to: store), 0)
        XCTAssertEqual(try SunCare.logApplication(subjectID: person.id, at: now, to: store), .restored(buttonID))
        XCTAssertEqual(try store.revisions().count, 3)
        XCTAssertTrue(SunCare.summary(records: try store.allRecords(), subjectID: person.id, now: now).todayCompleted)
    }

    func testOnlyPersonAndManualHabitFactsAreAcceptedAndOldJSONStillDecodes() throws {
        let person = try store.ensureSelfEntity(), account = LifeEntity(kind: .account, name: "가상 계좌")
        try store.save(entity: account)
        XCTAssertThrowsError(try SunCare.logApplication(subjectID: account.id, at: now, to: store))
        XCTAssertThrowsError(try store.save(confirmation(person: account.id, at: now)))
        var estimated = confirmation(person: person.id, at: now); estimated.method = .aiEstimate
        XCTAssertThrowsError(try store.save(estimated))
        var invalid = confirmation(person: person.id, at: now); invalid.activityID = "not a stable ID"
        XCTAssertThrowsError(try store.save(invalid))
        invalid.activityID = nil
        XCTAssertThrowsError(try store.save(invalid))
        invalid.activityID = "sunscreen"; invalid.activityStatus = nil
        XCTAssertThrowsError(try store.save(invalid))
        invalid.kind = .meal; invalid.activityStatus = .completed; invalid.note = "가상의 식사"
        XCTAssertThrowsError(try store.save(invalid))
        let archive = try LifeJSON.decoder().decode(LifeArchive.self, from: LifeExamples.importTemplate())
        XCTAssertNil(archive.records.first?.activityID)
        XCTAssertNil(archive.records.first?.activityStatus)
        XCTAssertNil(archive.records.first?.activityDay)
    }

    func testHabitJSONRoundtripAndSchemaDoesNotClaimActualActionTime() throws {
        let person = try store.ensureSelfEntity()
        _ = try SunCare.logApplication(subjectID: person.id, at: now, to: store)
        let archive = try store.exportJSON()
        let imported = try LifeStore(path: folder.appendingPathComponent("import/records.sqlite").path)
        _ = try imported.importJSON(archive)
        XCTAssertEqual(try imported.allRecords(), try store.allRecords())
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportJSONLD()) as? [String: Any])
        let graph = try XCTUnwrap(exported["@graph"] as? [[String: Any]])
        let node = try XCTUnwrap(graph.first { $0["ppomi:activityID"] as? String == "sunscreen" })
        XCTAssertEqual(node["ppomi:activityStatus"] as? String, "completed")
        XCTAssertEqual(node["ppomi:activityDay"] as? String, "2026-09-06")
        XCTAssertEqual(node["ppomi:activityTimeZone"] as? String, "Asia/Seoul")
        XCTAssertNotNil(node["ppomi:confirmationTime"])
        XCTAssertNil(node["startTime"])
        XCTAssertNil(node["value"])
    }

    func testYesterdayReportedTodayCountsYesterdayAndFutureReportsCannotBeStored() throws {
        let fixedNow = now
        let db = try LifeStore(path: folder.appendingPathComponent("fixed-clock/records.sqlite").path, now: { fixedNow })
        let person = try db.ensureSelfEntity()
        var yesterday = confirmation(person: person.id, at: fixedNow)
        yesterday.activityDay = "2026-09-05"
        try db.save(yesterday)
        let summary = SunCare.summary(records: try db.allRecords(), subjectID: person.id, now: fixedNow)
        XCTAssertFalse(summary.todayCompleted)
        XCTAssertTrue(summary.cells.first { $0.dayKey == "2026-09-05" }?.isCompleted == true)
        XCTAssertEqual(summary.last7DaysCount, 1)
        XCTAssertThrowsError(try SunCare.logApplication(subjectID: person.id, at: fixedNow.addingTimeInterval(60), to: db))
        var futureDay = confirmation(person: person.id, at: fixedNow); futureDay.activityDay = "2026-09-07"
        XCTAssertThrowsError(try db.save(futureDay))
        var malformed = confirmation(person: person.id, at: fixedNow); malformed.activityDay = "2026-02-30"
        XCTAssertThrowsError(try db.save(malformed))
        malformed.activityDay = "2026-09-06"; malformed.activityTimeZone = "Moon/Station"
        XCTAssertThrowsError(try db.save(malformed))
        XCTAssertEqual(try db.allRecords().count, 1)
        let tomorrow = SunCare.summary(records: try db.allRecords(), subjectID: person.id, now: fixedNow.addingTimeInterval(86_400))
        XCTAssertFalse(tomorrow.todayCompleted, "Advancing the clock must not reveal a scheduled fake completion")
    }
}
