import CryptoKit
import XCTest
@testable import Ppomi

final class KeyWrapTests: XCTestCase {
    /// 받는 기기만 푼다: 다른 기기의 비밀키, 다른 키 ID, 손댄 바이트는 전부 실패.
    func testWrapRoundTripAndTamper() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey(), other = Curve25519.KeyAgreement.PrivateKey()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let workspace = UUID().uuidString.lowercased(), keyID = UUID().uuidString.lowercased()
        let blob = try KeyWrap.wrap(key, for: recipient.publicKey.rawRepresentation, workspaceID: workspace, keyID: keyID)
        XCTAssertEqual(blob.count, 92)
        XCTAssertEqual(try KeyWrap.unwrap(blob, with: recipient, workspaceID: workspace, keyID: keyID), key)
        XCTAssertThrowsError(try KeyWrap.unwrap(blob, with: other, workspaceID: workspace, keyID: keyID))
        XCTAssertThrowsError(try KeyWrap.unwrap(blob, with: recipient, workspaceID: workspace, keyID: UUID().uuidString))
        var tampered = blob; tampered[40] ^= 1
        XCTAssertThrowsError(try KeyWrap.unwrap(tampered, with: recipient, workspaceID: workspace, keyID: keyID))
    }
}
