import XCTest
@testable import Ppomi

final class SecretsTreeTests: XCTestCase {
    private var fixture: Any { SecretsVault.fixture() }

    func testFixtureIsSyntheticProbeOnly() throws {
        let blob = try XCTUnwrap(SecretsTree.asObject(fixture))
        XCTAssertEqual(blob["synthetic"] as? Bool, true)
        XCTAssertEqual(blob["source"] as? String, "storybook-probe")
        let items = try XCTUnwrap(SecretsTree.asObject(blob["items"]))
        XCTAssertEqual(items["ppomi/kb-star-biz/account"] as? String, "001234567890")
        let token = SecretsTree.atPath(fixture, ["items", "ppomi/probe/session-blob", "payload", "token"]) as? String
        XCTAssertEqual(token, "probe-not-a-real-token")
    }

    func testLast4OnlyForAccountKeyedLeaves() {
        for key in ["account", "accountNumber", "ACCOUNT_NUMBER", "account-no", "acct", "계좌", "계좌번호",
                    "ppomi/kb-probe/account", "bank.accountNumber"] {
            XCTAssertEqual(SecretsTree.maskLeaf(path: [key], value: "001234567890"), "****7890", key)
            XCTAssertEqual(SecretsTree.chips(of: [key: "001234567890"]).map(\.chip), ["****7890"], key)
        }
        for key in ["accountName", "accounts", "account-holder", "subaccountish", "token"] {
            XCTAssertEqual(SecretsTree.maskLeaf(path: [key], value: "001234567890"), "••••", key)
            XCTAssertTrue(SecretsTree.chips(of: [key: "001234567890"]).isEmpty, key)
        }
        XCTAssertEqual(SecretsTree.keyToken(["items", "ppomi/kb-probe/account"]), "account")
        XCTAssertEqual(SecretsTree.maskLeaf(path: ["account"], value: "12"), "••••")
        let custom: [String: Any] = ["iban": "DE00 1234 5678 9012", "account": "001234567890"]
        XCTAssertEqual(SecretsTree.maskLeaf(path: ["iban"], value: custom["iban"]!, accountKeys: ["iban"]), "****9012")
        XCTAssertEqual(SecretsTree.maskLeaf(path: ["account"], value: custom["account"]!, accountKeys: ["iban"]), "••••")
        XCTAssertEqual(SecretsTree.chips(of: custom, accountKeys: ["iban"]).map { [$0.key, $0.chip] }, [["iban", "****9012"]])
    }

    func testNonAccountDigitShapesStayFullyMasked() {
        let shapes: [String: Any] = [
            "otp": "123456", "pin": "654321", "phone": "010-1234-5678", "rrn": "900101-1234567",
            "bizno": "123-45-67890", "card": "4111 1111 1111 1111", "count": 123456,
            "accountName": "합성 통장 1234", "note": "1234 5678 90",
        ]
        for (key, value) in shapes {
            XCTAssertFalse(SecretsTree.accountish(path: [key], value: value), key)
            XCTAssertEqual(SecretsTree.maskLeaf(path: [key], value: value), "••••", key)
            XCTAssertEqual(SecretsTree.display(path: [key], value: value, unlocked: false), "••••", key)
        }
        XCTAssertTrue(SecretsTree.chips(of: shapes).isEmpty)
    }

    func testFixtureChipsMatchAccountLeavesOnly() {
        XCTAssertEqual(SecretsTree.last4("001234567890"), "****7890")
        XCTAssertTrue(SecretsTree.accountish(path: ["accountNumber"], value: "009876543210"))
        XCTAssertTrue(SecretsTree.accountish(path: ["ppomi/kb-star-biz/account"], value: "001234567890"))
        XCTAssertFalse(SecretsTree.accountish(path: ["pins"], value: "0000"))
        XCTAssertFalse(SecretsTree.accountish(path: ["token"], value: "probe-not-a-real-token"))
        XCTAssertEqual(SecretsTree.chips(of: fixture).map { [$0.key, $0.chip] }, [
            ["ppomi/kb-star-biz/account", "****7890"],
            ["ppomi/probe/json-string", "****3210"],
        ])
    }

