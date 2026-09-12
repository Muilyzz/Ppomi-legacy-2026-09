// Local dump for 「상태·비밀」. Prefer ppomi-secrets Keychain (account `ppomi`, service = key).
// Fixture fallback is the Storybook probe blob. Copy/display stay on this Mac.
import Foundation
import LocalAuthentication
import Security

enum SecretsVault {
    /// Storybook `secrets-fixture.json` — synthetic probe only.
    static let fixtureJSON = Data(#"""
    {
      "synthetic": true,
      "source": "storybook-probe",
      "note": "Fake Keychain dump. Probe values only — not a real secret export.",
      "items": {
        "ppomi/kb-star-biz/account": "001234567890",
        "ppomi/probe/session-blob": {
          "label": "합성 세션",
          "payload": {
            "accountName": "합성 테스트 통장",
            "token": "probe-not-a-real-token",
            "pins": ["0000"],
            "nested": {"ok": true, "count": 2}
          }
        },
        "ppomi/probe/json-string": "{\"accountNumber\":\"009876543210\",\"bank\":\"kb-probe\"}"
      }
    }
    """#.utf8)

    static func fixture() -> Any {
        (try? JSONSerialization.jsonObject(with: fixtureJSON)) ?? ["synthetic": true, "items": [:]]
    }

    /// Live Keychain items (ppomi-secrets). Empty → fixture.
    /// MZZ-49: E2E vault sync (Mac↔Win plaintext) hooks here — not implemented in this PR.
    static func snapshot(unlocked: Bool, liveItems: [String: String]? = nil) -> Any {
        let items = liveItems ?? Self.liveItems(unlocked: unlocked)
        if items.isEmpty { return fixture() }
        return ["synthetic": false, "source": "ppomi-secrets", "items": items]
    }

    static func liveItems(unlocked: Bool) -> [String: String] {
        guard NSClassFromString("XCTestCase") == nil else { return [:] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "ppomi",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return [:] }
        var items: [String: String] = [:]
        for row in rows {
            guard let key = row[kSecAttrService as String] as? String, key.hasPrefix("ppomi/") else { continue }
            if unlocked || SecretsTree.isAccountKey([key]) {
                items[key] = read(service: key) ?? ""
            } else {
                items[key] = ""
            }
        }
        return items
    }

    private static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "ppomi",
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}

enum SecretsGate {
    enum Failure: Error { case locked }

    static func unlock(reason: String = "로컬 시크릿을 보려면 확인이 필요합니다") async throws {
        if NSClassFromString("XCTestCase") != nil { return }
        let context = LAContext()
        context.localizedCancelTitle = "취소"
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw Failure.locked
        }
    }
}
