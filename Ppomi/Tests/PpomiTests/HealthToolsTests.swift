import XCTest
@testable import Ppomi

final class HealthToolsTests: XCTestCase {
    private var folder: URL!
    private var store: LifeStore!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-health-tools-tests-" + UUID().uuidString)
        store = try LifeStore(path: folder.appendingPathComponent("records.sqlite").path)
    }
    override func tearDownWithError() throws {
        Tools.fake = nil; store = nil
        try FileManager.default.removeItem(at: folder)
    }
    private func args(sourceID: String = "synthetic-meal-001") -> [String: Any] {
        ["kind": "meal", "occurredAt": "2026-09-06T12:30:00+09:00", "sourceID": sourceID,
         "attribution": "reported", "note": "테스트용 식사 기록"]
    }
    private func decoded(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func tools() throws -> Tools {
        let tools = try Tools(db: DB(path: folder.appendingPathComponent("ledger.sqlite").path, writable: true))
        tools.healthStorePath = store.path
        return tools
    }

    func testReportedAndEstimatedRecordsStayDistinctAndUnreviewed() throws {
        let reported = try decoded(HealthTools.record(args(), store: store))
        XCTAssertEqual(reported["review"] as? String, "unreviewed")
        var estimate = args(sourceID: "synthetic-meal-estimate-001")
        estimate["attribution"] = "aiEstimate"
        estimate["metrics"] = #"[{"code":"energy","title":"추정 열량","value":500,"unit":"kcal"}]"#
        _ = try HealthTools.record(estimate, store: store)
        let rows = try store.allRecords()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.method)), [.manual, .aiEstimate])
        XCTAssertTrue(rows.allSatisfy { $0.review == .unreviewed && $0.sourceName == "Ppomi agent" })
        XCTAssertTrue(rows.first { $0.method == .manual }!.metrics.isEmpty)
    }

    func testSourceRetryIsIdempotentPreservesHumanReviewAndConflictsOnChangedFact() throws {
        let first = try decoded(HealthTools.record(args(), store: store))
        let id = try XCTUnwrap(first["recordID"] as? String)
        try store.markReviewed(id: id)
        let again = try decoded(HealthTools.record(args(), store: store))
        XCTAssertEqual(again["recordID"] as? String, id)
        XCTAssertEqual(again["status"] as? String, "duplicate")
        XCTAssertEqual(try store.record(id: id)?.review, .userConfirmed)
        var changed = args(); changed["note"] = "원본과 다른 식사"
        XCTAssertThrowsError(try HealthTools.record(changed, store: store))
        var changedMethod = args(); changedMethod["attribution"] = "aiEstimate"
        XCTAssertThrowsError(try HealthTools.record(changedMethod, store: store))
        XCTAssertEqual(try store.allRecords().count, 1)
    }

    func testCannotClaimReviewApiSourceOrInsertFinancialData() throws {
        for (key, value) in [("review", "userConfirmed"), ("approved", "true"), ("method", "api"),
                             ("sourceName", "InBody"), ("evidencePath", "/private/not-allowed")] {
            var a = args(); a[key] = value
            XCTAssertThrowsError(try HealthTools.record(a, store: store), key)
        }
        for kind in ["financialSnapshot", "financialTransaction"] {
            var a = args(); a["kind"] = kind
            XCTAssertThrowsError(try HealthTools.record(a, store: store))
        }
        var financialMetric = args()
        financialMetric["metrics"] = #"[{"code":"amount","title":"금액","value":1000,"unit":"KRW"}]"#
        XCTAssertThrowsError(try HealthTools.record(financialMetric, store: store))
        XCTAssertTrue(try store.allRecords().isEmpty)
    }

    func testDateUnitsUnknownValuesAndSourceIdentityAreValidated() throws {
        for date in ["2026-09-06", "2026-09-06T12:30:00", "2026-02-30T12:30:00+09:00"] {
            var a = args(); a["occurredAt"] = date
            XCTAssertThrowsError(try HealthTools.record(a, store: store))
        }
        for metrics in [
            #"[{"code":"weight","title":"체중","value":72.3,"unit":"lb"}]"#,
            #"[{"code":"weight","title":"체중","value":0,"unit":"kg"}]"#,
            #"[{"code":"weight","title":"체중","value":true,"unit":"kg"}]"#,
            #"[{"code":"weight","title":"체중","value":72.3,"unit":"kg"},{"code":"weight","title":"체중","value":72.3,"unit":"kg"}]"#
        ] {
            var a = args(); a["kind"] = "measurement"; a["metrics"] = metrics
            XCTAssertThrowsError(try HealthTools.record(a, store: store))
        }
        var noID = args(); noID.removeValue(forKey: "sourceID")
        XCTAssertThrowsError(try HealthTools.record(noID, store: store))
        var unknownAttribution = args(); unknownAttribution["attribution"] = "api"
        XCTAssertThrowsError(try HealthTools.record(unknownAttribution, store: store))
        var valid = args(); valid["kind"] = "measurement"
        valid["metrics"] = #"[{"code":"weight","title":"체중","value":72.3,"unit":"kg"}]"#
        _ = try HealthTools.record(valid, store: store)
        let row = try XCTUnwrap(store.allRecords().first)
        XCTAssertEqual(row.metrics.count, 1)
        XCTAssertNil(row.metrics.first { $0.code == "bodyFatPercent" })
    }

    func testQueryDefaultsToSelfSeparatesPeopleAndBoundsResults() throws {
        let me = try store.ensureSelfEntity()
        let other = LifeEntity(kind: .person, name: "같은 이름이어도 다른 사람")
        let account = LifeEntity(kind: .account, name: "계좌")
        try store.save(entity: other); try store.save(entity: account)
        for (index, date) in ["2026-09-05T12:30:00+09:00", "2026-09-06T12:30:00+09:00"].enumerated() {
            var a = args(sourceID: "synthetic-\(index)"); a["occurredAt"] = date
            _ = try HealthTools.record(a, store: store)
        }
        var theirs = args(sourceID: "synthetic-0"); theirs["subjectID"] = other.id
        _ = try HealthTools.record(theirs, store: store)
        try store.save(LifeRecord(subjectID: me.id, kind: .financialSnapshot,
            occurredAt: LifeJSON.parseTimestamp("2026-09-06T13:00:00+09:00")!, sourceName: "Synthetic finance", method: .manual,
            metrics: [.init(code: "balance", title: "잔액", value: 1000, unit: "KRW")]))
        let result = try decoded(HealthTools.records(["limit": 1], store: store))
        let records = try XCTUnwrap(result["records"] as? [[String: Any]])
        XCTAssertEqual(result["totalMatching"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["subjectID"] as? String, me.id)
        XCTAssertEqual(records.first?["occurredAt"] as? String, "2026-09-06T03:30:00.000Z")
        let filtered = try decoded(HealthTools.records(["since": "2026-09-06T00:00:00+09:00", "before": "2026-09-07T00:00:00+09:00"], store: store))
        XCTAssertEqual(filtered["totalMatching"] as? Int, 1)
        XCTAssertEqual(try decoded(HealthTools.records(["subjectID": other.id], store: store))["totalMatching"] as? Int, 1)
        XCTAssertThrowsError(try HealthTools.records(["subjectID": account.id], store: store))
        XCTAssertThrowsError(try HealthTools.records(["subjectID": "unregistered"], store: store))
        XCTAssertThrowsError(try HealthTools.records(["limit": true], store: store))
        XCTAssertThrowsError(try HealthTools.records(["limit": 101], store: store))
        XCTAssertThrowsError(try HealthTools.records(["kind": "financialSnapshot"], store: store))
        XCTAssertFalse(try HealthTools.records([:], store: store).contains(folder.path))
    }

    func testCaptureReusesPhoneGateBeforeOpeningStoreOrCapturing() throws {
        let tools = try tools()
        let capturePath = folder.appendingPathComponent("capture-only.sqlite").path
        tools.healthStorePath = capturePath
        var captures = 0
        tools.captureInBody = { _ in captures += 1; return "synthetic capture" }
        Tools.fake = (screen: { XCTFail("No direct phone screenshot expected"); return [] }, hand: { _ in XCTFail("No phone input expected") })
        tools.currentText = "오늘 뭐 먹었지?"
        XCTAssertTrue(tools.execute("inbody_capture", [:]).hasPrefix("실행 안 함:"))
        XCTAssertEqual(captures, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturePath))
        tools.currentText = "인바디 앱에서 읽어줘"
        XCTAssertTrue(tools.execute("inbody_capture", ["review": "userConfirmed"]).hasPrefix("오류:"))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(tools.execute("inbody_capture", [:]), "synthetic capture")
        XCTAssertEqual(captures, 1)
    }

    func testMCPAndVoicePublishSameToolsAndWritesStayOutOfFinancialLedger() throws {
        for name in ["health_records", "record_health", "inbody_capture"] {
            let voice = try XCTUnwrap(Tools.specs.first { $0.name == name })
            let mcp = try XCTUnwrap(MCPServer.tools.first { $0.name == name })
            XCTAssertEqual(voice.required, mcp.required)
            XCTAssertEqual(Set(voice.params.keys), Set(mcp.params.keys))
            XCTAssertNil(voice.params["review"]); XCTAssertNil(voice.params["approved"])
        }
        let tools = try tools()
        let recorded = try decoded(tools.execute("record_health", args()))
        XCTAssertEqual(recorded["status"] as? String, "inserted")
        let read = try decoded(tools.execute("health_records", [:]))
        XCTAssertEqual(read["totalMatching"] as? Int, 1)
        XCTAssertEqual(try tools.db.scalar("SELECT COUNT(*) FROM transactions") as? Int, 0)
    }

    func testHealthCaptureNeverUsesLegacyWakeCaptureAndRequiresConnectedPhone() throws {
        let tools = try tools()
        tools.currentText = "인바디 앱에서 읽어줘"
        var wakes = 0, captures = 0
        tools.wakePhone = { wakes += 1 }
        tools.captureInBody = { _ in captures += 1; return "private synthetic capture" }
        tools.phoneGateStatus = { (true, "CONNECTED") }
        XCTAssertEqual(tools.execute("inbody_capture", [:]), "private synthetic capture")
        XCTAssertEqual(captures, 1); XCTAssertEqual(wakes, 0)
        for state in ["PAUSED", "DISCONNECTED", "IN_USE", "NONE", "", "UNKNOWN"] {
            tools.phoneGateStatus = { (true, state) }
            XCTAssertTrue(tools.execute("inbody_capture", [:]).hasPrefix("실행 안 함:"), state)
        }
        tools.phoneGateStatus = { (false, "CONNECTED") }
        tools.permissionNeed = { .settings }
        XCTAssertTrue(tools.execute("inbody_capture", [:]).contains("권한"))
        XCTAssertEqual(try tools.db.state("setup:needed"), "1")
        tools.phoneGateStatus = { (true, "CONNECTED") }
        tools.currentText = "오늘 뭐 먹었지?"
        XCTAssertTrue(tools.execute("inbody_capture", [:]).hasPrefix("실행 안 함:"))
        XCTAssertEqual(captures, 1); XCTAssertEqual(wakes, 0)

        // Other tools keep the existing wake/reconnect path.
        Tools.fake = (screen: { [] }, hand: { _ in XCTFail("No phone input expected") })
        tools.currentText = "폰에서 읽어줘"
        tools.phoneGateStatus = { (true, "PAUSED") }
        XCTAssertEqual(tools.execute("phone_screen", [:]), "")
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(captures, 1)
    }

    func testHabitRequiresUserReportAndRetractionRevisesOriginalSource() throws {
        var habit: [String: Any] = ["kind": "habit", "activityID": "sunscreen", "occurredAt": "2026-09-06T08:30:00+09:00",
                                   "sourceID": "synthetic-sunscreen-report", "attribution": "reported",
                                   "activityDay": "2026-09-05", "activityTimeZone": "Asia/Seoul"]
        let result = try decoded(HealthTools.record(habit, store: store))
        let id = try XCTUnwrap(result["recordID"] as? String)
        XCTAssertEqual(try store.record(id: id)?.activityStatus, .completed)
        XCTAssertEqual(try decoded(HealthTools.record(habit, store: store))["status"] as? String, "duplicate")
        XCTAssertEqual(try decoded(HealthTools.records(["kind": "habit", "activityID": "sunscreen"], store: store))["totalMatching"] as? Int, 1)
        XCTAssertEqual(try decoded(HealthTools.records(["activityID": "sunscreen", "activityDay": "2026-09-05"], store: store))["totalMatching"] as? Int, 1)
        XCTAssertEqual(try decoded(HealthTools.records(["activityID": "sunscreen", "activityDay": "2026-09-06"], store: store))["totalMatching"] as? Int, 0)
        var estimate = habit; estimate["sourceID"] = "synthetic-estimate"; estimate["attribution"] = "aiEstimate"
        XCTAssertThrowsError(try HealthTools.record(estimate, store: store))
        var noActivity = habit; noActivity.removeValue(forKey: "activityID")
        XCTAssertThrowsError(try HealthTools.record(noActivity, store: store))
        for field in ["activityDay", "activityTimeZone"] {
            var missing = habit; missing.removeValue(forKey: field)
            XCTAssertThrowsError(try HealthTools.record(missing, store: store), field)
        }
        habit["activityStatus"] = "retracted"
        XCTAssertEqual(try decoded(HealthTools.record(habit, store: store))["status"] as? String, "updated")
        XCTAssertEqual(try store.record(id: id)?.activityStatus, .retracted)
        XCTAssertEqual(try store.revisions(recordID: id).count, 1)
        XCTAssertEqual(try decoded(HealthTools.record(habit, store: store))["status"] as? String, "duplicate")
        var missing = habit; missing["sourceID"] = "nonexistent-completion"
        XCTAssertThrowsError(try HealthTools.record(missing, store: store))
        XCTAssertEqual(try store.allRecords().count, 1)
    }
}
