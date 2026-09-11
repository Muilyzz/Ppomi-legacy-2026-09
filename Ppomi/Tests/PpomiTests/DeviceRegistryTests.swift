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
}
