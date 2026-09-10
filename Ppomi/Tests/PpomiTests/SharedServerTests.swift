import XCTest
@testable import Ppomi

final class SharedServerTests: XCTestCase {
    private let deviceID = "6c856bbe-e215-4434-b5f8-9c92f94d76a1"
    private let runID = "4ca856ec-8886-4891-af94-3167a72d2d58"
    private let operationID = "f4ff78b6-edf0-4a21-9c52-66b41c205d61"

    private func config(url: String = "https://abcdefghijklmnopqrst.supabase.co", key: String = "sb_publishable_testpublicvalue123456789") -> SharedServerConfiguration {
        SharedServerConfiguration(url: url, publishableKey: key, email: "synthetic-device@example.invalid",
                                  password: "synthetic-password-for-tests", deviceId: deviceID)
    }
    private func reply(_ value: Any, status: Int = 200) throws -> SharedServerClient.Reply {
        SharedServerClient.Reply(data: try JSONSerialization.data(withJSONObject: value), status: status)
    }
    private func context(device: String? = nil) -> [String: Any] {
        ["workspace": ["id": "1a8ca76f-4530-422e-9373-6c17015c30d8", "name": "Synthetic workspace"],
         "device": ["id": device ?? deviceID, "label": "Synthetic Mac", "platform": "macos"],
         "devices": [["id": deviceID, "label": "Synthetic Mac", "platform": "macos"]]]
    }

