import XCTest
@testable import Ppomi

final class FixtureMacUI: MacUI.Session {
    var packageName = "com.google.Chrome"
    var appLabel = "Google Chrome"
    var drafts: [MacUI.Node]
    var last: MacUI.Snapshot?
    var taps: [(nodeId: String?, x: Double?, y: Double?)] = []
    var types: [(nodeId: String?, text: String)] = []
    var reads = 0
    var failRead: MacUI.Failure?
    var expireImmediately = false

    init(drafts: [MacUI.Node] = [
        MacUI.Node(id: "", parentId: nil, text: "Example Domain", role: "text", clickable: false, editable: false,
                   visible: true, enabled: true, password: false, bounds: .init(left: 0, top: 0, right: 800, bottom: 40)),
        MacUI.Node(id: "", parentId: nil, text: "More information", role: "link", clickable: true, editable: false,
                   visible: true, enabled: true, password: false, bounds: .init(left: 20, top: 80, right: 180, bottom: 104)),
        MacUI.Node(id: "", parentId: nil, text: "Search", role: "edit", clickable: false, editable: true,
                   visible: true, enabled: true, password: false, bounds: .init(left: 20, top: 120, right: 400, bottom: 148)),
        MacUI.Node(id: "", parentId: nil, text: "결제하기", role: "button", clickable: true, editable: false,
                   visible: true, enabled: true, password: false, bounds: .init(left: 20, top: 200, right: 120, bottom: 232)),
        MacUI.Node(id: "", parentId: nil, text: "비밀번호", role: "edit", clickable: false, editable: false,
                   visible: true, enabled: true, password: true, bounds: .init(left: 20, top: 240, right: 220, bottom: 268)),
    ]) {
        self.drafts = drafts
    }

    func read(app: String?) throws -> MacUI.Snapshot {
        if let failRead { throw failRead }
        _ = try MacUI.parseRead(app: app)
        reads += 1
        let snapshotId = "fixture-\(reads)"
        var nodes: [MacUI.Node] = []
        for (index, draft) in drafts.enumerated() {
            var node = draft
            node.id = "\(snapshotId):\(index)"
            nodes.append(node)
        }
        let snapshot = MacUI.Snapshot(snapshotId: snapshotId, packageName: packageName, appLabel: appLabel,
                                      nodes: nodes, truncated: false)
        last = expireImmediately ? nil : snapshot
        return snapshot
    }

    func tap(nodeId: String?, x: Double?, y: Double?) throws -> MacUI.ActionResult {
        taps.append((nodeId, x, y))
        guard let snapshot = last else { throw MacUI.Failure.staleScreen }
        if let nodeId {
            guard let node = snapshot.nodes.first(where: { $0.id == nodeId }) else { throw MacUI.Failure.staleScreen }
            if node.password || Tools.isPayWord(node.text) || !node.clickable || !node.enabled {
                throw MacUI.Failure.protectedAction
            }
            last = nil
            return MacUI.ActionResult(invoked: true)
        }
        guard let x, let y, snapshot.nodes.contains(where: { $0.bounds.contains(x, y) }) else {
            throw MacUI.Failure.staleScreen
        }
        if let hit = snapshot.nodes.last(where: { $0.bounds.contains(x, y) }),
           hit.password || Tools.isPayWord(hit.text) {
            throw MacUI.Failure.protectedAction
        }
        last = nil
        return MacUI.ActionResult(invoked: true)
    }

    func type(nodeId: String?, text: String) throws -> MacUI.ActionResult {
        types.append((nodeId, text))
        guard let snapshot = last else { throw MacUI.Failure.staleScreen }
        if let nodeId {
            guard let node = snapshot.nodes.first(where: { $0.id == nodeId }), node.editable, !node.password else {
                throw nodeId.hasPrefix(snapshot.snapshotId) ? MacUI.Failure.protectedAction : MacUI.Failure.staleScreen
            }
        }
        last = nil
        return MacUI.ActionResult(typed: true)
    }
}

