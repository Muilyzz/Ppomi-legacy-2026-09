// 맥앱 비서 브리지: MCP 도구 스펙이 JSON 으로 나가고, fd -1 의 인프로세스 MCPServer 가 도구를 실행하며 지시문을 준다.
import XCTest
@testable import Ppomi

final class AssistantToolBridgeTests: XCTestCase {
    func testToolSpecsAreJSONSerializableAndIncludeThePhoneAndWindowsTools() throws {
        let specs = MCPServer.toolSpecs
        XCTAssertTrue(JSONSerialization.isValidJSONObject(specs))
        let names = specs.map { $0["name"] as! String }
        for name in ["phone_screen", "phone_tap", "windows_screen", "windows_click", "profile_fill", "run_combo", "bank_profile_capture", "verify_step", "read_playbook", "screen_read", "ui_tap", "ui_type"] {
            XCTAssertTrue(names.contains(name), name)
        }
        let fill = try XCTUnwrap(specs.first { $0["name"] as? String == "profile_fill" })
        let params = try XCTUnwrap(fill["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertTrue(Set((params["required"] as? [String]) ?? []).isSuperset(of: ["x", "y"]))
        XCTAssertNotNil((params["properties"] as? [String: Any])?["form"])
    }

    func testInProcessServerRunsAToolAndCarriesInstructions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try MCPServer(dbPath: dir.appendingPathComponent("ledger.db").path, fd: -1)
        XCTAssertTrue(server.instructions.contains("verify_step"))
        let r = server.call("list_playbooks", [:])
        let text = try XCTUnwrap(((r["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("\"playbooks\""))
        let bad = server.call("no_such_tool", [:])
        XCTAssertEqual(bad["isError"] as? Bool, true)
    }
}
