import XCTest
import CryptoKit
@testable import Ppomi

final class FamilyUpdateTests: XCTestCase {
    private var fixtureRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/updates")
    }
    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtureRoot.appendingPathComponent(name)) }
    private func configuration(key: String? = nil, channel: String = "preview") throws -> FamilyUpdateConfiguration {
        let publicKey = try key ?? String(decoding: fixture("public-key.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try FamilyUpdateConfiguration.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "endpoint": "https://updates.example.test/\(channel)/macos.json", "publicKey": publicKey, "channel": channel
        ]))
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("family-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func store(_ root: URL, config: FamilyUpdateConfiguration) -> FamilyUpdateStore {
        FamilyUpdateStore(root: root, configuration: config, platform: "macos", capabilities: ["agent.v1", "records.v1"])
    }
    private func resign(_ bytes: Data, key: P256.Signing.PrivateKey, change: (inout [String: Any]) -> Void) throws -> Data {
        let outer = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
        var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: outer["payload"]!)!) as! [String: Any]
        change(&payload)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": key.signature(for: data).derRepresentation.base64EncodedString()])
    }
    func testNodeSignedFixturesVerifyForEachPlatformAndTamperingFails() throws {
        let config = try configuration()
        for (platform, capabilities) in [("macos", Set(["agent.v1", "records.v1"])), ("ipados", Set(["records.v1"])), ("android", Set(["agent.v1"]))] {
            let pack = try FamilyUpdatePackage.verify(fixture("valid-\(platform).json"), configuration: config, platform: platform, capabilities: capabilities)
            XCTAssertEqual(pack.manifest.sequence, 42)
            XCTAssertEqual(pack.manifest.release, "fixture-test-only")
        }
        XCTAssertThrowsError(try FamilyUpdatePackage.verify(fixture("tampered.json"), configuration: config, platform: "macos", capabilities: ["agent.v1", "records.v1"]))
    }
    func testMetadataAndFileValidationEvenWithValidSignature() throws {
        let key = P256.Signing.PrivateKey()
        let config = try configuration(key: key.publicKey.x963Representation.base64EncodedString())
        let valid = try fixture("valid-macos.json")
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["platform"] = "android" }, { $0["channel"] = "family" }, { $0["bridgeVersion"] = 2 },
            { $0["minNativeBuild"] = 2 }, { $0["capabilities"] = ["unknown.v1"] }, { $0["sequence"] = true },
            { $0["sequence"] = 0 }, { $0["sequence"] = 1.5 }, { $0["surprise"] = "field" },
            { var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "../outside.js"; $0["files"] = files },
            { var files = $0["files"] as! [[String: Any]]; files.append(files[0]); $0["files"] = files },
            { var files = $0["files"] as! [[String: Any]]; files[0]["sha256"] = String(repeating: "0", count: 64); $0["files"] = files },
            { var files = $0["files"] as! [[String: Any]]; files.removeFirst(); $0["files"] = files }
        ]
        for change in mutations {
            let invalid = try resign(valid, key: key, change: change)
            XCTAssertThrowsError(try FamilyUpdatePackage.verify(invalid, configuration: config, platform: "macos", capabilities: ["agent.v1", "records.v1"]))
        }
    }
    func testStageKeepsCurrentProcessBundledAndConfirmedNextLaunchPersists() throws {
        let root = try temporaryRoot(), config = try configuration()
        let first = store(root, config: config)
        try first.beginLaunch(); try first.stage(fixture("valid-macos.json"))
        XCTAssertNil(first.selected); XCTAssertEqual(first.release, "bundled")
        let second = store(root, config: config); try second.beginLaunch()
        XCTAssertTrue(second.isTrial); XCTAssertEqual(second.release, "fixture-test-only")
        try second.markReady()
        let third = store(root, config: config); try third.beginLaunch()
        XCTAssertFalse(third.isTrial); XCTAssertEqual(third.release, "fixture-test-only")
        XCTAssertThrowsError(try third.stage(fixture("valid-macos.json")))
    }
    func testUnconfirmedLaunchReturnsToBundledAndKeepsReplayFloor() throws {
        let root = try temporaryRoot(), config = try configuration()
        let first = store(root, config: config); try first.beginLaunch(); try first.stage(fixture("valid-macos.json"))
        let trial = store(root, config: config); try trial.beginLaunch(); XCTAssertTrue(trial.isTrial)
        let recovery = store(root, config: config); try recovery.beginLaunch()
        XCTAssertNil(recovery.selected); XCTAssertEqual(recovery.release, "bundled")
        XCTAssertThrowsError(try recovery.stage(fixture("valid-macos.json")))
    }
    func testFailedNewReleaseRestoresLastConfirmedRelease() throws {
        let root = try temporaryRoot(), key = P256.Signing.PrivateKey()
        let config = try configuration(key: key.publicKey.x963Representation.base64EncodedString())
        let one = try resign(fixture("valid-macos.json"), key: key) { $0["sequence"] = 1; $0["release"] = "one" }
        let two = try resign(fixture("valid-macos.json"), key: key) { $0["sequence"] = 2; $0["release"] = "two" }
        let first = store(root, config: config); try first.beginLaunch(); try first.stage(one)
        let second = store(root, config: config); try second.beginLaunch(); try second.markReady(); try second.stage(two)
        XCTAssertEqual(second.release, "one")
        let third = store(root, config: config); try third.beginLaunch(); XCTAssertEqual(third.release, "two")
        try third.markFailed()
        let recovery = store(root, config: config); try recovery.beginLaunch(); XCTAssertEqual(recovery.release, "one")
        XCTAssertThrowsError(try recovery.stage(two))
    }
    func testCorruptInstalledBytesOrSymlinkCannotRun() throws {
        for symlink in [false, true] {
            let root = try temporaryRoot(), config = try configuration()
            let first = store(root, config: config); try first.beginLaunch(); try first.stage(fixture("valid-macos.json"))
            let entry = root.appendingPathComponent("releases/42-fixture-test-only/files/Agent/app.js")
            if symlink {
                try FileManager.default.removeItem(at: entry)
                let other = root.appendingPathComponent("outside.js"); try Data("evil".utf8).write(to: other)
                try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: other)
            } else { try Data("evil".utf8).write(to: entry) }
            let next = store(root, config: config); try next.beginLaunch()
            XCTAssertNil(next.selected)
        }
    }
    func testConfigRejectsCredentialsHTTPAndBadKey() throws {
        let key = try String(decoding: fixture("public-key.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for endpoint in ["http://example.test/preview/macos.json", "https://user:password@example.test/preview/macos.json", "https://example.test/preview/macos.json?token=secret"] {
            let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "endpoint": endpoint, "publicKey": key, "channel": "preview"])
            XCTAssertThrowsError(try FamilyUpdateConfiguration.decode(data))
        }
        XCTAssertNotEqual(try configuration().namespace(platform: "macos"), try configuration(channel: "family").namespace(platform: "macos"))
        for path in ["../a.js", "/a.js", "a\\b.js", "a/%2e.js", "a.js/../b.js", "a.dylib", "a.js?b", "a.js\n"] { XCTAssertFalse(FamilyUpdatePackage.safePath(path)) }
        XCTAssertTrue(FamilyUpdatePackage.safePath("icons/Logo.SVG"))
    }
    func testRecoveryShowsConfirmedReleaseBeforeAnotherPendingCandidate() throws {
        let root = try temporaryRoot(), key = P256.Signing.PrivateKey()
        let config = try configuration(key: key.publicKey.x963Representation.base64EncodedString())
        func pack(_ number: Int) throws -> Data {
            try resign(fixture("valid-macos.json"), key: key) { $0["sequence"] = number; $0["release"] = "release-\(number)" }
        }
        let first = store(root, config: config); try first.beginLaunch(); try first.stage(pack(1))
        let good = store(root, config: config); try good.beginLaunch(); try good.markReady(); try good.stage(pack(2))
        let broken = store(root, config: config); try broken.beginLaunch()
        let pinned = try XCTUnwrap(broken.selected)
        try broken.markFailed(); try broken.stage(pack(3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.appendingPathComponent("Agent/app.js").path))
        XCTAssertThrowsError(try broken.markReady())
        let recovery = store(root, config: config); try recovery.beginLaunch()
        XCTAssertEqual(recovery.release, "release-1"); XCTAssertFalse(recovery.isTrial)
        let next = store(root, config: config); try next.beginLaunch()
        XCTAssertEqual(next.release, "release-3"); XCTAssertTrue(next.isTrial)
    }
    func testUnsignedExtraFileInvalidatesInstalledPackage() throws {
        let root = try temporaryRoot(), config = try configuration()
        let first = store(root, config: config); try first.beginLaunch(); try first.stage(fixture("valid-macos.json"))
        let extra = root.appendingPathComponent("releases/42-fixture-test-only/files/Agent/unsigned.js")
        try Data("unsigned code".utf8).write(to: extra)
        let next = store(root, config: config); try next.beginLaunch()
        XCTAssertNil(next.selected)
    }
    func testHeadlessJobsCannotConsumeGUITrialOrStartDownload() {
        for flag in ["--mcp", "--snapshot", "--verify-records", "--migrate-records", "--configure-shared", "--configure-agent-endpoint", "--voice"] {
            XCTAssertFalse(FamilyUpdateRuntime.permitsUpdates(arguments: ["Ppomi", flag]))
        }
        XCTAssertTrue(FamilyUpdateRuntime.permitsUpdates(arguments: ["Ppomi"]))
        XCTAssertTrue(FamilyUpdateRuntime.permitsUpdates(arguments: ["Ppomi", "--kiosk"]))
    }
}