final class MacUIToolsTests: XCTestCase {
    private var directory: URL!
    private var fixture: FixtureMacUI!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = FixtureMacUI()
        MacUI.fake = fixture
    }

    override func tearDownWithError() throws {
        MacUI.fake = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func tools() throws -> Tools {
        try Tools(db: DB(path: directory.appendingPathComponent("ledger.db").path, writable: true))
    }

    func testParseRejectsBadTapTypeAndUnknownApps() throws {
        XCTAssertNil(try MacUI.parseRead(app: nil))
        XCTAssertEqual(try MacUI.parseRead(app: "Safari"), MacUI.safariID)
        XCTAssertEqual(try MacUI.parseRead(app: "com.google.Chrome"), MacUI.chromeID)
        XCTAssertThrowsError(try MacUI.parseRead(app: "Notes"))
        XCTAssertThrowsError(try MacUI.parseTap([:]))
        XCTAssertThrowsError(try MacUI.parseTap(["nodeId": "a", "x": 1, "y": 2]))
        XCTAssertThrowsError(try MacUI.parseTap(["x": 1]))
        XCTAssertThrowsError(try MacUI.parseTap(["x": true, "y": 2]))
        XCTAssertNoThrow(try MacUI.parseTap(["nodeId": "fixture-1:1"]))
        XCTAssertNoThrow(try MacUI.parseTap(["x": 40.0, "y": 90.0]))
        XCTAssertThrowsError(try MacUI.parseType(["text": "x\u{0007}"]))
        XCTAssertThrowsError(try MacUI.parseType(["text": String(repeating: "x", count: 4097)]))
        XCTAssertEqual(try MacUI.parseType(["text": ""]).text, "")
        XCTAssertEqual(try MacBrowser.bundleID(for: "safari"), "com.apple.Safari")
        XCTAssertEqual(try MacBrowser.displayName(for: nil), "Google Chrome")
        XCTAssertThrowsError(try MacBrowser.bundleID(for: "firefox"))
    }

    func testScreenReadTapTypeJSONAndStaleIds() throws {
        let tools = try tools()
        let read = tools.execute("screen_read", ["app": "chrome"])
        XCTAssertFalse(read.hasPrefix("오류:"), read)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual(object["appLabel"] as? String, "Google Chrome")
        XCTAssertEqual(object["packageName"] as? String, "com.google.Chrome")
        XCTAssertEqual(object["truncated"] as? Bool, false)
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 5)
        XCTAssertEqual(nodes[1]["clickable"] as? Bool, true)
        XCTAssertEqual(nodes[2]["editable"] as? Bool, true)
        XCTAssertEqual(nodes[4]["password"] as? Bool, true)
        XCTAssertEqual(nodes[4]["text"] as? String, "비밀번호")
        let link = try XCTUnwrap(nodes[1]["id"] as? String)
        let field = try XCTUnwrap(nodes[2]["id"] as? String)
        let tap = tools.execute("ui_tap", ["nodeId": link])
        XCTAssertTrue(tap.contains("\"invoked\":true"), tap)
        XCTAssertEqual(fixture.taps.map(\.nodeId), [link])
        assertContract(tools.execute("ui_tap", ["nodeId": link]), code: "stale_screen")
        _ = tools.execute("screen_read", [:])
        let typed = tools.execute("ui_type", ["nodeId": "fixture-2:2", "text": "hello"])
        XCTAssertTrue(typed.contains("\"typed\":true"), typed)
        XCTAssertEqual(fixture.types.map(\.text), ["hello"])
        XCTAssertEqual(field.hasSuffix(":2"), true)
        XCTAssertTrue(MacUI.names.isSubset(of: RuntimeEvent.allowedTools))
        XCTAssertTrue(MacUI.names.isSubset(of: Set(MCPServer.tools.map(\.name))))
    }

    func testCoordinateTapAndProtectedPayOrPassword() throws {
        let tools = try tools()
        _ = tools.execute("screen_read", [:])
        let byPoint = tools.execute("ui_tap", ["x": 40.0, "y": 90.0])
        XCTAssertTrue(byPoint.contains("\"invoked\":true"), byPoint)
        _ = tools.execute("screen_read", [:])
        assertContract(tools.execute("ui_tap", ["nodeId": "fixture-2:3"]), code: "protected_action")
        assertContract(tools.execute("ui_type", ["nodeId": "fixture-2:4", "text": "secret"]), code: "protected_action")
        assertContract(tools.execute("ui_tap", ["x": 9_999.0, "y": 9_999.0]), code: "stale_screen")
    }

    func testErrorInterpolationExposesContractCodesNotEnumCases() {
        XCTAssertTrue("\(MacUI.Failure.staleScreen)".hasPrefix("stale_screen"))
        XCTAssertTrue("\(MacUI.Failure.protectedAction)".hasPrefix("protected_action"))
        XCTAssertFalse("\(MacUI.Failure.staleScreen)".contains("staleScreen"))
        XCTAssertFalse("\(MacUI.Failure.protectedAction)".contains("protectedAction"))
        XCTAssertTrue("오류: \(MacUI.Failure.staleScreen)".hasPrefix("오류: stale_screen"))
        XCTAssertTrue("오류: \(MacUI.Failure.protectedAction)".hasPrefix("오류: protected_action"))
        XCTAssertEqual(MacUI.Failure.staleScreen.localizedDescription, MacUI.Failure.staleScreen.description)
        XCTAssertTrue(MacUI.isPassword(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(MacUI.isPassword(role: "AXSecureTextField", subrole: ""))
        XCTAssertFalse(MacUI.isPassword(role: "AXTextField", subrole: ""))
        XCTAssertTrue(MacUI.clicksWebContent(role: "AXLink", rolesTowardRoot: ["AXLink", "AXGroup", "AXWindow"]))
        XCTAssertTrue(MacUI.clicksWebContent(role: "AXButton", rolesTowardRoot: ["AXButton", "AXWebArea", "AXWindow"]))
        XCTAssertFalse(MacUI.clicksWebContent(role: "AXButton", rolesTowardRoot: ["AXButton", "AXToolbar", "AXWindow"]))
        XCTAssertEqual(MacUI.hidUTF16Chunks("hello", size: 2).map { String(utf16CodeUnits: $0, count: $0.count) },
                       ["he", "ll", "o"])
        XCTAssertEqual(MacUI.hidUTF16Chunks("", size: 16), [])
    }

    @MainActor
    func testMCPAndExecutorExposeTheSameTools() async throws {
        let tools = try tools()
        var named: [(URL, String)] = []
        tools.openNamedBrowser = { named.append(($0, $1)) }
        XCTAssertTrue(tools.execute("browser_open", ["url": "https://example.com/", "browser": "safari"])
            .hasPrefix("Mac의 Safari에 열었다"))
        XCTAssertEqual(named.map(\.1), ["safari"])
        XCTAssertTrue(tools.execute("browser_open", ["url": "https://example.com/", "browser": "firefox"]).hasPrefix("오류:"))

        let mcp = try MCPServer(dbPath: directory.appendingPathComponent("mcp.db").path, fd: -1)
        let screen = mcp.call("screen_read", ["app": "safari"])
        XCTAssertNil(screen["isError"])
        let structured = try XCTUnwrap(screen["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["packageName"] as? String, "com.google.Chrome")
        let names = MCPServer.tools.map(\.name)
        for name in ["screen_read", "ui_tap", "ui_type", "browser_open"] {
            XCTAssertTrue(names.contains(name), name)
        }

        let executor = AgentExecutor(workspace: AgentWorkspace(root: directory.appendingPathComponent("files")),
                                     mcp: mcp, configured: { false })
        let bootstrap = await call(executor, "bootstrap")
        let body = try XCTUnwrap(bootstrap["result"] as? [String: Any])
        let listed = try XCTUnwrap(body["tools"] as? [String])
        XCTAssertTrue(listed.contains("screen_read"))
        XCTAssertTrue(listed.contains("ui_tap"))
        XCTAssertTrue(listed.contains("ui_type"))
        XCTAssertEqual((body["executor"] as? [String: Any])?["browserAutomation"] as? Bool, true)
        _ = await call(executor, "sessionState", ["active": true, "mode": "text"])
        let invoked = await call(executor, "executeTool", ["name": "screen_read", "args": ["app": "chrome"]])
        let result = try XCTUnwrap(invoked["result"] as? [String: Any])
        XCTAssertEqual(result["error"] as? Bool, false)
        XCTAssertNotNil(result["structuredContent"])
        executor.invalidate()
    }

    @MainActor
    private func call(_ executor: AgentExecutor, _ method: String, _ args: [String: Any] = [:]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            executor.receive(["id": UUID().uuidString, "method": method, "args": args]) { continuation.resume(returning: $0) }
        }
    }

    private func assertContract(_ message: String, code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(message.hasPrefix("오류: \(code)"), "\(message)", file: file, line: line)
        XCTAssertFalse(message.contains("staleScreen"), message, file: file, line: line)
        XCTAssertFalse(message.contains("protectedAction"), message, file: file, line: line)
    }
}
