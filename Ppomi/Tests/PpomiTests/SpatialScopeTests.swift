import Foundation
import XCTest
@testable import Ppomi

final class SpatialScopeTests: XCTestCase {
    private var directory: URL!
    private let personal = RecordScope(kind: .personal, ownerID: "owner:one")
    private let business = RecordScope(kind: .business, ownerID: "owner:one", businessID: "business:one")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiSpatialScope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func spatial(id: String = "spatial:one", usages: [SpatialUsage] = []) -> SpatialArchive {
        .init(assets: [.init(id: id, entityID: "entity:property", title: "공통 공간", accountIDs: ["old:unverified"],
            ownerships: [.init(ownerID: "owner:one", shareBasisPoints: 10_000, sourceRecordID: "source:ownership", note: "입력한 소유 근거")],
            usages: usages, parts: [.init(id: "part:one", title: "외곽선", footprint: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 10)],
                height: 8, elevation: 0, provenance: .init(kind: .measured, sourceRecordID: "source:shape", note: "도면의 치수"))])])
    }

    private func usage(_ scope: RecordScope, id: String = "usage:one", allocation: Int? = nil,
                       links: [SpatialAccountLink] = []) -> SpatialUsage {
        .init(id: id, scope: scope, allocationBasisPoints: allocation, sourceRecordID: "source:use", note: "입력한 사용 근거", accountLinks: links)
    }

    private func accounting() -> AccountingArchive {
        let unit = AccountingUnit(id: "unit:KRW", name: "원", symbol: "₩", dimension: .currency, scale: 0)
        return .init(books: [
            .init(id: "book:personal", name: "개인", ownerID: "owner:one", kind: .financial, unit: unit, scope: personal),
            .init(id: "book:business", name: "사업", ownerID: "owner:one", kind: .financial, unit: unit, scope: business)
        ], accounts: [
            .init(id: "account:personal-asset", bookID: "book:personal", name: "개인 자산", kind: .asset),
            .init(id: "account:business-asset", bookID: "book:business", name: "사업 자산", kind: .asset),
            .init(id: "account:business-expense", bookID: "book:business", name: "사업 비용", kind: .expense)
        ])
    }

    func testOldJSONRemainsUnclassifiedAndPreservesUnverifiedReferences() throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: SpatialStore.encode(spatial())) as? [String: Any])
        var assets = try XCTUnwrap(raw["assets"] as? [[String: Any]])
        assets[0].removeValue(forKey: "ownerships"); assets[0].removeValue(forKey: "usages"); raw["assets"] = assets
        let oldData = try JSONSerialization.data(withJSONObject: raw)
        let restored = try SpatialStore.decode(oldData)
        let asset = try XCTUnwrap(restored.assets.first)
        XCTAssertTrue(asset.ownerships.isEmpty); XCTAssertTrue(asset.usages.isEmpty)
        XCTAssertEqual(asset.accountIDs, ["old:unverified"])
        XCTAssertTrue(asset.matches(.init(kind: .unclassified)))
        XCTAssertFalse(asset.matches(.init(kind: .personal)))
        XCTAssertFalse(asset.matches(.init(kind: .business)))
        XCTAssertEqual(try SpatialStore.decode(SpatialStore.encode(restored)), restored)
        let file = directory.appendingPathComponent("spatial.json")
        try oldData.write(to: file)
        let store = SpatialStore(path: file.path, accountingSnapshot: { XCTFail("Old references must not open accounting"); return .init() })
        XCTAssertEqual(try store.snapshot(), restored)
        XCTAssertEqual(try store.importArchive(restored), 0)
        XCTAssertEqual(try Data(contentsOf: file), oldData, "Reading/retrying old data must not rewrite it with inferred ownership")
    }

    func testPartialAndUnknownRatiosRemainUnknownAndOwnershipDoesNotDetermineUse() throws {
        var archive = spatial(usages: [usage(personal, id: "personal", allocation: 2_500), usage(business, id: "business")])
        archive.assets[0].ownerships = [
            .init(ownerID: "owner:one", shareBasisPoints: 4_000, sourceRecordID: "source:ownership", note: "확인된 일부 지분"),
            .init(ownerID: "owner:two", shareBasisPoints: nil, sourceRecordID: "source:ownership:two", note: "비율 미입력")
        ]
        XCTAssertNoThrow(try SpatialGeometry.validate(archive))
        let restored = try SpatialStore.decode(SpatialStore.encode(archive))
        XCTAssertNil(restored.assets[0].ownerships[1].shareBasisPoints)
        XCTAssertNil(restored.assets[0].usages[1].allocationBasisPoints)
        XCTAssertEqual(restored.assets[0].parts, archive.assets[0].parts)
        XCTAssertTrue(restored.assets[0].matches(.init(kind: .personal, ownerID: "owner:one")))
        XCTAssertTrue(restored.assets[0].matches(.init(kind: .business, businessID: "business:one")))
        XCTAssertFalse(restored.assets[0].matches(.init(kind: .unclassified)))
    }

    func testRatiosAndDuplicateOwnerUsageOrScopeAreRejected() throws {
        for value in [0, -1, 10_001, Int.max] {
            var a = spatial(usages: [usage(personal, allocation: value)])
            XCTAssertThrowsError(try SpatialGeometry.validate(a))
            a = spatial(); a.assets[0].ownerships[0].shareBasisPoints = value
            XCTAssertThrowsError(try SpatialGeometry.validate(a))
        }
        var a = spatial(usages: [usage(personal, id: "p", allocation: 6_000), usage(business, id: "b", allocation: 6_000)])
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = spatial(); a.assets[0].ownerships.append(.init(ownerID: "owner:two", shareBasisPoints: 1, sourceRecordID: "source:two", note: "합계 초과"))
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = spatial(); a.assets[0].ownerships.append(a.assets[0].ownerships[0])
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = spatial(usages: [usage(personal, id: "one"), usage(personal, id: "two")])
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = spatial(usages: [usage(personal), usage(business)])
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        let conflicting = RecordScope(kind: .business, ownerID: "owner:other", businessID: "business:one")
        a = spatial(usages: [usage(business, id: "one"), usage(conflicting, id: "two")])
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
    }

    func testPersonalOwnerAndBusinessUserCanLinkToRegisteredBusinessAsset() throws {
        let link = SpatialAccountLink(bookID: "book:business", accountID: "account:business-asset")
        let archive = spatial(usages: [usage(business, links: [link])])
        XCTAssertNoThrow(try SpatialAccountingLinks.validate(spatial: archive, accounting: accounting()))
        let storedBooks = accounting()
        let store = SpatialStore(path: directory.appendingPathComponent("spatial.json").path, accountingSnapshot: { storedBooks })
        XCTAssertEqual(try store.importArchive(archive), 1)
        XCTAssertEqual(try store.snapshot(), archive)
        XCTAssertEqual(storedBooks.entries.count, 0)
        // A tenant may own the usage record without owning the physical building.
        var rented = archive; rented.assets[0].ownerships[0].ownerID = "owner:landlord"
        XCTAssertNoThrow(try SpatialAccountingLinks.validate(spatial: rented, accounting: storedBooks))
    }

    func testCrossScopeWrongBookMissingAndNonAssetLinksAreRejected() throws {
        let badLinks: [SpatialAccountLink] = [
            .init(bookID: "book:personal", accountID: "account:personal-asset"),
            .init(bookID: "book:business", accountID: "account:personal-asset"),
            .init(bookID: "book:business", accountID: "account:missing"),
            .init(bookID: "book:business", accountID: "account:business-expense")
        ]
        for link in badLinks {
            XCTAssertThrowsError(try SpatialAccountingLinks.validate(spatial: spatial(usages: [usage(business, links: [link])]), accounting: accounting()))
        }
        let correct = SpatialAccountLink(bookID: "book:business", accountID: "account:business-asset")
        XCTAssertThrowsError(try SpatialGeometry.validate(spatial(usages: [usage(.init(kind: .unclassified), links: [correct])])))
        var books = accounting(); books.books[1].scope = nil
        XCTAssertThrowsError(try SpatialAccountingLinks.validate(spatial: spatial(usages: [usage(business, links: [correct])]), accounting: books))
    }

    func testUnrelatedLegacyBookOwnerTextDoesNotBlockNewValidatedLink() throws {
        var books = accounting()
        books.books.append(.init(id: "book:legacy", name: "이전 장부", ownerID: " legacy owner\n",
                                 kind: .financial, unit: books.books[0].unit))
        let link = SpatialAccountLink(bookID: "book:business", accountID: "account:business-asset")
        let archive = spatial(usages: [usage(business, links: [link])])
        XCTAssertNoThrow(try SpatialAccountingLinks.validate(spatial: archive, accounting: books))
        let snapshot = books
        let store = SpatialStore(path: directory.appendingPathComponent("spatial.json").path, accountingSnapshot: { snapshot })
        XCTAssertEqual(try store.importArchive(archive), 1)
        XCTAssertEqual(try store.snapshot(), archive)
    }

    func testUnrelatedAccountingScopeAddedLaterDoesNotInvalidateExistingSpatialLinks() throws {
        var books = accounting()
        let unlinkedScope = RecordScope(kind: .business, ownerID: "owner:unlinked-space", businessID: "business:unlinked")
        let linked = usage(business, id: "linked", links: [.init(bookID: "book:business", accountID: "account:business-asset")])
        let archive = spatial(usages: [linked, usage(unlinkedScope, id: "unlinked")])
        let store = SpatialStore(path: directory.appendingPathComponent("spatial.json").path, accountingSnapshot: { books })
        try store.importArchive(archive)
        // A separate accounting record does not establish a relationship with the unlinked spatial use.
        books.books.append(.init(id: "book:unrelated", name: "연결하지 않은 장부", ownerID: "owner:unrelated-book",
                                 kind: .financial, unit: books.books[0].unit,
                                 scope: .init(kind: .business, ownerID: "owner:unrelated-book", businessID: "business:unlinked")))
        XCTAssertNoThrow(try SpatialAccountingLinks.validate(spatial: archive, accounting: books))
        XCTAssertEqual(try store.snapshot(), archive)
    }

    func testRejectedLinksAndImmutableIDConflictsDoNotPartiallyCommit() throws {
        let storedBooks = accounting()
        let file = directory.appendingPathComponent("spatial.json")
        let store = SpatialStore(path: file.path, accountingSnapshot: { storedBooks })
        let original = spatial(usages: [usage(personal)])
        try store.importArchive(original)
        let data = try Data(contentsOf: file)
        let bad = usage(business, links: [.init(bookID: "book:personal", accountID: "account:personal-asset")])
        var incoming = spatial(id: "new", usages: [bad]); incoming.assets.append(spatial(id: "also-new").assets[0])
        XCTAssertThrowsError(try store.importArchive(incoming))
        XCTAssertEqual(try Data(contentsOf: file), data)
        incoming = original; incoming.assets[0].usages[0].scope = business
        XCTAssertThrowsError(try store.importArchive(incoming))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testSnapshotRevalidatesLinksButStandaloneShapesNeverReadAccounting() throws {
        let file = directory.appendingPathComponent("spatial.json")
        let standalone = SpatialStore(path: file.path, accountingSnapshot: { XCTFail("No new links means no accounting read"); return .init() })
        try standalone.importArchive(spatial())
        XCTAssertEqual(try standalone.snapshot().assets.count, 1)
        let books = accounting()
        let linked = spatial(id: "linked", usages: [usage(business, links: [.init(bookID: "book:business", accountID: "account:business-asset")])])
        try SpatialStore(path: file.path, accountingSnapshot: { books }).importArchive(linked)
        XCTAssertThrowsError(try SpatialStore(path: file.path, accountingSnapshot: { .init() }).snapshot())
    }

    func testSyntheticMixedUseExampleHasNoAccountingLinks() throws {
        let example = try SpatialStore.decode(SpatialCatalog.templateData())
        let asset = try XCTUnwrap(example.assets.first)
        XCTAssertTrue(asset.isSynthetic)
        XCTAssertEqual(Set(asset.usages.map(\.scope.kind)), [.personal, .business])
        XCTAssertEqual(Set(asset.usages.compactMap(\.scope.ownerID)), Set(asset.ownerships.map(\.ownerID)))
        XCTAssertFalse(SpatialAccountingLinks.hasLinks(example))
    }
}
