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

    func testColdStartMissingPermissionsShowsPromptNotSettingsTheFirstTime() throws {
        let path = NSTemporaryDirectory() + "ppomi-kb-perm-\(UUID().uuidString)/ledger.db"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tools = try Tools(db: try DB(path: path, writable: true))
        tools.currentText = "해줘"
        tools.phoneGateStatus = { (false, "CONNECTED") }
        tools.permissionNeed = { .prompt }
        var hands: [[String]] = []
        Tools.fake = (screen: { [] }, hand: { hands.append($0) })
        let out = tools.execute("path_cold_start", ["app": "kb-enterprise"])
        XCTAssertTrue(out.hasPrefix("실행 안 함:"), out)
        XCTAssertTrue(out.contains("권한 허용"), out)
        XCTAssertFalse(out.contains("설정이 열렸"), out)
        XCTAssertEqual(try tools.db.state("setup:prompt"), "1")
        XCTAssertNil(try tools.db.state("setup:needed"))
        XCTAssertTrue(hands.isEmpty)
    }

    func testColdStartDeniedPermissionsOpensStartupSettings() throws {
        let path = NSTemporaryDirectory() + "ppomi-kb-deny-\(UUID().uuidString)/ledger.db"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let tools = try Tools(db: try DB(path: path, writable: true))
        tools.currentText = "해줘"
        tools.phoneGateStatus = { (false, "CONNECTED") }
        tools.permissionNeed = { .settings }
        Tools.fake = (screen: { [] }, hand: { _ in XCTFail("denied permissions must not touch the phone") })
        let out = tools.execute("path_cold_start", ["app": "kb-enterprise"])
        XCTAssertTrue(out.contains("시작하기"), out)
        XCTAssertTrue(out.contains("다시 실행"), out)
        XCTAssertEqual(try tools.db.state("setup:needed"), "1")
        XCTAssertNil(try tools.db.state("setup:prompt"))
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

    @MainActor func testChatPathResultDocksIPhoneAndStopsAtHumanLoginWithoutSecrets() {
        let state = AppState()
        state.applyPathColdStart("멈춤: 사람 로그인(Face ID). 이 Mac · macos · 온라인. 계좌·비밀은 읽지 않음.")
        XCTAssertEqual(state.workSurface, .iphone)
        XCTAssertFalse(state.pathBusy)
        XCTAssertTrue(state.pathStatus?.contains("멈춤") == true, state.pathStatus ?? "")
        XCTAssertFalse(state.pathStatus?.contains("123456") == true)
        XCTAssertFalse(state.pathStatus?.contains("계좌번호") == true)
        if case .humanTurn(let reason) = state.phase {
            XCTAssertTrue(reason.contains("Face ID"), reason)
        } else {
            XCTFail("expected humanTurn, got \(state.phase)")
        }
        XCTAssertEqual(AgentVoicePanel.surfaceHint(for: "path_cold_start", args: ["app": "kb-enterprise"]), .iphone)
    }

    func testBundledKBEnterpriseDeclaresHomeThenOpenThenHumanLogin() throws {
        let record = try XCTUnwrap(PlaybookCatalog.resolve("kb-enterprise"))
        let cap = try XCTUnwrap(record.manifest.capabilities.first { $0.id == "cold-start-open" })
        XCTAssertEqual(cap.steps.map(\.id), ["go-home", "open-kb", "human-login"])
        XCTAssertEqual(cap.steps.map(\.kind), ["close", "open", "human"])
        XCTAssertTrue(record.manifest.capabilities.first { $0.id == "cold-start-open" }?.description.contains("path_cold_start") == true)
        XCTAssertTrue(record.guideText.contains("KB 사업자 계좌"))
        XCTAssertTrue(record.guideText.contains("버튼을 누르지 않는다") || record.guideText.contains("누르지 않는다"))
    }
}
