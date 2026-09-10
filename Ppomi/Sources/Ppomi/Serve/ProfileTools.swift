import Foundation

/// Conversation is the registration path; tool replies contain presence flags, never the stored identity values.
enum ProfileTools {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func validateKeys(_ a: [String: Any], allowed: Set<String>) throws {
        guard Set(a.keys).isSubset(of: allowed) else { throw Failure(message: "지원하지 않는 개인정보 필드가 있습니다. 이름·생년월일·휴대폰·통신사·상호·사업자등록번호만 등록할 수 있습니다.") }
    }

    static func string(_ a: [String: Any], _ key: String, default fallback: String? = nil) throws -> String? {
        guard let value = a[key] else { return fallback }
        if value is NSNull { return nil }
        guard let value = value as? String else { throw Failure(message: "프로필 필드는 문자열이어야 합니다.") }
        return value
    }

    static func status(_ profile: IdentityProfile) -> [String: Any] {
        let banks: [[String: Any]] = (profile.bankProfiles ?? [:]).sorted { $0.key < $1.key }.map { bankID, bank in
            ["bank_id": bankID,
             "registered": ["customer_name": bank.customerName != nil, "account_number": bank.accountNumber != nil]]
        }
        return ["profile_id": profile.id, "label_hint": String(profile.label.prefix(1)) + String(repeating: "•", count: min(12, max(0, profile.label.count - 1))),
         "registered": ["name": profile.name != nil, "birth_date": profile.birthDate != nil,
                        "phone": profile.phone != nil, "carrier": profile.carrier != nil,
                        "business_name": profile.businessName != nil,
                        "business_registration_number": profile.businessRegistrationNumber != nil],
         "bank_profiles": banks]
    }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func save(_ a: [String: Any], store: IdentityProfileStore) throws -> String {
        try validateKeys(a, allowed: ["profile_id", "label", "name", "birth_date", "phone", "carrier", "business_name", "business_registration_number"])
        guard let id = try string(a, "profile_id", default: "self"),
              a.keys.contains(where: { $0 != "profile_id" }) else { throw Failure(message: "등록하거나 바꿀 기본정보가 필요합니다.") }
        var profile = try store.profile(id: id) ?? IdentityProfile(id: id, label: id == "self" ? "나" : id)
        if a["label"] != nil { profile.label = try string(a, "label") ?? "" }
        if a["name"] != nil { profile.name = try string(a, "name") }
        if a["birth_date"] != nil { profile.birthDate = try string(a, "birth_date") }
        if a["phone"] != nil { profile.phone = try string(a, "phone") }
        if a["carrier"] != nil { profile.carrier = try string(a, "carrier") }
        if a["business_name"] != nil { profile.businessName = try string(a, "business_name") }
        if a["business_registration_number"] != nil { profile.businessRegistrationNumber = try string(a, "business_registration_number") }
        profile = try profile.validated()
        try store.save(profile)
        return try json(["saved": true, "profile": status(profile),
                         "notice": "키체인에 저장했습니다. 저장한 값은 앱에서 확인·수정하거나 profile_fill로 입력할 수 있습니다."])
    }

    static func list(_ a: [String: Any], store: IdentityProfileStore) throws -> String {
        try validateKeys(a, allowed: ["profile_id"])
        let profiles: [IdentityProfile]
        if let id = try string(a, "profile_id") { profiles = try store.profile(id: id).map { [$0] } ?? [] }
        else { profiles = try store.list() }
        return try json(["profiles": profiles.map(status)])
    }

    static func remove(_ a: [String: Any], store: IdentityProfileStore) throws -> String {
        try validateKeys(a, allowed: ["profile_id"])
        guard let id = try string(a, "profile_id"), !id.isEmpty else { throw Failure(message: "삭제할 profile_id를 지정해 주세요.") }
        try store.delete(id: id)
        return try json(["deleted": true])
    }
}