    func testConfigurationRestrictsCredentialRecipientAndRedactsSecrets() throws {
        let valid = config()
        XCTAssertNoThrow(try valid.validate())
        for url in ["http://abcdefghijklmnopqrst.supabase.co", "https://supabase.co.evil.example",
                    "https://test.supabase.co@evil.example", "https://test.supabase.co?token=private",
                    "https://test.supabase.co/other", "https://test.supabase.co:443", "https://localhost"] {
            XCTAssertThrowsError(try config(url: url).validate())
        }
        XCTAssertThrowsError(try config(key: "sb_secret_testsecretvalue123456789").validate())
        let secretJWT = "a." + Data(#"{"role":"service_role"}"#.utf8).base64EncodedString() + ".b"
        XCTAssertThrowsError(try config(key: secretJWT).validate())
        let anonJWT = "a." + Data(#"{"role":"anon"}"#.utf8).base64EncodedString() + ".b"
        XCTAssertNoThrow(try config(key: anonJWT).validate())
        let safe = String(describing: valid) + String(reflecting: valid)
            + String(data: try JSONSerialization.data(withJSONObject: valid.safeStatus), encoding: .utf8)!
        for secret in [valid.publishableKey, valid.password, valid.email] { XCTAssertFalse(safe.contains(secret)) }
        XCTAssertThrowsError(try SharedServerConfiguration.decode(Data("malformed credential document".utf8))) { error in
            XCTAssertEqual(error as? SharedServerError, .configuration)
        }
    }

    func testMutationArgumentsRequireStableIDsAndDocumentVersion() throws {
        let input: [String: Any] = ["runId": runID, "executorDeviceId": deviceID, "request": "안드로이드 테스트"]
        let first = try SharedTools.request("shared_task_create", input)
        let repeated = try SharedTools.request("shared_task_create", input)
        XCTAssertEqual(first.method, "ppomi_create_run")
        XCTAssertEqual(first.arguments["p_run_id"] as? String, runID)
        XCTAssertEqual(first.arguments as NSDictionary, repeated.arguments as NSDictionary)
        XCTAssertThrowsError(try SharedTools.request("shared_task_create", ["request": "test", "executorDeviceId": deviceID]))
        XCTAssertThrowsError(try SharedTools.request("shared_tasks", ["limit": true]))
        XCTAssertThrowsError(try SharedTools.request("shared_tasks", ["runId": "not-a-uuid"]))

        var document: [String: Any] = ["id": "test.rule-1", "kind": "rule", "title": "테스트 규칙", "body": ["note": "synthetic"],
                                       "expectedVersion": 0, "operationId": operationID]
        let put = try SharedTools.request("shared_document_put", document)
        XCTAssertEqual(put.method, "ppomi_put_document")
        XCTAssertEqual(put.arguments["p_expected_version"] as? Int, 0)
        XCTAssertEqual(put.arguments["p_operation_id"] as? String, operationID)
        XCTAssertEqual(put.arguments["p_archived"] as? Bool, false)
        document["expectedVersion"] = true
        XCTAssertThrowsError(try SharedTools.request("shared_document_put", document))
        document["expectedVersion"] = 1
        document["archived"] = "false"
        XCTAssertThrowsError(try SharedTools.request("shared_document_put", document))
        document["archived"] = false
        document["kind"] = "code"
        XCTAssertThrowsError(try SharedTools.request("shared_document_put", document))
    }

    func testServerConflictAndMalformedResponsesNeverEchoPayload() throws {
        let sensitive = "server-body-containing-a-password-and-user-data"
        let conflict = try reply(["code": "40001", "message": sensitive], status: 409)
        XCTAssertThrowsError(try SharedServerClient.decode(conflict)) { error in
            XCTAssertEqual(error as? SharedServerError, .conflict)
            XCTAssertFalse(String(describing: error).contains(sensitive))
        }
        let failure = try reply(["code": "unknown", "message": sensitive, "details": sensitive], status: 500)
        XCTAssertThrowsError(try SharedServerClient.decode(failure)) { error in
            XCTAssertFalse(String(describing: error).contains(sensitive))
        }
        XCTAssertThrowsError(try SharedServerClient.decode(.init(data: Data("not json".utf8), status: 200)))
        XCTAssertThrowsError(try SharedServerClient.decode(.init(data: Data("null".utf8), status: 200)))
    }

    func testDeviceBindingIsCheckedBeforeCreatingTask() throws {
        var paths: [String] = []
        let client = SharedServerClient(configuration: { self.config() }) { request in
            paths.append(request.url!.path)
            if request.url!.path.contains("/auth/") {
                return try self.reply(["access_token": "synthetic-access-token", "expires_in": 3600])
            }
            return try self.reply(self.context(device: self.runID))
        }
        XCTAssertThrowsError(try client.rpc("ppomi_create_run", ["p_run_id": runID])) { error in
            XCTAssertEqual(error as? SharedServerError, .deviceMismatch)
        }
        XCTAssertEqual(paths, ["/auth/v1/token", "/rest/v1/rpc/ppomi_context"])
    }

    func testAuthenticatedRPCUsesExactArgumentsAndNeverRetriesUnknownMutationOutcome() throws {
        var paths: [String] = []
        var createBodies: [[String: Any]] = []
        let client = SharedServerClient(configuration: { self.config() }) { request in
            let path = request.url!.path
            paths.append(path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), self.config().publishableKey)
            if path.contains("/auth/") {
                XCTAssertEqual(request.url!.query, "grant_type=password")
                return try self.reply(["access_token": "synthetic-access-token", "expires_in": 3600])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-token")
            if path.hasSuffix("ppomi_context") { return try self.reply(self.context()) }
            createBodies.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
            throw NSError(domain: "potential-secret-url-in-network-error", code: 1)
        }
        let arguments = try SharedTools.request("shared_task_create", ["runId": runID, "executorDeviceId": deviceID, "request": "synthetic"])
        XCTAssertThrowsError(try client.rpc(arguments.method, arguments.arguments)) { error in
            XCTAssertEqual(error as? SharedServerError, .connection)
            XCTAssertFalse(String(describing: error).contains("potential-secret"))
        }
        XCTAssertEqual(createBodies.count, 1)
        XCTAssertEqual(createBodies.first?["p_run_id"] as? String, runID)
        XCTAssertEqual(paths.count, 3)
        // An explicit retry preserves the operation's stable server ID and the request body.
        XCTAssertThrowsError(try client.rpc(arguments.method, arguments.arguments))
        XCTAssertEqual(createBodies.count, 2)
        XCTAssertEqual(createBodies[0] as NSDictionary, createBodies[1] as NSDictionary)
        XCTAssertEqual(paths.filter { $0.contains("/auth/") }.count, 1)
    }

    func testUnconfiguredStatusDoesNotConnectAndToolsAreRegistered() throws {
        let client = SharedServerClient(configuration: { nil }) { _ in XCTFail("must not connect"); throw SharedServerError.connection }
        let status = try client.status()
        XCTAssertEqual(status["configured"] as? Bool, false)
        XCTAssertEqual(status["connected"] as? Bool, false)
        XCTAssertTrue(SharedTools.names.isSubset(of: Set(Tools.specs.map(\.name))))
        XCTAssertTrue(SharedTools.names.isSubset(of: Set(MCPServer.tools.map(\.name))))
    }
}
