import Foundation

/// A trusted chat card receives only presence flags. Values travel from that card straight to Keychain.
/// Tokens are memory-only, short-lived and invalidated with the native chat session.
final class AgentBankProfileRequests: @unchecked Sendable {
    enum Failure: LocalizedError {
        case invalid, expired
        var errorDescription: String? {
            switch self {
            case .invalid: return "은행정보 입력 요청을 확인할 수 없습니다. 새 입력 카드를 열어 주세요."
            case .expired: return "은행정보 입력 요청이 종료됐습니다. 새 입력 카드를 열어 주세요."
            }
        }
    }
    private struct Request {
        var id: String
        var profileID: String
        var bankID: String
        var fields: Set<String>
        var expiresAt: Date
    }
    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    private let store: IdentityProfileStore
    private let now: () -> Date

    init(store: IdentityProfileStore = .shared, now: @escaping () -> Date = Date.init) {
        self.store = store; self.now = now
    }

    func invalidate() { lock.withLock { requests.removeAll() } }

    func begin(_ args: [String: Any]) throws -> [String: Any] {
        guard Set(args.keys).isSubset(of: ["profile_id", "bank_id"]),
              let profileID = args["profile_id"] as? String,
              let bankID = args["bank_id"] as? String, bankID == "kb" else { throw Failure.invalid }
        let id = try IdentityProfile.normalizedID(profileID)
        return try lock.withLock {
            requests = requests.filter { $0.value.expiresAt > now() }
            guard requests.count < 8 else { throw Failure.invalid }
            let profile = try store.profile(id: id) ?? IdentityProfile(id: id, label: id == "self" ? "나" : id)
            let flags = Self.registered(profile.bankProfiles?[bankID])
            let request = Request(id: UUID().uuidString, profileID: id, bankID: bankID,
                                  fields: Set(flags.filter { !$0.value }.map(\.key)),
                                  expiresAt: now().addingTimeInterval(600))
            requests[request.id] = request
            return ["request_id": request.id, "profile_id": id, "bank_id": bankID,
                    "label_hint": String(profile.label.prefix(1)) + (profile.label.count > 1 ? "•" : ""),
                    "registered": flags]
        }
    }

    func submit(_ args: [String: Any]) throws -> [String: Any] {
        guard Set(args.keys) == ["request_id", "values"],
              let id = args["request_id"] as? String,
              let values = args["values"] as? [String: String],
              values.values.allSatisfy({ $0.utf8.count <= 1024 }) else { throw Failure.invalid }
        return try lock.withLock {
            guard let request = requests[id], request.expiresAt > now() else {
                requests.removeValue(forKey: id); throw Failure.expired
            }
            guard Set(values.keys) == request.fields,
                  values.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Failure.invalid }
            // A concurrent settings edit must never be overwritten by an older chat card.
            let profile = try store.updateBankProfile(id: request.profileID, bankID: request.bankID,
                                                      values: values, onlyMissing: true)
            requests.removeValue(forKey: id)
            return ["saved": true, "profile_id": request.profileID, "bank_id": request.bankID,
                    "registered": Self.registered(profile.bankProfiles?[request.bankID])]
        }
    }

    func cancel(_ args: [String: Any]) throws -> [String: Any] {
        guard Set(args.keys) == ["request_id"], let id = args["request_id"] as? String else { throw Failure.invalid }
        lock.withLock { _ = requests.removeValue(forKey: id) }
        return ["cancelled": true]
    }

    private static func registered(_ bank: IdentityBankProfile?) -> [String: Bool] {
        ["customer_name": bank?.customerName != nil, "account_number": bank?.accountNumber != nil]
    }
}
