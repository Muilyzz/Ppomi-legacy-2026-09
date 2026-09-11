import XCTest
@testable import Ppomi

final class DeviceRegistryTests: XCTestCase {
    func testAttachUpsertsThisMacAndListsByOwner() throws {
        let registry = DeviceRegistry()
        let first = try registry.attach(DeviceSessionAttach(
            deviceId: "mac-1", os: .macos, ownerId: "owner-a", orgId: nil, lastSeen: "2026-09-11T00:00:00Z"))
        XCTAssertEqual(first.id, "mac-1")
        XCTAssertEqual(first.os, .macos)
        XCTAssertTrue(first.online)
        XCTAssertEqual(first.ownerId, "owner-a")
        XCTAssertEqual(registry.list(DeviceListScope(ownerId: "owner-a")).map(\.id), ["mac-1"])
        XCTAssertTrue(registry.list(DeviceListScope(ownerId: "other")).isEmpty)

        let again = try registry.attach(DeviceSessionAttach(
            deviceId: "mac-1", os: .macos, ownerId: "owner-a", lastSeen: "2026-09-11T01:00:00Z"))
        XCTAssertEqual(again.lastSeen, "2026-09-11T01:00:00Z")
        XCTAssertEqual(registry.list(DeviceListScope(ownerId: "owner-a")).count, 1)
        XCTAssertEqual(DeviceRegistry.displayLine(again), "이 Mac · macos · 온라인")
    }

    func testAttachRejectsEmptyIdsAndDoesNotStoreSecrets() {
        let registry = DeviceRegistry()
        XCTAssertThrowsError(try registry.attach(DeviceSessionAttach(deviceId: "  ", os: .macos, ownerId: "o")))
        XCTAssertThrowsError(try registry.attach(DeviceSessionAttach(deviceId: "d", os: .macos, ownerId: "")))
        let device = registry.attachThisMac(deviceId: "mac-local", ownerId: "local")
        let encoded = String(data: try! JSONEncoder().encode(device), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertFalse(encoded.contains("secret"))
    }

    func testAttachRefusesCrossOwnerReattachAndKeepsTheOriginal() throws {
        let registry = DeviceRegistry()
        _ = try registry.attach(DeviceSessionAttach(deviceId: "mac-1", os: .macos, ownerId: "owner-a"))
        XCTAssertThrowsError(try registry.attach(DeviceSessionAttach(deviceId: "mac-1", os: .macos, ownerId: "owner-b"))) { error in
            XCTAssertTrue("\(error)".contains("owner_mismatch"), "\(error)")
        }
        // The original owner still holds the device; the intruder sees nothing.
        XCTAssertEqual(registry.list(DeviceListScope(ownerId: "owner-a")).map(\.id), ["mac-1"])
        XCTAssertTrue(registry.list(DeviceListScope(ownerId: "owner-b")).isEmpty)
    }

    func testOpaqueOwnerNeverContainsTheEmail() {
        XCTAssertEqual(DeviceRegistry.opaqueOwner(email: nil), "local")
        XCTAssertEqual(DeviceRegistry.opaqueOwner(email: "   "), "local")
        let owner = DeviceRegistry.opaqueOwner(email: "ceo@example.com")
        XCTAssertTrue(owner.hasPrefix("owner:"), owner)
        XCTAssertFalse(owner.contains("ceo@example.com"), owner)
        XCTAssertFalse(owner.contains("@"), owner)
        XCTAssertEqual(owner, DeviceRegistry.opaqueOwner(email: "ceo@example.com"))   // stable
    }

    func testLoadPersistedDeduplicatesByIdAndToleratesACorruptFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fleet.json")

        // Two rows with the same id must not trap; last write wins.
        let duplicated = """
        [{"id":"mac-1","lastSeen":"2026-09-11T00:00:00Z","online":true,"os":"macos","ownerId":"owner-a"},\
        {"id":"mac-1","lastSeen":"2026-09-11T02:00:00Z","online":false,"os":"macos","ownerId":"owner-a"}]
        """
        try duplicated.write(to: url, atomically: true, encoding: .utf8)
        let registry = DeviceRegistry(); registry.persistURL = url; registry.loadPersisted()
        let loaded = registry.list(DeviceListScope(ownerId: "owner-a"))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.online, false)   // last write wins

        // A corrupt file starts empty instead of crashing.
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let recovered = DeviceRegistry(); recovered.persistURL = url; recovered.loadPersisted()
        XCTAssertTrue(recovered.list(DeviceListScope(ownerId: "owner-a")).isEmpty)
    }

    func testAttachWritesFleetFileWithOwnerOnlyPermissions() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fleet.json")
        let registry = DeviceRegistry(); registry.persistURL = url
        _ = try registry.attach(DeviceSessionAttach(deviceId: "mac-1", os: .macos, ownerId: "owner-a"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }
}
