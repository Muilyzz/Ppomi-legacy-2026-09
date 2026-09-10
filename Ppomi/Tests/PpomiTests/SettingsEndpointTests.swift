import XCTest
@testable import Ppomi

final class SettingsEndpointTests: XCTestCase {
    func testSaveStoresNormalizedURLAndRejectsGarbage() throws {
        let suite = "ppomi-settings-endpoint-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notified = expectation(forNotification: AgentNativePolicy.endpointChanged, object: nil)

        XCTAssertEqual(try AgentNativePolicy.save(endpoint: "https://example.invalid/Agent/", defaults: defaults).absoluteString,
                       "https://example.invalid/Agent/")
        XCTAssertEqual(defaults.string(forKey: AgentNativePolicy.endpointPreference), "https://example.invalid/Agent/")
        wait(for: [notified], timeout: 1)

        for garbage in ["", "주소", "http://example.invalid", "https://", "https://example.invalid?x=1", "https://a b"] {
            XCTAssertThrowsError(try AgentNativePolicy.save(endpoint: garbage, defaults: defaults), garbage)
            XCTAssertEqual(defaults.string(forKey: AgentNativePolicy.endpointPreference), "https://example.invalid/Agent/")
        }
    }
}
