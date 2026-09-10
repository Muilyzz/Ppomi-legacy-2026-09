import Foundation
import XCTest
@testable import Ppomi

final class AccountingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_783_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiAccounting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(bookID: String = "book", dimension: AccountingUnit.Dimension = .currency,
                         amount: Int = 100_000) -> AccountingArchive {
        let unit = AccountingUnit(id: "unit-" + bookID, name: "사용자 정의 단위", symbol: "u", dimension: dimension, scale: 0)
        let book = AccountingBook(id: bookID, name: "사용자 정의 장부", ownerID: "owner", kind: dimension == .currency ? .financial : .resource, unit: unit)
        let accounts: [AccountingAccount] = [
            .init(id: bookID + "/cost", bookID: bookID, name: "사용자 정의 소비", kind: .expense),
            .init(id: bookID + "/fund", bookID: bookID, name: "사용자 정의 원천", kind: .asset),
            .init(id: bookID + "/retained", bookID: bookID, name: "사용자 정의 잔존분", kind: .asset)
        ]
        let entry = AccountingEntry(id: bookID + "/entry", eventID: "event", bookID: bookID,
            occurredAt: date, recordedAt: date, memo: "알려지지 않은 새 활동도 계정 데이터로 표현", source: "수동 입력",
            sourceRecordID: bookID + "/source", postings: [
                .init(accountID: accounts[0].id, side: .debit, amount: amount),
                .init(accountID: accounts[1].id, side: .credit, amount: amount)
            ])
        return AccountingArchive(books: [book], accounts: accounts, entries: [entry])
    }

    private func estimate(_ source: AccountingEntry, id: String = "estimate", ratio: Int = 6_000,
                          replacing: String? = nil, postingIndex: Int = 0) throws -> AccountingEntry {
        try AccountingEngine.reclassify(source: source, postingIndex: postingIndex,
            targetAccountID: source.bookID + "/retained", basisPoints: ratio, id: id,
            assessment: .init(sourceEntryID: source.id, rationale: "새로운 증빙으로 남은 효용을 평가", confidenceBasisPoints: 7_000,
                              model: "test-model", replacesEntryID: replacing), recordedAt: date.addingTimeInterval(10))
    }

    func testMoneyTimeAndCustomQuantityUseIdenticalEngineAndKeepOriginalFacts() throws {
        for dimension in [AccountingUnit.Dimension.currency, .time, .quantity] {
            var archive = fixture(dimension: dimension)
            let source = archive.entries[0]
            let adjustment = try estimate(source)
            archive.entries.append(adjustment)
            try AccountingEngine.validate(archive)
            XCTAssertEqual(archive.entries[0], source)
            XCTAssertEqual(try AccountingEngine.entries(in: archive, bookID: "book", includeAdjustments: false), [source])
            let balances = try AccountingEngine.balances(in: archive, bookID: "book", includeAdjustments: true)
            XCTAssertEqual(balances["book/cost"], 40_000)
            XCTAssertEqual(balances["book/retained"], 60_000)
            XCTAssertEqual(balances["book/fund"], -100_000)
            XCTAssertEqual(try AccountingEngine.balances(in: archive, bookID: "book", includeAdjustments: false)["book/cost"], 100_000)
        }
    }

    func testMultiPostingJournalAndNetComparisonRemainBalanced() throws {
        var archive = fixture()
        archive.entries[0].postings = [
            .init(accountID: "book/cost", side: .debit, amount: 40_000),
            .init(accountID: "book/retained", side: .debit, amount: 60_000),
            .init(accountID: "book/fund", side: .credit, amount: 100_000)
        ]
        XCTAssertNoThrow(try AccountingEngine.validate(archive))
        let normal = fixture()
        let adjustment = try estimate(normal.entries[0])
        let net = try AccountingEngine.netPostings([normal.entries[0], adjustment])
        XCTAssertEqual(Set(net.map(\.accountID)), ["book/cost", "book/retained", "book/fund"])
        XCTAssertEqual(net.first { $0.accountID == "book/cost" }?.amount, 40_000)
        XCTAssertEqual(net.first { $0.accountID == "book/retained" }?.amount, 60_000)
        XCTAssertEqual(net.first { $0.accountID == "book/fund" }?.side, .credit)
        XCTAssertEqual(net.filter { $0.side == .debit }.map(\.amount).reduce(0, +), 100_000)
    }

    func testBalancesNeverMixBooksOrUnits() throws {
        let a = fixture(bookID: "money"), b = fixture(bookID: "time", dimension: .time, amount: 120)
        var joined = AccountingArchive(books: a.books + b.books, accounts: a.accounts + b.accounts, entries: a.entries + b.entries)
        try AccountingEngine.validate(joined)
        XCTAssertEqual(try AccountingEngine.balances(in: joined, bookID: "time", includeAdjustments: true)["time/cost"], 120)
        XCTAssertThrowsError(try AccountingEngine.netPostings(joined.entries))
        joined.entries[0].postings[0].accountID = "time/cost"
        XCTAssertThrowsError(try AccountingEngine.validate(joined))
        var invalidFinancial = b; invalidFinancial.books[0].kind = .financial
        XCTAssertThrowsError(try AccountingEngine.validate(invalidFinancial))
        var inconsistent = AccountingArchive(books: a.books + b.books)
        inconsistent.books[1].unit.id = inconsistent.books[0].unit.id
        XCTAssertThrowsError(try AccountingEngine.validate(inconsistent))
    }

    func testMissingReferencesDuplicatesAndParentCyclesAreRejected() throws {
        var archive = fixture(); archive.entries[0].postings[0].accountID = "absent"
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(); archive.accounts[0].bookID = "absent"
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(); archive.accounts[0].parentID = "book/fund"
        XCTAssertThrowsError(try AccountingEngine.validate(archive), "Parents must have the same account class")
        archive = fixture(); archive.accounts[1].parentID = "book/retained"; archive.accounts[2].parentID = "book/fund"
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(); archive.accounts.append(archive.accounts[0])
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(); archive.books[0].ownerID = " "
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
    }

    func testZeroNegativeUnbalancedAndOverflowingAmountsAreRejected() throws {
        for invalid in [0, -1] {
            XCTAssertThrowsError(try AccountingEngine.validate(fixture(amount: invalid)))
        }
        var archive = fixture(); archive.entries[0].postings[0].amount += 1
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(amount: Int.max)
        archive.entries[0].postings += [
            .init(accountID: "book/cost", side: .debit, amount: 1),
            .init(accountID: "book/fund", side: .credit, amount: 1)
        ]
        XCTAssertThrowsError(try AccountingEngine.validate(archive), "Balanced mathematical totals still must fit storage")
        archive = fixture(amount: Int.max)
        var second = archive.entries[0]; second.id = "second"; second.sourceRecordID = "second"
        archive.entries.append(second)
        XCTAssertNoThrow(try AccountingEngine.validate(archive))
        XCTAssertThrowsError(try AccountingEngine.balances(in: archive, bookID: "book", includeAdjustments: false))
        XCTAssertThrowsError(try AccountingEngine.netPostings(archive.entries))
    }

    func testReclassificationRoundsPreciselyAndSupportsCreditSideWithoutOverflow() throws {
        let source = fixture(amount: 1003).entries[0]
        XCTAssertEqual(try estimate(source, ratio: 5_000).postings.map(\.amount), [502, 502])
        let credit = try estimate(source, ratio: 5_000, postingIndex: 1)
        XCTAssertEqual(credit.postings.map(\.side), [.credit, .debit])
        XCTAssertEqual(credit.postings.last?.accountID, "book/fund")
        XCTAssertEqual(try estimate(fixture(amount: Int.max).entries[0], ratio: 10_000).postings.first?.amount, Int.max)
        XCTAssertThrowsError(try estimate(source, ratio: 10_001))
        XCTAssertThrowsError(try estimate(source, ratio: -1))
        XCTAssertThrowsError(try estimate(source, postingIndex: 2))
        XCTAssertThrowsError(try estimate(fixture(amount: 1).entries[0], ratio: 1))
    }

    func testReplacementSelectsOneEffectiveAssessmentAndCanWithdrawToZero() throws {
        var archive = fixture()
        let source = archive.entries[0]
        let old = try estimate(source, id: "old")
        let revised = try estimate(source, id: "new", ratio: 3_000, replacing: "old")
        archive.entries += [old, revised]
        XCTAssertEqual(Set(try AccountingEngine.entries(in: archive, bookID: "book", includeAdjustments: true).map(\.id)), [source.id, "new"])
        XCTAssertEqual(try AccountingEngine.balances(in: archive, bookID: "book", includeAdjustments: true)["book/retained"], 30_000)
        let withdrawn = try estimate(source, id: "withdrawn", ratio: 0, replacing: "new")
        XCTAssertTrue(withdrawn.postings.isEmpty)
        archive.entries.append(withdrawn)
        XCTAssertEqual(try AccountingEngine.balances(in: archive, bookID: "book", includeAdjustments: true)["book/retained"], 0)
        XCTAssertEqual(try AccountingEngine.netPostings([source, withdrawn]), source.postings.sorted { $0.accountID < $1.accountID })
        XCTAssertEqual(archive.entries.count, 4, "The source and every previous assessment remain auditable")
        XCTAssertThrowsError(try estimate(source, ratio: 0), "A zero initial assessment has nothing to reclassify")
    }

    func testConcurrentAssessmentForksDuplicateRootsAndCyclesAreRejected() throws {
        var archive = fixture(); let source = archive.entries[0]
        let old = try estimate(source, id: "old")
        archive.entries += [old, try estimate(source, id: "a", replacing: "old"), try estimate(source, id: "b", replacing: "old")]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive.entries = [source, old, try estimate(source, id: "another-root")]
        XCTAssertThrowsError(try AccountingEngine.validate(archive), "Separate root assessments cannot silently allocate 120%")
        var a = try estimate(source, id: "a", replacing: "b")
        let b = try estimate(source, id: "b", replacing: "a")
        archive.entries = [source, a, b]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        a.assessment?.replacesEntryID = "missing"
        archive.entries = [source, a]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
    }

    func testAssessmentsRequireSourceIdentityMatchingBookEventAndRationale() throws {
        var archive = fixture(); let source = archive.entries[0]
        var adjustment = try estimate(source)
        adjustment.eventID = "other-event"; archive.entries.append(adjustment)
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        adjustment = try estimate(source); adjustment.assessment?.sourceEntryID = adjustment.id
        archive.entries = [source, adjustment]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        adjustment = try estimate(source); adjustment.assessment?.rationale = " "
        archive.entries = [source, adjustment]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        var annotatedFact = source; annotatedFact.assessment = try estimate(source).assessment
        archive.entries = [annotatedFact]
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        archive = fixture(); var duplicate = source; duplicate.id = "another-ID"
        archive.entries.append(duplicate)
        XCTAssertThrowsError(try AccountingEngine.validate(archive), "Source identities survive caller-generated new IDs")
    }

    func testStoreRoundtripRetryAndPrivatePermissions() throws {
        let path = directory.appendingPathComponent("private/accounting.sqlite").path
        let store = try AccountingStore(path: path)
        var archive = fixture()
        archive.entries[0].recordedAt = date.addingTimeInterval(0.123456)
        XCTAssertEqual(try store.importArchive(archive), 5)
        XCTAssertEqual(try store.importArchive(archive), 0)
        let snapshot = try store.snapshot()
        XCTAssertEqual(try AccountingStore(path: path).snapshot(), snapshot)
        XCTAssertEqual(try LifeJSON.decoder().decode(AccountingArchive.self, from: LifeJSON.encoder().encode(snapshot)), snapshot)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let parentPermissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("private").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(parentPermissions?.intValue, 0o700)
        XCTAssertEqual(try LifeJSON.decoder().decode(AccountingArchive.self, from: Data("{}".utf8)), AccountingArchive())
    }

    func testAtomicImportFailurePreservesEveryExistingFactAndAllowsIncrementalReferences() throws {
        let store = try AccountingStore(path: directory.appendingPathComponent("accounting.sqlite").path)
        let archive = fixture(); try store.importArchive(archive)
        let before = try store.snapshot()
        let other = fixture(bookID: "other", dimension: .time)
        var conflict = archive.entries[0]; conflict.memo = "conflicting replacement"
        XCTAssertThrowsError(try store.importArchive(.init(books: other.books, accounts: other.accounts, entries: other.entries + [conflict])))
        XCTAssertEqual(try store.snapshot(), before)
        var invalid = other; invalid.entries[0].postings[0].amount += 1
        XCTAssertThrowsError(try store.importArchive(invalid))
        XCTAssertEqual(try store.snapshot(), before)
        let adjustment = try estimate(archive.entries[0])
        XCTAssertEqual(try store.importArchive(.init(entries: [adjustment])), 1, "Incremental imports reference already stored accounts and facts")
        XCTAssertEqual(try store.importArchive(.init(entries: [adjustment])), 0)
        XCTAssertEqual(try store.snapshot().entries.count, 2)
    }

    func testInvalidDatesCannotReachPersistenceOrAcquireDefaultValues() throws {
        let store = try AccountingStore(path: directory.appendingPathComponent("accounting.sqlite").path)
        var archive = fixture(); archive.entries[0].occurredAt = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try AccountingEngine.validate(archive))
        XCTAssertThrowsError(try store.importArchive(archive))
        XCTAssertEqual(try store.snapshot(), AccountingArchive())
        let encoded = String(decoding: try LifeJSON.encoder().encode(fixture()), as: UTF8.self)
        let invalid = encoded.replacingOccurrences(of: LifeJSON.timestamp(date), with: "2026-07-02T12:00:00")
        XCTAssertThrowsError(try LifeJSON.decoder().decode(AccountingArchive.self, from: Data(invalid.utf8)))
    }

    func testConcurrentWritersKeepAllEntriesAndRetriedSourceCannotDuplicate() throws {
        let path = directory.appendingPathComponent("accounting.sqlite").path
        let store = try AccountingStore(path: path)
        let initial = fixture(); try store.importArchive(initial)
        let count = 8
        let complete = expectation(description: "Every writer committed")
        complete.expectedFulfillmentCount = count
        for index in 0..<count {
            DispatchQueue.global().async {
                defer { complete.fulfill() }
                do {
                    let writer = try AccountingStore(path: path)
                    var entry = initial.entries[0]
                    entry.id = "concurrent-\(index)"; entry.eventID = entry.id; entry.sourceRecordID = entry.id
                    XCTAssertEqual(try writer.importArchive(.init(entries: [entry])), 1)
                    XCTAssertEqual(try writer.importArchive(.init(entries: [entry])), 0)
                } catch { XCTFail("Concurrent import failed: \(error)") }
            }
        }
        wait(for: [complete], timeout: 10)
        XCTAssertEqual(try store.snapshot().entries.count, count + 1)
        var duplicate = initial.entries[0]; duplicate.id = "new-id-same-source"
        XCTAssertThrowsError(try store.importArchive(.init(entries: [duplicate])))
        XCTAssertEqual(try store.snapshot().entries.count, count + 1)
    }
}
