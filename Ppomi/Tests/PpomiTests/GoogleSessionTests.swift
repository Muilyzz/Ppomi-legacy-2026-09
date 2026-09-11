import XCTest
@testable import Ppomi

final class GoogleSessionTests: XCTestCase {
    private let deviceID = "c8b22c49-3137-45f6-ad83-95866c687c63"

    private func account(_ token: String = "synthetic-google-access", expiresIn: TimeInterval = 3600) -> MacSession {
        MacSession(accessToken: token, refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(expiresIn),
                   registered: true, email: "synthetic@example.invalid", name: "합성 사용자", avatarURL: "https://example.invalid/avatar")
    }

    func testGoogleRequestUsesNativeSessionAndDeviceWithoutPasswordLogin() throws {
        let session = account()
        var requests: [URLRequest] = []
        let client = SharedServerClient(configuration: { XCTFail("Google login must not use legacy credentials"); return nil },
                                        session: { session }, deviceID: { self.deviceID }) { request in
            requests.append(request)
            return .init(data: Data(#"{"ok":true}"#.utf8), status: 200)
        }
        XCTAssertTrue(client.isConfigured)
        let reply = try client.agentRequest(endpoint: PpomiServer.agentEndpoint, path: "/v1/responses", body: [:])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/responses")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer " + session.accessToken)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Ppomi-Device"), deviceID)
        let display = String(describing: client.authentication) + String(describing: reply)
        for privateValue in [session.accessToken, session.refreshToken, session.email, session.avatarURL!] {
            XCTAssertFalse(display.contains(privateValue))
        }
        XCTAssertEqual(client.authentication["signedIn"] as? Bool, true)
        XCTAssertEqual(client.authentication["displayName"] as? String, session.name)
    }

    func testAccountWindowChangesReplaceCachedTokenAndLogoutCannotReuseIt() throws {
        var session: MacSession? = account("synthetic-first-access")
        var tokens: [String] = []
        let client = SharedServerClient(configuration: { nil }, session: { session }, deviceID: { self.deviceID }) { request in
            tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return .init(data: Data("{}".utf8), status: 200)
        }
        _ = try client.agentRequest(endpoint: PpomiServer.agentEndpoint, path: "/v1/responses", body: [:])
        session = account("synthetic-second-access") // another process wrote the shared Keychain
        _ = try client.agentRequest(endpoint: PpomiServer.agentEndpoint, path: "/v1/responses", body: [:])
        XCTAssertEqual(tokens, ["Bearer synthetic-first-access", "Bearer synthetic-second-access"])
        session = nil
        XCTAssertFalse(client.isConfigured)
        XCTAssertEqual(client.authentication["signedIn"] as? Bool, false)
        XCTAssertNil(client.authentication["displayName"])
        XCTAssertThrowsError(try client.agentRequest(endpoint: PpomiServer.agentEndpoint, path: "/v1/responses", body: [:])) {
            XCTAssertEqual($0 as? SharedServerError, .unconfigured)
        }
        XCTAssertEqual(tokens.count, 2)
    }

    func testExpiredSessionIsSavedBeforeMutationAndFailureIsNotReplayed() throws {
        var session = account(expiresIn: -60)
        var refreshed = 0, saved = 0, sent = 0
        let client = SharedServerClient(configuration: { nil }, session: { session }, deviceID: { self.deviceID }, refreshSession: { value in
            XCTAssertEqual(value, "synthetic-refresh"); refreshed += 1
            return SupabaseAuth.Tokens(access: "synthetic-new-access", refresh: "synthetic-new-refresh", expiresAt: Date().addingTimeInterval(3600), claims: [:])
        }, saveSession: { value in session = value; saved += 1 }) { request in
            XCTAssertEqual(saved, 1)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-new-access")
            sent += 1
            return .init(data: Data("{}".utf8), status: 401)
        }
        XCTAssertThrowsError(try client.agentRequest(endpoint: PpomiServer.agentEndpoint, path: "/v1/responses", body: [:])) {
            XCTAssertEqual($0 as? SharedServerError, .authentication)
        }
        XCTAssertEqual(refreshed, 1); XCTAssertEqual(saved, 1); XCTAssertEqual(sent, 1)
        XCTAssertEqual(session.refreshToken, "synthetic-new-refresh")
    }

    func testPendingDevicesAreApprovedByExplicitRPCBeforeAnyKeyExchange() throws {
        let session = account()
        let windows = "7f4a1c2e-3b5d-4e6f-8a9b-0c1d2e3f4a5b"
        var calls: [(name: String, body: String)] = []
        let client = SharedServerClient(configuration: { nil }, session: { session }, deviceID: { self.deviceID }) { request in
            let name = request.url?.lastPathComponent ?? ""
            calls.append((name, String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
            switch name {
            case "ppomi_devices_pending":
                return .init(data: Data(#"[{"id":"\#(windows.uppercased())","label":"Windows","platform":"windows"},{"id":"not-a-device","label":"x","platform":"web"}]"#.utf8), status: 200)
            case "ppomi_device_approve":
                return .init(data: Data(#"{"device":{"id":"\#(windows)","label":"Windows","platform":"windows","approved":true}}"#.utf8), status: 200)
            default:
                return .init(data: Data(#"{"found":false}"#.utf8), status: 200)   // no key on this test Mac: nothing to wrap, nothing to receive
            }
        }
        let pending = try GoogleAccount.pendingDevices(client)
        XCTAssertEqual(pending.map(\.id), [windows])   // malformed rows are dropped, IDs are normalized
        XCTAssertEqual(pending.first?.platformName, "Windows")
        try GoogleAccount.approve(windows, client)
        XCTAssertEqual(calls.map(\.name).prefix(2), ["ppomi_devices_pending", "ppomi_device_approve"])
        XCTAssertTrue(calls[1].body.contains(windows))
        XCTAssertEqual(calls.count, 3)   // approval is followed by exactly one key-exchange round
        XCTAssertThrowsError(try GoogleAccount.approve("not-a-device", client))
        XCTAssertEqual(calls.count, 3)   // an invalid ID never reaches the server
    }

    func testLegacyConfigurationDoesNotMeanGoogleSignedIn() {
        let client = SharedServerClient(configuration: {
            SharedServerConfiguration(url: "https://abcdefghijklmnopqrst.supabase.co", publishableKey: "sb_publishable_syntheticpublicvalue123456789",
                                      email: "synthetic@example.invalid", password: "synthetic-password", deviceId: self.deviceID)
        }, session: { nil }, transport: { _ in XCTFail("Presentation must not use the network"); return .init(data: Data(), status: 500) })
        XCTAssertTrue(client.isConfigured)
        XCTAssertEqual(client.authentication["signedIn"] as? Bool, false)
    }
}

@MainActor
final class AgentExecutorGoogleTests: XCTestCase {
    func testFreshInstallationUsesPublicEndpointAndInjectedGoogleState() async throws {
        let suite = "ppomi-auth-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = MacSession(accessToken: "synthetic-access-token", refreshToken: "synthetic-refresh-token", expiresAt: Date().addingTimeInterval(3600),
                                 registered: true, email: "synthetic@example.invalid", name: "합성", avatarURL: nil)
        let server = SharedServerClient(configuration: { nil }, session: { session }, transport: { _ in
            XCTFail("Bootstrap must not make an HTTP request"); return .init(data: Data(), status: 500)
        })
        let executor = AgentExecutor(defaults: defaults, server: server, mcp: nil)
        let reply: [String: Any] = await withCheckedContinuation { continuation in
            executor.receive(["id": UUID().uuidString, "method": "bootstrap", "args": [:]]) { continuation.resume(returning: $0) }
        }
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["endpoint"] as? String, PpomiServer.agentEndpoint)
        XCTAssertEqual(result["configured"] as? Bool, true)
        XCTAssertEqual((result["executor"] as? [String: Any])?["googleSignIn"] as? Bool, true)
        XCTAssertEqual((result["authentication"] as? [String: Any])?["signedIn"] as? Bool, true)
        let text = String(describing: result)
        for privateValue in [session.accessToken, session.refreshToken, session.email] { XCTAssertFalse(text.contains(privateValue)) }
    }
}
