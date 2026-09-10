import XCTest
@testable import Ppomi

final class RecordScopeTests: XCTestCase {
    func testSameOwnerHasDistinctPersonalAndMultipleBusinessBoundaries() throws {
        let personal = RecordScope(kind: .personal, ownerID: "person:1")
        let businessA = RecordScope(kind: .business, ownerID: "person:1", businessID: "business:a")
        let businessB = RecordScope(kind: .business, ownerID: "person:1", businessID: "business:b")
        let unclassified = RecordScope(kind: .unclassified, ownerID: "person:1")
        let scopes = [personal, businessA, businessB, unclassified]
        try RecordScope.validateConsistency(scopes)
        XCTAssertEqual(Set(scopes).count, 4)
        XCTAssertEqual(scopes.filter(RecordScopeFilter(kind: .personal).matches), [personal])
        XCTAssertEqual(scopes.filter(RecordScopeFilter(businessID: "business:a").matches), [businessA])
        XCTAssertEqual(scopes.filter(RecordScopeFilter(ownerID: "person:1").matches), scopes)
        XCTAssertEqual(scopes.filter(RecordScopeFilter(kind: .unclassified).matches), [unclassified])
    }

    func testIncompleteOrContradictoryAttributionsAreRejected() {
        for scope in [RecordScope(kind: .personal),
                      RecordScope(kind: .personal, ownerID: "person:1", businessID: "business:a"),
                      RecordScope(kind: .business, ownerID: "person:1"),
                      RecordScope(kind: .business, businessID: "business:a"),
                      RecordScope(kind: .unclassified, businessID: "business:a"),
                      RecordScope(kind: .personal, ownerID: " person:1"),
                      RecordScope(kind: .personal, ownerID: "person:\n1")] {
            XCTAssertThrowsError(try scope.validate())
        }
        XCTAssertNoThrow(try RecordScope(kind: .unclassified).validate())
        XCTAssertNoThrow(try RecordScope(kind: .unclassified, ownerID: "legacy:source").validate())
    }

    func testBusinessCannotSilentlyChangeOwner() {
        let first = RecordScope(kind: .business, ownerID: "person:1", businessID: "business:a")
        let second = RecordScope(kind: .business, ownerID: "person:2", businessID: "business:a")
        XCTAssertThrowsError(try RecordScope.validateConsistency([first, second]))
        XCTAssertNoThrow(try RecordScope.validateConsistency([first, first]))
    }

    func testFilterRejectsImpossibleRequestsAndDoesNotPromoteUnknownData() throws {
        XCTAssertThrowsError(try RecordScopeFilter(kind: .personal, businessID: "business:a").validate())
        XCTAssertThrowsError(try RecordScopeFilter(kind: .unclassified, businessID: "business:a").validate())
        XCTAssertThrowsError(try RecordScopeFilter(ownerID: "").validate())
        XCTAssertNoThrow(try RecordScopeFilter(businessID: "business:a").validate())
        let unknown = RecordScope(kind: .unclassified, ownerID: "person:1")
        XCTAssertFalse(RecordScopeFilter(kind: .personal, ownerID: "person:1").matches(unknown))
        XCTAssertFalse(RecordScopeFilter(businessID: "business:a").matches(unknown))
    }

    func testRoundTripPreservesOnlyExplicitOpaqueReferences() throws {
        let scope = RecordScope(kind: .business, ownerID: "person:1", businessID: "business:a")
        let data = try JSONEncoder().encode(scope)
        XCTAssertEqual(try JSONDecoder().decode(RecordScope.self, from: data), scope)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["kind", "ownerID", "businessID"])
        let unknown = try JSONDecoder().decode(RecordScope.self, from: Data(#"{"kind":"unclassified"}"#.utf8))
        XCTAssertNil(unknown.ownerID)
        XCTAssertNil(unknown.businessID)
    }
}
