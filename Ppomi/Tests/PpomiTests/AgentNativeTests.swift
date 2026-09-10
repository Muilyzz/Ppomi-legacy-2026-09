import Darwin
import XCTest
@testable import Ppomi

final class AgentNativeTests: XCTestCase {
    private var temporary: URL!
    private var workspace: AgentWorkspace!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-agent-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        workspace = AgentWorkspace(root: temporary.appendingPathComponent("workspace", isDirectory: true))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testFilesAreAtomicVerifiedUTF8AndBounded() throws {
        let saved = try workspace.write(path: "test.txt", content: "테스트 기록")
        let read = try workspace.read(path: "test.txt")
        XCTAssertEqual(read["content"] as? String, "테스트 기록")
        XCTAssertEqual(saved["sha256"] as? String, read["sha256"] as? String)
        XCTAssertEqual(saved["verified"] as? Bool, true)
        XCTAssertThrowsError(try workspace.write(path: "test.txt", content: String(repeating: "x", count: AgentWorkspace.limit + 1)))
        XCTAssertEqual(try workspace.read(path: "test.txt")["content"] as? String, "테스트 기록")
        let files = try XCTUnwrap(try workspace.list()["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0]["path"] as? String, "test.txt")
        try Data([0xff, 0xfe]).write(to: workspace.root.appendingPathComponent("binary"))
        XCTAssertThrowsError(try workspace.read(path: "binary"))
    }

    func testTraversalSymlinksHardlinksAndSpecialFilesCannotEscape() throws {
        _ = try workspace.list()
        for path in ["../outside", "/tmp/file", "a/../x", "a//x", "a\\x", ".", "a/", "\0"] {
            XCTAssertThrowsError(try workspace.read(path: path), path)
            XCTAssertThrowsError(try workspace.write(path: path, content: "x"), path)
        }
        let outside = temporary.appendingPathComponent("outside.txt")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.read(path: "link"))
        XCTAssertThrowsError(try workspace.write(path: "link", content: "changed"))
        try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("directory"), withDestinationURL: temporary)
        XCTAssertThrowsError(try workspace.list(path: "directory"))
        XCTAssertThrowsError(try workspace.read(path: "directory/outside.txt"))
        try FileManager.default.linkItem(at: outside, to: workspace.root.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try workspace.read(path: "hardlink"))
        XCTAssertThrowsError(try workspace.write(path: "hardlink", content: "changed"))
        XCTAssertEqual(mkfifo(workspace.root.appendingPathComponent("fifo").path, 0o600), 0)
        XCTAssertThrowsError(try workspace.read(path: "fifo"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
        XCTAssertEqual((try workspace.list()["files"] as? [[String: Any]])?.count, 0)
    }

    func testSymlinkWorkspaceRootIsRejected() throws {
        try FileManager.default.createSymbolicLink(at: workspace.root, withDestinationURL: temporary)
        XCTAssertThrowsError(try workspace.write(path: "escape", content: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("escape").path))
    }

    func testNewSessionCannotExecuteOldQueuedTools() throws {
        let lifetime = AgentNativeSession()
        var executions = 0
        XCTAssertThrowsError(try lifetime.perform { executions += 1 })
        lifetime.setActive(true)
        let first = lifetime.revision
        try lifetime.perform(revision: first) { executions += 1 }
        lifetime.setActive(false)
        XCTAssertThrowsError(try lifetime.perform(revision: first) { executions += 1 })
        lifetime.setActive(true)
        XCTAssertThrowsError(try lifetime.perform(revision: first) { executions += 1 })
        try lifetime.perform(revision: lifetime.revision) { executions += 1 }
        XCTAssertEqual(executions, 2)
    }

    func testOnlyBundledEntryAndAllowlistedHTTPSPathsAreTrusted() throws {
        let entry = URL(fileURLWithPath: "/App/Web/Agent/index.html")
        XCTAssertTrue(AgentNativePolicy.trusted(entry, entry: entry))
        for url in ["https://example.invalid/index.html", "file:///App/Web/other.html", "file:///App/Web/Agent/index.html#x", "file:///App/Web/Agent/index.html?x=1"] {
            XCTAssertFalse(AgentNativePolicy.trusted(URL(string: url), entry: entry))
        }
        for endpoint in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid?x=1", "https://example.invalid#x", "https://example.invalid/%2e%2e", "https://example.invalid/../x"] {
            XCTAssertThrowsError(try AgentNativePolicy.endpoint(endpoint), endpoint)
        }
        XCTAssertEqual(try AgentNativePolicy.requestURL(endpoint: "https://example.invalid/agent", path: "/v1/session").absoluteString,
                       "https://example.invalid/agent/v1/session")
        XCTAssertThrowsError(try AgentNativePolicy.requestURL(endpoint: "https://example.invalid", path: "/v1/session?next=evil"))
        XCTAssertThrowsError(try AgentNativePolicy.requestURL(endpoint: "https://example.invalid", path: "https://evil.invalid"))
    }

    func testAgentProxyAuthenticatesNativelyWithoutForwardingDevicePassword() throws {
        let device = "6c856bbe-e215-4434-b5f8-9c92f94d76a1"
        let config = SharedServerConfiguration(url: "https://abcdefghijklmnopqrst.supabase.co", publishableKey: "sb_publishable_testpublicvalue123456789",
                                               email: "synthetic@example.invalid", password: "synthetic-device-password", deviceId: device)
        var requests = [URLRequest]()
        let client = SharedServerClient(configuration: { config }) { request in
            requests.append(request)
            let value: [String: Any]
            if request.url!.path.contains("/auth/") { value = ["access_token": "synthetic-access-token", "expires_in": 3600] }
            else if request.url!.path.hasSuffix("ppomi_context") {
                value = ["device": ["id": device], "workspace": ["id": "1a8ca76f-4530-422e-9373-6c17015c30d8"], "devices": []]
            } else {
                XCTAssertEqual(request.url!.host, "agent.example.invalid")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-token")
                XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
                XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(config.password))
                value = ["clientSecret": "synthetic-short-lived", "model": "synthetic"]
            }
            return .init(data: try JSONSerialization.data(withJSONObject: value), status: 200)
        }
        XCTAssertThrowsError(try client.agentRequest(endpoint: "https://agent.example.invalid", path: "/private", body: [:]))
        XCTAssertTrue(requests.isEmpty)
        let result = try XCTUnwrap(try client.agentRequest(endpoint: "https://agent.example.invalid", path: "/v1/session", body: [:]) as? [String: Any])
        XCTAssertEqual(result["clientSecret"] as? String, "synthetic-short-lived")
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(String(describing: result).contains("synthetic-access-token"))
    }
}
