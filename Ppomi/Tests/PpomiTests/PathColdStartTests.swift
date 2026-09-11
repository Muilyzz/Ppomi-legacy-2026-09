import XCTest
@testable import Ppomi

final class PathColdStartTests: XCTestCase {
    override func tearDown() {
        Tools.fake = nil
        super.tearDown()
    }

    func testColdStartHomesThenOpensKBAndStopsAtHumanLogin() throws {
        let path = NSTemporaryDirectory() + "ppomi-kb-\(UUID().uuidString)/ledger.db"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tools = try Tools(db: try DB(path: path, writable: true))
        tools.footprintDir = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("playbooks")
        tools.currentText = "해줘"
        tools.deviceRegistry = DeviceRegistry()
        var hands: [[String]] = []
        Tools.fake = (screen: { [OCR.Word(x: 0.1, y: 0.2, w: 0.3, h: 0.03, text: "합성 홈")] }, hand: { hands.append($0) })

        let out = tools.execute("path_cold_start", ["app": "kb-enterprise"])
        XCTAssertTrue(out.contains("멈춤"), out)
        XCTAssertTrue(out.contains("로그인"), out)
        XCTAssertTrue(out.contains("example 아님"), out)
        XCTAssertFalse(out.contains("123456"), out)
        XCTAssertFalse(out.contains("계좌번호"), out)
        XCTAssertEqual(hands.first, ["key", "home"])
        XCTAssertEqual(hands.dropFirst().first, ["open", "KB스타기업뱅킹"])
        XCTAssertTrue(MCPServer.tools.contains { $0.name == "path_cold_start" })
        let fleet = tools.deviceRegistry.list(DeviceListScope(ownerId: "local"))
        XCTAssertEqual(fleet.first?.os, .macos)
        XCTAssertTrue(fleet.first?.online == true)
    }

    func testColdStartRefusesOtherApps() throws {
        let path = NSTemporaryDirectory() + "ppomi-kb-\(UUID().uuidString)/ledger.db"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tools = try Tools(db: try DB(path: path, writable: true))
        tools.currentText = "해줘"
        var hands: [[String]] = []
        Tools.fake = (screen: { [] }, hand: { hands.append($0) })
        let out = tools.execute("path_cold_start", ["app": "yeogi"])
        XCTAssertTrue(out.hasPrefix("실행 안 함:"), out)
        XCTAssertTrue(hands.isEmpty)
    }

    func testBundledKBEnterpriseDeclaresHomeThenOpenThenHumanLogin() throws {
        let record = try XCTUnwrap(PlaybookCatalog.resolve("kb-enterprise"))
        let cap = try XCTUnwrap(record.manifest.capabilities.first { $0.id == "cold-start-open" })
        XCTAssertEqual(cap.steps.map(\.id), ["go-home", "open-kb", "human-login"])
        XCTAssertEqual(cap.steps.map(\.kind), ["close", "open", "human"])
    }
}
