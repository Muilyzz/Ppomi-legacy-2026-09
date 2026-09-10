import Foundation
import SceneKit
import XCTest
@testable import Ppomi

final class SpatialAssetTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiSpatial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(id: String = "asset:1") -> SpatialArchive {
        .init(assets: [.init(id: id, entityID: "entity:1", title: "임의 공간", accountIDs: ["account:property"], parts: [
            .init(id: "part:1", title: "임의 형상", footprint: [.init(x: 0, y: 0), .init(x: 12, y: 0), .init(x: 12, y: 8), .init(x: 0, y: 8)],
                  height: 13, elevation: -2, provenance: .init(kind: .measured, sourceRecordID: "source:survey", note: "입력 도면의 치수"))
        ])])
    }

    func testRoundTripRetainsCoordinatesEvidenceAndLinksWithoutAccountingValues() throws {
        var archive = fixture()
        archive.assets[0].parts[0].provenance.kind = .estimated
        archive.assets[0].parts[0].provenance.note = "높이는 자료의 별도 추정치이고 외곽선은 도면에서 읽었습니다."
        XCTAssertEqual(try SpatialStore.decode(SpatialStore.encode(archive)), archive)
        XCTAssertEqual(SpatialGeometry.area(archive.assets[0].parts[0].footprint), 96, accuracy: 0.0001)
        let payload = String(decoding: try SpatialStore.encode(archive), as: UTF8.self)
        XCTAssertFalse(payload.contains("postings")); XCTAssertFalse(payload.contains("valuation"))
    }

    func testConcaveAndEitherWindingFootprintsAreAccepted() throws {
        let points: [SpatialPoint] = [.init(x: 0, y: 0), .init(x: 6, y: 0), .init(x: 6, y: 2), .init(x: 2, y: 2), .init(x: 2, y: 6), .init(x: 0, y: 6)]
        XCTAssertNoThrow(try SpatialGeometry.validateFootprint(points))
        XCTAssertNoThrow(try SpatialGeometry.validateFootprint(points.reversed()))
        XCTAssertEqual(SpatialGeometry.area(points), 20, accuracy: 0.0001)
        let translated = points.map { SpatialPoint(x: $0.x + 999_990, y: $0.y - 999_990) }
        XCTAssertEqual(SpatialGeometry.area(translated), 20, accuracy: 0.0001)
    }

    func testDegenerateCrossingTouchingAndOverlappingFootprintsAreRejected() throws {
        let invalid: [[SpatialPoint]] = [
            [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)],
            [.init(x: 0, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4), .init(x: 4, y: 0)],
            [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 4)],
            [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 4), .init(x: 2, y: 0), .init(x: 0, y: 4)],
            [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 0)]
        ]
        for footprint in invalid { XCTAssertThrowsError(try SpatialGeometry.validateFootprint(footprint)) }
    }

    func testInvalidUnitsVersionsIDsUnknownOrNonfiniteDimensionsAreRejected() throws {
        var a = fixture(); a.unit = "feet"; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.formatVersion = 2; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets.append(a.assets[0]); XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].parts.append(a.assets[0].parts[0]); XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].entityID = " "; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].parts[0].provenance.sourceRecordID = ""; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].parts[0].provenance.note = ""; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        for height in [0.0, -1.0, .infinity, .nan, 10_001] {
            a = fixture(); a.assets[0].parts[0].height = height; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        }
        a = fixture(); a.assets[0].parts[0].elevation = .nan; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].parts[0].footprint[0].x = .infinity; XCTAssertThrowsError(try SpatialGeometry.validate(a))
        let withoutHeight = try JSONSerialization.jsonObject(with: SpatialStore.encode(fixture())) as! [String: Any]
        var missing = withoutHeight
        var assets = missing["assets"] as! [[String: Any]]
        var parts = assets[0]["parts"] as! [[String: Any]]; parts[0].removeValue(forKey: "height")
        assets[0]["parts"] = parts; missing["assets"] = assets
        XCTAssertThrowsError(try SpatialStore.decode(JSONSerialization.data(withJSONObject: missing)))
    }

    func testSyntheticExamplesAreExplicitAndPreviewDoesNotPopulateStore() throws {
        let template = try SpatialStore.decode(SpatialCatalog.templateData())
        XCTAssertFalse(template.assets.isEmpty)
        XCTAssertTrue(template.assets.allSatisfy { $0.isSynthetic && $0.parts.allSatisfy { $0.provenance.kind == .schematic } })
        let path = directory.appendingPathComponent("private/spatial.json").path
        XCTAssertTrue(try SpatialStore(path: path).snapshot().assets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        var invalid = fixture(); invalid.assets[0].isSynthetic = true
        XCTAssertThrowsError(try SpatialGeometry.validate(invalid))
    }

    func testImmutableIDRetryAndConflictingImportAreAtomic() throws {
        let path = directory.appendingPathComponent("private/spatial.json").path
        let store = SpatialStore(path: path)
        XCTAssertEqual(try store.importArchive(fixture()), 1)
        XCTAssertEqual(try store.importArchive(fixture()), 0)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var conflicting = fixture(); conflicting.assets[0].parts[0].height = 22
        conflicting.assets.insert(fixture(id: "new").assets[0], at: 0)
        XCTAssertThrowsError(try store.importArchive(conflicting))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertEqual(try SpatialStore(path: path).snapshot(), fixture())
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testConcurrentImportsDoNotLoseAssets() throws {
        let path = directory.appendingPathComponent("private/spatial.json").path
        let archives = (0..<12).map { fixture(id: "asset:\($0)") }
        DispatchQueue.concurrentPerform(iterations: archives.count) { index in
            do { try SpatialStore(path: path).importArchive(archives[index]) }
            catch { XCTFail("Concurrent import failed: \(error)") }
        }
        XCTAssertEqual(try SpatialStore(path: path).snapshot().assets.count, archives.count)
    }

    func testOversizedDataAndRemoteInputsAreRejected() throws {
        XCTAssertThrowsError(try SpatialStore.decode(Data(repeating: 32, count: SpatialGeometry.maximumBytes + 1)))
        XCTAssertThrowsError(try SpatialStore.readFile(URL(string: "https://example.com/model.json")!))
        var a = fixture()
        a.assets = (0...SpatialGeometry.maximumAssets).map { fixture(id: "asset:\($0)").assets[0] }
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
        a = fixture(); a.assets[0].parts[0].footprint = Array(repeating: .init(x: 0, y: 0), count: SpatialGeometry.maximumVertices + 1)
        XCTAssertThrowsError(try SpatialGeometry.validate(a))
    }

    @MainActor func testSceneExtrudesConcavePartsAtTheirDeclaredHeightAndElevation() throws {
        let archive = try SpatialStore.decode(SpatialCatalog.templateData())
        let asset = try XCTUnwrap(archive.assets.first)
        let view = SCNView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        SpatialScene.configure(view, asset: asset)
        let base = asset.parts.map(\.elevation).min() ?? 0
        for part in asset.parts {
            let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "part:" + part.id, recursively: false))
            let shape = try XCTUnwrap(node.geometry as? SCNShape)
            XCTAssertEqual(Double(shape.extrusionDepth), part.height, accuracy: 0.00001)
            XCTAssertEqual(Double(node.position.y), part.elevation - base + part.height / 2, accuracy: 0.00001)
        }
        XCTAssertNotNil(view.pointOfView?.camera)
    }
}
