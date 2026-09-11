// 개인정보 금고: Secure Enclave 키 하나. 쓰기는 공개키로(지문 없이 — 예금주 캡처·profile_save 가 채운다), 읽기는 SE 비밀키로만 하고 그 키는
// 지문(등록된 지문이 없으면 기기 암호) 뒤에서만 쓸 수 있다. UI 의 문이 아니라 하드웨어의 문: 루트·키체인 복사·다른 Mac 으로도 못 읽는다.
// 형식 ppomi-identity-v1 = [1] + 임시 P256 공개키(x963, 65바이트) + AES-GCM combined. 지문을 다시 등록하면 키가 무효가 된다(biometryCurrentSet).
import CryptoKit
import Foundation
import LocalAuthentication

final class IdentityVault: @unchecked Sendable {
    static let shared = IdentityVault()
    enum Failure: Error, LocalizedError {
        case unavailable, locked, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: return "이 Mac 에는 Secure Enclave 가 없어 개인정보를 잠글 수 없습니다."
            case .locked: return "개인정보는 지문 확인 뒤에 읽습니다."
            case .invalid: return "개인정보 금고의 자료를 풀지 못했습니다."
            }
        }
    }
    private static let service = "com.muilyzz.ppomi.identity.vault"
    private static let label = Data("ppomi-identity-v1".utf8)
    private let lock = NSLock()
    private var context: LAContext?
    private var contextAt = Date.distantPast

    /// 테스트에서는 없음(지문 대화상자를 띄우지 않는다). SE 없는 Mac 도 없음 → 프로필은 예전처럼 키체인 평문.
    var isAvailable: Bool { NSClassFromString("XCTestCase") == nil && SecureEnclave.isAvailable }
    /// 최근 5분 안에 지문을 댔는가. 그 안에서는 SE 가 다시 묻지 않는다.
    var isUnlocked: Bool { lock.withLock { context != nil && Date().timeIntervalSince(contextAt) < 300 } }

    /// 지문(없으면 기기 암호)을 한 번 받는다.
    func unlock(reason: String) async throws {
        let c = LAContext(); c.localizedCancelTitle = "취소"; c.touchIDAuthenticationAllowableReuseDuration = 300
        guard try await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw Failure.locked }
        lock.withLock { context = c; contextAt = Date() }
    }
    func relock() { lock.withLock { context = nil; contextAt = .distantPast } }

    /// 공개키로 봉인: 지문 없이 된다.
    func seal(_ plaintext: Data) throws -> Data {
        let key = try enclaveKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetric = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Self.label, sharedInfo: key.publicKey.rawRepresentation, outputByteCount: 32)
        guard let sealed = try AES.GCM.seal(plaintext, using: symmetric, authenticating: Self.label).combined else { throw Failure.invalid }
        return Data([1]) + ephemeral.publicKey.x963Representation + sealed
    }
    static func isSealed(_ data: Data) -> Bool { data.first == 1 && data.count > 66 + 28 }
    /// SE 비밀키로 연다: 최근 지문이 없으면 SE 가 시스템 대화상자로 지문을 묻고, 거절되면 locked.
    func open(_ blob: Data) throws -> Data {
        guard Self.isSealed(blob) else { throw Failure.invalid }
        let key = try enclaveKey()
        do {
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob[1..<66])
            let symmetric = try key.sharedSecretFromKeyAgreement(with: ephemeral)
                .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Self.label, sharedInfo: key.publicKey.rawRepresentation, outputByteCount: 32)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: blob[66...]), using: symmetric, authenticating: Self.label)
        } catch let error as CryptoKitError {
            if case .authenticationFailure = error { throw Failure.invalid }
            throw Failure.locked
        } catch { throw Failure.locked }
    }

    private func enclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard isAvailable else { throw Failure.unavailable }
        let context = lock.withLock { self.context }
        if let raw = SessionStore.load(Data.self, service: Self.service, account: "secure-enclave-key") {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: raw, authenticationContext: context)
        }
        let biometrics = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           biometrics ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence], &error) else { throw Failure.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        try SessionStore.save(key.dataRepresentation, service: Self.service, account: "secure-enclave-key")
        return key
    }
}
