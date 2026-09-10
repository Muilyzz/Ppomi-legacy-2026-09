import Foundation
import XCTest
@testable import Ppomi

final class AccountingScopeTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_783_000_000)
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("accounting.sqlite").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-accounting-scope-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func fixture(_ bookID: String, ownerID: String = "owner-a", scope: RecordScope? = nil) -> AccountingArchive {
        var book = AccountingBook(id: bookID, name: "같은 표시 이름", ownerID: ownerID, kind: .financial,
            unit: .init(id: "KRW", name: "원", symbol: "원", dimension: .currency, scale: 0))
        book.scope = scope
        let accounts: [AccountingAccount] = [
            .init(id: bookID + "/cost", bookID: bookID, name: "비용", kind: .expense),
            .init(id: bookID + "/fund", bookID: bookID, name: "예금", kind: .asset),
            .init(id: bookID + "/retained", bookID: bookID, name: "관리용 자산", kind: .asset)
        ]
        let entry = AccountingEntry(id: bookID + "/entry", eventID: "shared-event", bookID: bookID,
            occurredAt: date, recordedAt: date, memo: "가상 범위 검증 자료", source: "scope-test",
            sourceRecordID: bookID + "/source", postings: [
                .init(accountID: bookID + "/cost", side: .debit, amount: 100_000),
                .init(accountID: bookID + "/fund", side: .credit, amount: 100_000)
            ])
        return .init(books: [book], accounts: accounts, entries: [entry])
    }

    private func scopedFixture() -> AccountingArchive {
        let parts = [
            fixture("personal", scope: .init(kind: .personal, ownerID: "owner-a")),
            fixture("business-a", scope: .init(kind: .business, ownerID: "owner-a", businessID: "business-ref-a")),
            fixture("business-b", scope: .init(kind: .business, ownerID: "owner-a", businessID: "business-ref-b")),
            fixture("legacy"),
            fixture("other-owner", ownerID: "owner-b", scope: .init(kind: .personal, ownerID: "owner-b"))
        ]
        return .init(books: parts.flatMap(\.books), accounts: parts.flatMap(\.accounts), entries: parts.flatMap(\.entries))
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = try AccountingTools.execute(name, arguments, path: path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func query(_ arguments: [String: Any]) throws -> AccountingArchive {
        let result = try call("accounting_records", arguments)
        let data = try XCTUnwrap(result["data"] as? [String: Any])
        let archive = try LifeJSON.decoder().decode(AccountingArchive.self, from: JSONSerialization.data(withJSONObject: data))
        let scopeMap = try XCTUnwrap(result["scopeByBookID"] as? [String: Any])
        XCTAssertEqual(Set(scopeMap.keys), Set(archive.books.map(\.id)))
        for book in archive.books {
            let scope = try XCTUnwrap(scopeMap[book.id] as? [String: Any])
            let decoded = try LifeJSON.decoder().decode(RecordScope.self, from: JSONSerialization.data(withJSONObject: scope))
            XCTAssertEqual(decoded, book.effectiveScope, "The response exposes effective scope without rewriting stored books")
        }
        return archive
    }

    private func assertBooks(_ archive: AccountingArchive, _ expected: Set<String>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(archive.books.map(\.id)), expected, file: file, line: line)
        XCTAssertEqual(Set(archive.accounts.map(\.bookID)), expected, file: file, line: line)
        XCTAssertTrue(Set(archive.entries.map(\.bookID)).isSubset(of: expected), file: file, line: line)
    }

    private func assessment(_ source: AccountingEntry, id: String, replacing: String? = nil) throws -> AccountingEntry {
        try AccountingEngine.reclassify(source: source, postingIndex: 0,
            targetAccountID: source.bookID + "/retained", basisPoints: replacing == nil ? 6_000 : 3_000,
            id: id, assessment: .init(sourceEntryID: source.id, rationale: "가상 범위 검증 평가",
                confidenceBasisPoints: 5_000, model: "scope-test", replacesEntryID: replacing), recordedAt: date)
    }

    func testLegacyJSONStaysUnclassifiedAndRetriesPreserveSourceAndAssessmentHistory() throws {
        let raw = """
        {"formatVersion":1,"books":[{"id":"legacy","name":"기존 장부","ownerID":"owner-a","kind":"financial",
          "unit":{"id":"KRW","name":"원","symbol":"원","dimension":"currency","scale":0}}],
         "accounts":[{"id":"legacy/cost","bookID":"legacy","name":"비용","kind":"expense"},
          {"id":"legacy/fund","bookID":"legacy","name":"예금","kind":"asset"},
          {"id":"legacy/retained","bookID":"legacy","name":"관리용 자산","kind":"asset"}],
         "entries":[{"id":"legacy/entry","eventID":"shared-event","bookID":"legacy",
          "occurredAt":"2026-07-02T12:00:00Z","recordedAt":"2026-07-02T12:00:00Z","memo":"기존 원본",
          "source":"scope-test","sourceRecordID":"legacy/source","layer":"recorded",
          "postings":[{"accountID":"legacy/cost","side":"debit","amount":100000},
           {"accountID":"legacy/fund","side":"credit","amount":100000}]}]}
        """
        let legacy = try LifeJSON.decoder().decode(AccountingArchive.self, from: Data(raw.utf8))
        XCTAssertNil(legacy.books[0].scope)
        XCTAssertEqual(legacy.books[0].effectiveScope, .init(kind: .unclassified, ownerID: "owner-a"))
        let store = try AccountingStore(path: path)
        XCTAssertEqual(try store.importArchive(legacy), 5)
        XCTAssertEqual(try store.importArchive(legacy), 0)
        let original = legacy.entries[0]
        let old = try assessment(original, id: "legacy/old")
        let new = try assessment(original, id: "legacy/new", replacing: old.id)
        XCTAssertEqual(try store.importArchive(.init(entries: [old, new])), 2)
        let before = try store.snapshot()
        XCTAssertEqual(try store.importArchive(before), 0)
        XCTAssertEqual(try store.importArchive(legacy), 0)
        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(before.entries.first { $0.id == original.id }, original)
        XCTAssertEqual(Set(before.entries.map(\.id)), [original.id, old.id, new.id])
        XCTAssertNil(before.books[0].scope, "Reading legacy data must not write an inferred personal classification")
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: LifeJSON.encoder().encode(before)) as? [String: Any])
        XCTAssertNil((exported["books"] as? [[String: Any]])?.first?["scope"])

        var changed = legacy.books[0]
        changed.scope = .init(kind: .personal, ownerID: "owner-a")
        XCTAssertThrowsError(try store.importArchive(.init(books: [changed])))
        XCTAssertEqual(try store.snapshot(), before, "Adding scope cannot silently rewrite an existing book ID")
        assertBooks(try query(["scopeKind": "unclassified", "ownerID": "owner-a"]), ["legacy"])
        assertBooks(try query(["scopeKind": "personal"]), [])
    }

    func testExplicitScopeOwnerMustMatchBookOwnerAndInvalidScopeCannotCommit() throws {
        let store = try AccountingStore(path: path)
        let valid = fixture("personal", scope: .init(kind: .personal, ownerID: "owner-a"))
        try store.importArchive(valid)
        let before = try store.snapshot()
        let invalidScopes: [RecordScope] = [
            .init(kind: .personal, ownerID: "owner-b"),
            .init(kind: .business, ownerID: "owner-b", businessID: "business-ref-b"),
            .init(kind: .business, ownerID: "owner-a"),
            .init(kind: .personal, ownerID: "owner-a", businessID: "business-ref-a"),
            .init(kind: .unclassified, ownerID: "owner-a", businessID: "business-ref-a")
        ]
        for scope in invalidScopes {
            let invalid = fixture("invalid", scope: scope)
            XCTAssertThrowsError(try AccountingEngine.validate(invalid))
            XCTAssertThrowsError(try store.importArchive(invalid))
            XCTAssertEqual(try store.snapshot(), before)
        }
    }

    func testPreviouslyStoredLegacyOwnerReferencesKeepTheirOriginalValidationAndPayloads() throws {
        let parts = [fixture("legacy-whitespace", ownerID: " owner-a "),
                     fixture("legacy-control", ownerID: "owner-\tline\nreference")]
        let legacy = AccountingArchive(books: parts.flatMap(\.books), accounts: parts.flatMap(\.accounts),
                                       entries: parts.flatMap(\.entries))
        let store = try AccountingStore(path: path)
        // Write old-style payloads directly, as if this DB predated RecordScope. The current import
        // validator must not decide whether this legacy fixture is allowed to exist in the first place.
        do {
            let database = try DB(path: path, writable: true)
            func insert<T: Encodable>(_ values: [T], table: String, id: KeyPath<T, String>) throws {
                for value in values {
                    let payload = String(decoding: try LifeJSON.encoder().encode(value), as: UTF8.self)
                    try database.exec("INSERT INTO \(table)(id,payload) VALUES(?,?)", [value[keyPath: id], payload])
                }
            }
            try insert(legacy.books, table: "accounting_books", id: \.id)
            try insert(legacy.accounts, table: "accounting_accounts", id: \.id)
            try insert(legacy.entries, table: "accounting_entries", id: \.id)
        }

        let before = try store.snapshot()
        XCTAssertEqual(Set(before.books.map(\.ownerID)), [" owner-a ", "owner-\tline\nreference"])
        for original in legacy.books {
            let book = try XCTUnwrap(before.books.first { $0.id == original.id })
            XCTAssertEqual(book, original)
            XCTAssertNil(book.scope)
            XCTAssertEqual(book.effectiveScope, .init(kind: .unclassified, ownerID: original.ownerID))
        }
        for source in legacy.entries {
            XCTAssertEqual(before.entries.first { $0.id == source.id }, source)
        }
        XCTAssertEqual(try store.importArchive(before), 0)
        XCTAssertEqual(try store.importArchive(legacy), 0)
        XCTAssertEqual(try store.snapshot(), before)
        let response = try query(["scopeKind": "unclassified"])
        XCTAssertEqual(Set(response.books.map(\.ownerID)), Set(before.books.map(\.ownerID)))

        for index in before.books.indices {
            var explicit = before
            explicit.books[index].scope = .init(kind: .personal, ownerID: explicit.books[index].ownerID)
            XCTAssertThrowsError(try AccountingEngine.validate(explicit), "New explicit scopes must still use the stricter reference format")
        }
    }

    func testBusinessReferenceCannotBeReassignedToAnotherOwner() throws {
        let store = try AccountingStore(path: path)
        let first = fixture("business-a", scope: .init(kind: .business, ownerID: "owner-a", businessID: "business-ref-a"))
        let sameOwner = fixture("business-a-second-book", scope: .init(kind: .business, ownerID: "owner-a", businessID: "business-ref-a"))
        try store.importArchive(first)
        XCTAssertNoThrow(try store.importArchive(sameOwner))
        let before = try store.snapshot()
        let otherOwner = fixture("business-other-owner", ownerID: "owner-b",
            scope: .init(kind: .business, ownerID: "owner-b", businessID: "business-ref-a"))
        XCTAssertNoThrow(try AccountingEngine.validate(otherOwner), "The conflict is with an existing book, not this book's shape")
        XCTAssertThrowsError(try store.importArchive(otherOwner))
        XCTAssertEqual(try store.snapshot(), before)
    }

    func testBusinessesCannotSharePostingsAccountParentsOrAssessmentSources() throws {
        let original = scopedFixture()
        XCTAssertNoThrow(try AccountingEngine.validate(original))
        var crossPosting = original
        let sourceIndex = try XCTUnwrap(crossPosting.entries.firstIndex { $0.bookID == "business-a" })
        crossPosting.entries[sourceIndex].postings[0].accountID = "business-b/cost"
        XCTAssertThrowsError(try AccountingEngine.validate(crossPosting))

        var crossParent = original
        let accountIndex = try XCTUnwrap(crossParent.accounts.firstIndex { $0.id == "business-a/cost" })
        crossParent.accounts[accountIndex].parentID = "business-b/cost"
        XCTAssertThrowsError(try AccountingEngine.validate(crossParent))

        var crossAssessment = original
        let source = try XCTUnwrap(original.entries.first { $0.bookID == "business-a" })
        var adjustment = try assessment(source, id: "business-a/assessment")
        adjustment.assessment?.sourceEntryID = "business-b/entry"
        crossAssessment.entries.append(adjustment)
        XCTAssertThrowsError(try AccountingEngine.validate(crossAssessment))
    }

    func testReclassificationIntoAnotherBusinessRollsBack() throws {
        let store = try AccountingStore(path: path)
        try store.importArchive(scopedFixture())
        let before = try store.snapshot()
        XCTAssertThrowsError(try call("accounting_reclassify", [
            "id": "cross-business-assessment", "sourceEntryID": "business-a/entry", "postingIndex": 0,
            "targetAccountID": "business-b/retained", "basisPoints": 6_000,
            "rationale": "사업 경계를 넘는 잘못된 가상 평가", "confidenceBasisPoints": 5_000
        ]))
        XCTAssertEqual(try store.snapshot(), before)
    }

    func testOwnerKindAndBusinessFiltersApplyToBooksAccountsAndEntriesTogether() throws {
        try AccountingStore(path: path).importArchive(scopedFixture())
        let businessA = try query(["businessID": "business-ref-a"])
        assertBooks(businessA, ["business-a"])
        XCTAssertEqual(businessA.entries.map(\.id), ["business-a/entry"])
        assertBooks(try query(["scopeKind": "business", "ownerID": "owner-a"]), ["business-a", "business-b"])
        assertBooks(try query(["scopeKind": "personal", "ownerID": "owner-a"]), ["personal"])
        assertBooks(try query(["ownerID": "owner-a"]), ["personal", "business-a", "business-b", "legacy"])
        assertBooks(try query(["ownerID": "owner-b"]), ["other-owner"])
        assertBooks(try query(["scopeKind": "unclassified"]), ["legacy"])
        assertBooks(try query(["businessID": "missing-business"]), [])
        assertBooks(try query(["ownerID": "owner-b", "businessID": "business-ref-a"]), [])
    }

    func testSharedEventAndExactEntryQueriesStayWithinScope() throws {
        try AccountingStore(path: path).importArchive(scopedFixture())
        let event = try query(["eventID": "shared-event", "businessID": "business-ref-a"])
        assertBooks(event, ["business-a"])
        XCTAssertEqual(event.entries.map(\.id), ["business-a/entry"])
        let hidden = try query(["entryID": "business-b/entry", "businessID": "business-ref-a"])
        assertBooks(hidden, ["business-a"])
        XCTAssertTrue(hidden.entries.isEmpty)
        let visible = try query(["entryID": "business-a/entry", "scopeKind": "business", "ownerID": "owner-a", "businessID": "business-ref-a"])
        XCTAssertEqual(visible.entries.map(\.id), ["business-a/entry"])
        XCTAssertTrue(try query(["entryID": "business-a/entry", "scopeKind": "personal"]).entries.isEmpty)
    }

    func testHistoryAndOldAssessmentIDQueriesCannotEscapeBusinessScope() throws {
        var archive = scopedFixture()
        for bookID in ["business-a", "business-b"] {
            let source = try XCTUnwrap(archive.entries.first { $0.bookID == bookID })
            let old = try assessment(source, id: bookID + "/old")
            archive.entries += [old, try assessment(source, id: bookID + "/new", replacing: old.id)]
        }
        try AccountingStore(path: path).importArchive(archive)
        let active = try query(["businessID": "business-ref-a", "eventID": "shared-event"])
        XCTAssertEqual(Set(active.entries.map(\.id)), ["business-a/entry", "business-a/new"])
        let history = try query(["businessID": "business-ref-a", "eventID": "shared-event", "history": true])
        assertBooks(history, ["business-a"])
        XCTAssertEqual(Set(history.entries.map(\.id)), ["business-a/entry", "business-a/old", "business-a/new"])
        let old = try query(["businessID": "business-ref-a", "entryID": "business-a/old"])
        XCTAssertEqual(old.entries.map(\.id), ["business-a/old"])
        let hidden = try query(["businessID": "business-ref-a", "entryID": "business-b/old", "history": true])
        assertBooks(hidden, ["business-a"])
        XCTAssertTrue(hidden.entries.isEmpty)
    }

    func testInvalidScopeQueriesAndConflictingBookSelectionsAreExplicitErrors() throws {
        try AccountingStore(path: path).importArchive(scopedFixture())
        let invalid: [[String: Any]] = [
            ["scopeKind": "unknown"], ["scopeKind": true], ["scopeKind": ""],
            ["ownerID": " "], ["ownerID": 12], ["businessID": ""], ["businessID": true],
            ["scopeKind": "personal", "businessID": "business-ref-a"],
            ["scopeKind": "unclassified", "businessID": "business-ref-a"],
            ["bookID": "business-a", "scopeKind": "personal"],
            ["bookID": "business-a", "ownerID": "owner-b"],
            ["bookID": "business-a", "businessID": "business-ref-b"]
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try call("accounting_records", arguments), "Expected rejection: \(arguments)")
        }
        assertBooks(try query(["bookID": "business-a", "scopeKind": "business", "ownerID": "owner-a", "businessID": "business-ref-a"]), ["business-a"])
    }
}