    func testJSONStringUnwrapsAndAtPathReadsLeaves() {
        XCTAssertEqual((SecretsTree.atPath(SecretsTree.unwrap("{\"a\":1}"), ["a"]) as? NSNumber)?.intValue, 1)
        XCTAssertEqual(SecretsTree.unwrap("not-json") as? String, "not-json")
        XCTAssertEqual(SecretsTree.atPath(fixture, ["items", "ppomi/probe/json-string", "bank"]) as? String, "kb-probe")
        XCTAssertEqual(SecretsTree.atPath(fixture, ["items", "ppomi/kb-star-biz/account"]) as? String, "001234567890")
    }

    func testLockedDisplayHidesPlaintextAndUnlockedShowsIt() {
        var locked = ""
        var opened = ""
        SecretsTree.eachLeaf(fixture) { path, leaf in
            locked += SecretsTree.display(path: path, value: leaf, unlocked: false)
            opened += SecretsTree.display(path: path, value: leaf, unlocked: true)
        }
        XCTAssertFalse(locked.contains("001234567890"))
        XCTAssertFalse(locked.contains("probe-not-a-real-token"))
        XCTAssertFalse(locked.contains("009876543210"))
        XCTAssertTrue(locked.contains("****7890"))
        XCTAssertTrue(locked.contains("••••"))
        XCTAssertTrue(opened.contains("001234567890"))
        XCTAssertTrue(opened.contains("probe-not-a-real-token"))
        XCTAssertFalse(SecretsTree.containsPlaintext(locked, from: fixture))
    }

    func testDepthCapStopsAt32() {
        var deep: Any = "leaf"
        for _ in 0..<40 { deep = ["d": deep] }
        var sawLeaf = false
        var maxPath = 0
        SecretsTree.eachLeaf(deep) { path, leaf in
            maxPath = max(maxPath, path.count)
            if SecretsTree.stringish(leaf) == "leaf" { sawLeaf = true }
        }
        XCTAssertFalse(sawLeaf)
        XCTAssertLessThan(maxPath, SecretsTree.maxDepth)
        var arr: Any = []
        for _ in 0..<80 { arr = [arr] }
        XCTAssertNoThrow(SecretsTree.chips(of: arr))
    }

    func testLiveSnapshotPrefersInjectedVaultAndFallsBackToFixture() {
        let live = SecretsVault.snapshot(unlocked: true, liveItems: ["ppomi/kb-star-biz/account": "001234567890"])
        let object = SecretsTree.asObject(live)
        XCTAssertEqual(object?["synthetic"] as? Bool, false)
        XCTAssertEqual(object?["source"] as? String, "ppomi-secrets")
        XCTAssertEqual(SecretsTree.atPath(live, ["items", "ppomi/kb-star-biz/account"]) as? String, "001234567890")
        let fallback = SecretsVault.snapshot(unlocked: false, liveItems: [:])
        XCTAssertEqual(SecretsTree.asObject(fallback)?["source"] as? String, "storybook-probe")
    }

    @MainActor func testShowSecretsOpensTheStatusSecretsTab() {
        let state = AppState()
        state.show(.secrets)
        XCTAssertEqual(state.tab, .secrets)
        XCTAssertEqual(state.recordsFocusRequest, 1)
        XCTAssertEqual(AppState.Tab.secrets.title, "상태·비밀")
    }
}

private extension AppState.Tab {
    var title: String {
        switch self {
        case .timeline: "타임라인"
        case .evidence: "증빙"
        case .accounting: "분개"
        case .playbooks: "절차"
        case .health: "건강"
        case .spatial: "3D"
        case .secrets: "상태·비밀"
        }
    }
}
