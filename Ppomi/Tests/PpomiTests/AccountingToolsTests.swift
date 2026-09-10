import XCTest
@testable import Ppomi

final class AccountingToolsTests: XCTestCase {
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("accounting.sqlite").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-accounting-tools-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    private func fixture() throws -> AccountingArchive {
        var value = try LifeJSON.decoder().decode(AccountingArchive.self, from: AccountingCatalog.templateData())
        value.entries.removeAll { $0.layer == .adjustment }
        return value
    }
    private func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let response = try AccountingTools.execute(name, args, path: path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }
    private func importFixture() throws {
        let data = try LifeJSON.encoder().encode(fixture())
        let args = ["archive": String(decoding: data, as: UTF8.self)]
        XCTAssertEqual(try call("accounting_import", args)["status"] as? String, "inserted")
        XCTAssertEqual(try call("accounting_import", args)["status"] as? String, "duplicate")
    }
    private func assessment(id: String = "test-estimate", source: String = "example-fee", target: String = "money-skill") -> [String: Any] {
        ["id": id, "sourceEntryID": source, "postingIndex": 0, "targetAccountID": target,
         "basisPoints": 6000, "rationale": "가상 평가 근거", "confidenceBasisPoints": 4500, "model": "test-model"]
    }

    func testTemplateIsValidAndDoesNotInsertSyntheticRecords() throws {
        _ = try call("accounting_template")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let archive = try LifeJSON.decoder().decode(AccountingArchive.self, from: AccountingCatalog.templateData())
        try AccountingEngine.validate(archive)
        XCTAssertEqual(Set(archive.books.map { $0.unit.id }), ["KRW", "min"])
    }

    func testSameAPIReclassifiesMoneyAndTimeWithoutChangingSources() throws {
        try importFixture()
        let before = try AccountingStore(path: path).snapshot().entries
        XCTAssertEqual(try call("accounting_reclassify", assessment())["status"] as? String, "inserted")
        XCTAssertEqual(try call("accounting_reclassify", assessment())["status"] as? String, "duplicate")
        _ = try call("accounting_reclassify", assessment(id: "time-estimate", source: "example-duration", target: "time-learning-asset"))
        let archive = try AccountingStore(path: path).snapshot()
        XCTAssertEqual(archive.entries.filter { $0.layer == .recorded }, before)
        let money = try AccountingEngine.balances(in: archive, bookID: "example-money", includeAdjustments: true)
        XCTAssertEqual(money["money-learning"], 40000)
        XCTAssertEqual(money["money-skill"], 60000)
        let time = try AccountingEngine.balances(in: archive, bookID: "example-time", includeAdjustments: true)
        XCTAssertEqual(time["time-learning-expense"], 48)
        XCTAssertEqual(time["time-learning-asset"], 72)
    }

    func testRevisionAndWithdrawalKeepBaselineAndHistory() throws {
        try importFixture()
        _ = try call("accounting_reclassify", assessment())
        var revision = assessment(id: "test-revision")
        revision["basisPoints"] = 3000
        revision["replacesEntryID"] = "test-estimate"
        _ = try call("accounting_reclassify", revision)
        var withdrawal = assessment(id: "test-withdrawal")
        withdrawal["basisPoints"] = 0
        withdrawal["replacesEntryID"] = "test-revision"
        _ = try call("accounting_reclassify", withdrawal)
        let archive = try AccountingStore(path: path).snapshot()
        XCTAssertEqual(archive.entries.filter { $0.layer == .adjustment }.count, 3)
        let baseline = try AccountingEngine.balances(in: archive, bookID: "example-money", includeAdjustments: false)
        XCTAssertEqual(try AccountingEngine.balances(in: archive, bookID: "example-money", includeAdjustments: true), baseline)
        let active = try call("accounting_records", ["bookID": "example-money"])
        let all = try call("accounting_records", ["bookID": "example-money", "history": true])
        XCTAssertEqual((all["totalMatching"] as? Int)! - (active["totalMatching"] as? Int)!, 2)
    }

    func testInvalidAgentInputCannotPartiallyChangeTheJournal() throws {
        try importFixture()
        let before = try AccountingStore(path: path).snapshot()
        for (key, value): (String, Any) in [("basisPoints", true), ("basisPoints", 10001), ("postingIndex", -1),
                                          ("confidenceBasisPoints", 50.5), ("recordedAt", "2026-09-08"),
                                          ("targetAccountID", "time-learning-asset")] {
            var args = assessment(); args[key] = value
            XCTAssertThrowsError(try call("accounting_reclassify", args), key)
        }
        var changed = try fixture()
        changed.accounts.append(.init(id: "should-rollback", bookID: "example-money", name: "추가 계정", kind: .expense))
        changed.entries[0].memo = "같은 ID 원본 덮어쓰기 시도"
        let raw = String(decoding: try LifeJSON.encoder().encode(changed), as: UTF8.self)
        XCTAssertThrowsError(try call("accounting_import", ["archive": raw]))
        XCTAssertEqual(try AccountingStore(path: path).snapshot(), before)
    }

    func testQueryBoundsAndMCPVoiceShareGenericTools() throws {
        try importFixture()
        let query = try call("accounting_records", ["bookID": "example-money", "limit": 1])
        XCTAssertEqual(query["truncated"] as? Bool, true)
        let data = try XCTUnwrap(query["data"] as? [String: Any])
        XCTAssertEqual((data["books"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(query["nextOffset"] as? Int, 1)
        let older = try call("accounting_records", ["entryID": "example-opening"])
        let olderData = try XCTUnwrap(older["data"] as? [String: Any])
        XCTAssertEqual((olderData["entries"] as? [[String: Any]])?.first?["id"] as? String, "example-opening")
        let activity = try call("accounting_records", ["eventID": "example-learning-event"])
        XCTAssertEqual(activity["totalMatching"] as? Int, 2)
        let page = try call("accounting_records", ["bookID": "example-money", "offset": 1, "limit": 1])
        XCTAssertEqual(page["truncated"] as? Bool, false)
        XCTAssertThrowsError(try call("accounting_records", ["limit": true]))
        XCTAssertThrowsError(try call("accounting_records", ["history": "false"]))
        XCTAssertThrowsError(try call("accounting_records", ["bookID": "missing"]))
        for name in AccountingTools.names {
            XCTAssertTrue(Tools.specs.contains { $0.name == name })
            XCTAssertTrue(MCPServer.tools.contains { $0.name == name })
        }
        let tools = try Tools(db: DB(path: folder.appendingPathComponent("ledger.sqlite").path, writable: true))
        tools.accountingStorePath = path
        XCTAssertFalse(tools.execute("accounting_records", [:]).hasPrefix("오류"))
        XCTAssertNil(tools.approval)
    }

    func testOverlappingAssessmentRetriesUseOneEntryAndPreserveConflicts() throws {
        try importFixture()
        let args = assessment(), storePath = path
        let done = expectation(description: "Concurrent retries finish")
        done.expectedFulfillmentCount = 6
        for _ in 0..<6 {
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do { _ = try AccountingTools.execute("accounting_reclassify", args, path: storePath) }
                catch { XCTFail("Same logical assessment retry failed: \(error)") }
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try AccountingStore(path: path).snapshot().entries.filter { $0.layer == .adjustment }.count, 1)
        var conflict = args; conflict["basisPoints"] = 3000
        XCTAssertThrowsError(try call("accounting_reclassify", conflict))
    }
}
