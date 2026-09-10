// 아이패드 설정. 공개 값은 상수, 기기 ID 는 UserDefaults, 로그인 세션·기록 키는 키체인. 사람이 입력하는 것은 없다(구글 로그인 + Mac 의 QR).
import Foundation
import Security
import UIKit

enum PadSettings {
    static let supabaseURL = "https://nafutfqfbbmknzmyspus.supabase.co"
    static let publishableKey = "sb_publishable_diyhnKb7L4C1R5wt9FRoEQ_rQs8b4WX"   // 공개 키(anon). 접근 제한은 서버 RLS 몫
    static let agentEndpoint = "https://ppomi-agent.vercel.app"
    static let callbackScheme = "ppomipad"
    private static let d = UserDefaults.standard
    /// 이 설치의 기기 ID. 작업 공간 등록 때 서버에 남고, 모든 요청의 X-Ppomi-Device 가 된다.
    static var deviceID: String {
        if let v = d.string(forKey: "deviceID") { return v }
        let v = UUID().uuidString.lowercased(); d.set(v, forKey: "deviceID"); return v
    }
    static var deviceLabel: String { "iPad" }
    /// 시스템 글자 크기(Dynamic Type)를 UI 전체 배율로: 본문 17pt 가 1.
    static var uiScale: Double { min(3, max(0.75, UIFont.preferredFont(forTextStyle: .body).pointSize / 17)) }
    /// 대화·기록이 되는 상태: 로그인했고 이 기기가 작업 공간에 등록됨.
    static var configured: Bool { Session.load()?.registered == true }
}

/// 키체인 항목 하나 = Codable 값 하나.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.muilyzz.ppomi.pad", kSecAttrAccount as String: account]
    }
    static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let updates = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query(account) as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account); updates.forEach { q[$0] = $1 }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotCreateFile) }
        } else if status != errSecSuccess { throw URLError(.cannotCreateFile) }
    }
    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// 구글 로그인 세션(Supabase 토큰). registered = 이 기기가 작업 공간에 등록됨(Mac 의 QR 뒤).
struct Session: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var registered: Bool
    static func load() -> Session? { Keychain.load(Session.self, account: "session") }
    func save() throws { try Keychain.save(self, account: "session") }
    static func clear() { Keychain.delete(account: "session"); Keychain.delete(account: "vault") }
}
