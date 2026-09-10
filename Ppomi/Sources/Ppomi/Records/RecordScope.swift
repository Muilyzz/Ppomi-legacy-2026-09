import Foundation

/// A record's personal/business boundary, independent of account names, identity secrets and geometry.
/// ownerID and businessID are opaque references; a business ID is not a registration number.
struct RecordScope: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case unclassified, personal, business

        var title: String {
            switch self { case .unclassified: "미분류"; case .personal: "개인"; case .business: "사업" }
        }
    }

    var kind: Kind
    var ownerID: String?
    var businessID: String?

    init(kind: Kind, ownerID: String? = nil, businessID: String? = nil) {
        self.kind = kind; self.ownerID = ownerID; self.businessID = businessID
    }

    var label: String {
        ([kind.title] + [ownerID, businessID].compactMap { $0 }).joined(separator: " · ")
    }

    func validate() throws {
        if let ownerID { try Self.validateID(ownerID, field: "소유자 ID") }
        if let businessID { try Self.validateID(businessID, field: "사업 ID") }
        switch kind {
        case .unclassified:
            guard businessID == nil else { throw RecordScopeError.invalid("미분류 자료를 사업 ID에 자동 귀속할 수 없습니다.") }
        case .personal:
            guard ownerID != nil, businessID == nil else {
                throw RecordScopeError.invalid("개인 구분에는 소유자 ID만 지정하고 사업 ID는 넣지 않습니다.")
            }
        case .business:
            guard ownerID != nil, businessID != nil else {
                throw RecordScopeError.invalid("사업 구분에는 소유자 ID와 별도의 사업 ID가 모두 필요합니다.")
            }
        }
    }

    /// Reusing a business reference for another owner must not quietly join their records.
    static func validateConsistency(_ scopes: [RecordScope]) throws {
        var businessOwners: [String: String] = [:]
        for scope in scopes {
            try scope.validate()
            guard scope.kind == .business, let business = scope.businessID, let owner = scope.ownerID else { continue }
            if let previous = businessOwners[business], previous != owner {
                throw RecordScopeError.invalid("같은 사업 ID를 서로 다른 소유자에게 연결할 수 없습니다: \(business)")
            }
            businessOwners[business] = owner
        }
    }

    static func validateID(_ value: String, field: String) throws {
        guard !value.isEmpty, value.count <= 500,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RecordScopeError.invalid("\(field)는 앞뒤 공백·제어문자 없이 1~500자로 지정하세요.")
        }
    }
}

struct RecordScopeFilter: Equatable {
    var kind: RecordScope.Kind?
    var ownerID: String?
    var businessID: String?

    init(kind: RecordScope.Kind? = nil, ownerID: String? = nil, businessID: String? = nil) {
        self.kind = kind; self.ownerID = ownerID; self.businessID = businessID
    }

    func validate() throws {
        if let ownerID { try RecordScope.validateID(ownerID, field: "조회 소유자 ID") }
        if let businessID {
            try RecordScope.validateID(businessID, field: "조회 사업 ID")
            guard kind == nil || kind == .business else {
                throw RecordScopeError.invalid("사업 ID 조회는 사업 구분에서만 사용할 수 있습니다.")
            }
        }
    }

    func matches(_ scope: RecordScope) -> Bool {
        (kind == nil || kind == scope.kind) && (ownerID == nil || ownerID == scope.ownerID) &&
            (businessID == nil || (scope.kind == .business && businessID == scope.businessID))
    }
}

enum RecordScopeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}
