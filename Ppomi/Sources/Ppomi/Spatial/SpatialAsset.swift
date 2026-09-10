import Foundation

/// Geometry is a description linked to an entity, never an accounting movement or valuation.
struct SpatialArchive: Codable, Equatable {
    var formatVersion: Int = 1
    var unit: String = "m"
    var assets: [SpatialAsset] = []
}

struct SpatialAsset: Codable, Equatable, Identifiable {
    var id: String
    var entityID: String
    var title: String
    /// Old unverified references are retained for compatibility, never promoted to validated links.
    var accountIDs: [String] = []
    var isSynthetic: Bool = false
    var ownerships: [SpatialOwnership] = []
    var usages: [SpatialUsage] = []
    var parts: [SpatialPart]

    init(id: String, entityID: String, title: String, accountIDs: [String] = [], isSynthetic: Bool = false,
         ownerships: [SpatialOwnership] = [], usages: [SpatialUsage] = [], parts: [SpatialPart]) {
        self.id = id; self.entityID = entityID; self.title = title; self.accountIDs = accountIDs
        self.isSynthetic = isSynthetic; self.ownerships = ownerships; self.usages = usages; self.parts = parts
    }

    private enum CodingKeys: String, CodingKey { case id, entityID, title, accountIDs, isSynthetic, ownerships, usages, parts }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        entityID = try values.decode(String.self, forKey: .entityID)
        title = try values.decode(String.self, forKey: .title)
        accountIDs = try values.decodeIfPresent([String].self, forKey: .accountIDs) ?? []
        isSynthetic = try values.decodeIfPresent(Bool.self, forKey: .isSynthetic) ?? false
        ownerships = try values.decodeIfPresent([SpatialOwnership].self, forKey: .ownerships) ?? []
        usages = try values.decodeIfPresent([SpatialUsage].self, forKey: .usages) ?? []
        parts = try values.decode([SpatialPart].self, forKey: .parts)
    }

    var effectiveScopes: [RecordScope] { usages.isEmpty ? [.init(kind: .unclassified)] : usages.map(\.scope) }
    func matches(_ filter: RecordScopeFilter) -> Bool { effectiveScopes.contains { filter.matches($0) } }
}

/// Legal/economic ownership and actual use are independent source-backed facts.
struct SpatialOwnership: Codable, Equatable, Identifiable {
    var ownerID: String
    var shareBasisPoints: Int?
    var sourceRecordID: String
    var note: String
    var id: String { ownerID }
}

struct SpatialUsage: Codable, Equatable, Identifiable {
    var id: String
    var scope: RecordScope
    var allocationBasisPoints: Int?
    var sourceRecordID: String
    var note: String
    var accountLinks: [SpatialAccountLink] = []

    init(id: String, scope: RecordScope, allocationBasisPoints: Int? = nil, sourceRecordID: String,
         note: String, accountLinks: [SpatialAccountLink] = []) {
        self.id = id; self.scope = scope; self.allocationBasisPoints = allocationBasisPoints
        self.sourceRecordID = sourceRecordID; self.note = note; self.accountLinks = accountLinks
    }

    private enum CodingKeys: String, CodingKey { case id, scope, allocationBasisPoints, sourceRecordID, note, accountLinks }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        scope = try values.decode(RecordScope.self, forKey: .scope)
        allocationBasisPoints = try values.decodeIfPresent(Int.self, forKey: .allocationBasisPoints)
        sourceRecordID = try values.decode(String.self, forKey: .sourceRecordID)
        note = try values.decode(String.self, forKey: .note)
        accountLinks = try values.decodeIfPresent([SpatialAccountLink].self, forKey: .accountLinks) ?? []
    }
}

struct SpatialAccountLink: Codable, Equatable, Hashable {
    var bookID: String
    var accountID: String
}

struct SpatialPart: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// Local horizontal coordinates, in meters. Do not repeat the first point at the end.
    var footprint: [SpatialPoint]
    var height: Double
    var elevation: Double
    /// Covers all supplied dimensions. Mixed-source geometry uses the least certain category.
    var provenance: SpatialProvenance
}

struct SpatialPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct SpatialProvenance: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case measured, estimated, schematic
        var title: String {
            switch self { case .measured: return "실측"; case .estimated: return "추정"; case .schematic: return "개략" }
        }
    }
    var kind: Kind
    var sourceRecordID: String
    var note: String
}

enum SpatialError: LocalizedError {
    case invalid(String), conflict(String)
    var errorDescription: String? {
        switch self { case .invalid(let message), .conflict(let message): return message }
    }
}

enum SpatialGeometry {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumAssets = 100
    static let maximumParts = 100
    static let maximumVertices = 256
    static let maximumTotalVertices = 20_000
    private static let epsilon = 0.00000001

    static func validate(_ archive: SpatialArchive) throws {
        guard archive.formatVersion == 1 else { throw SpatialError.invalid("지원하지 않는 공간 자료 버전입니다.") }
        guard archive.unit == "m" else { throw SpatialError.invalid("공간 치수 단위는 미터(m)여야 합니다.") }
        guard archive.assets.count <= maximumAssets else { throw SpatialError.invalid("공간 자료는 최대 100개 자산을 담을 수 있습니다.") }
        var assetIDs = Set<String>(), totalVertices = 0
        try RecordScope.validateConsistency(archive.assets.flatMap(\.effectiveScopes))
        for asset in archive.assets {
            try text(asset.id, "자산 ID"); try text(asset.entityID, "연결 대상 ID"); try text(asset.title, "자산 이름")
            guard assetIDs.insert(asset.id).inserted else { throw SpatialError.invalid("중복 공간 자산 ID: \(asset.id)") }
            guard asset.accountIDs.count <= 100, Set(asset.accountIDs).count == asset.accountIDs.count else {
                throw SpatialError.invalid("계정 연결은 중복 없이 최대 100개여야 합니다.")
            }
            for id in asset.accountIDs { try text(id, "연결 계정 ID") }
            try validateOwnershipAndUse(asset)
            guard !asset.parts.isEmpty, asset.parts.count <= maximumParts else { throw SpatialError.invalid("자산별 형상은 1~100개여야 합니다.") }
            var partIDs = Set<String>()
            for part in asset.parts {
                try text(part.id, "형상 ID"); try text(part.title, "형상 이름")
                guard partIDs.insert(part.id).inserted else { throw SpatialError.invalid("자산 안의 형상 ID가 중복됐습니다: \(part.id)") }
                guard part.height.isFinite, part.height > 0, part.height <= 10_000,
                      part.elevation.isFinite, abs(part.elevation) <= 10_000 else {
                    throw SpatialError.invalid("높이는 0 초과 10,000m 이하, 기준면 높이는 ±10,000m 이내의 유한한 값이어야 합니다.")
                }
                try text(part.provenance.sourceRecordID, "형상 출처 ID")
                try text(part.provenance.note, "형상 치수의 근거", limit: 2_000)
                if asset.isSynthetic, part.provenance.kind != .schematic {
                    throw SpatialError.invalid("가상 예시의 형상은 개략(schematic)으로 표시해야 합니다.")
                }
                totalVertices += part.footprint.count
                guard totalVertices <= maximumTotalVertices else { throw SpatialError.invalid("전체 꼭짓점은 20,000개 이하여야 합니다.") }
                try validateFootprint(part.footprint)
            }
        }
    }

    private static func validateOwnershipAndUse(_ asset: SpatialAsset) throws {
        guard asset.ownerships.count <= 100, asset.usages.count <= 100 else {
            throw SpatialError.invalid("자산별 소유자와 사용 구분은 각각 최대 100개여야 합니다.")
        }
        var owners = Set<String>(), usageIDs = Set<String>(), scopes = Set<RecordScope>()
        for ownership in asset.ownerships {
            try RecordScope.validateID(ownership.ownerID, field: "소유자 ID")
            try text(ownership.sourceRecordID, "소유 근거 ID")
            try text(ownership.note, "소유 근거", limit: 2_000)
            guard owners.insert(ownership.ownerID).inserted else { throw SpatialError.invalid("소유자 ID가 중복됐습니다: \(ownership.ownerID)") }
        }
        for usage in asset.usages {
            try text(usage.id, "사용 구분 ID")
            try usage.scope.validate()
            try text(usage.sourceRecordID, "사용 근거 ID")
            try text(usage.note, "사용 근거", limit: 2_000)
            guard usageIDs.insert(usage.id).inserted, scopes.insert(usage.scope).inserted else {
                throw SpatialError.invalid("사용 구분 ID 또는 같은 개인·사업 범위가 중복됐습니다: \(usage.id)")
            }
            guard usage.accountLinks.count <= 100, Set(usage.accountLinks).count == usage.accountLinks.count else {
                throw SpatialError.invalid("검증할 계정 연결은 중복 없이 최대 100개여야 합니다.")
            }
            for link in usage.accountLinks {
                try text(link.bookID, "연결 장부 ID"); try text(link.accountID, "연결 계정 ID")
            }
            if !usage.accountLinks.isEmpty, usage.scope.kind == .unclassified {
                throw SpatialError.invalid("미분류 사용에는 검증된 계정 연결을 등록할 수 없습니다.")
            }
        }
        try validateRatios(asset.ownerships.map(\.shareBasisPoints), field: "소유 지분")
        try validateRatios(asset.usages.map(\.allocationBasisPoints), field: "사용 배분")
    }

    private static func validateRatios(_ values: [Int?], field: String) throws {
        var known = 0
        for value in values.compactMap({ $0 }) {
            guard (1...10_000).contains(value) else { throw SpatialError.invalid("\(field) 비율은 1~10,000 basis points이거나 미입력이어야 합니다.") }
            known += value
            guard known <= 10_000 else { throw SpatialError.invalid("알려진 \(field) 비율의 합은 100%를 넘을 수 없습니다.") }
        }
    }

    static func validateFootprint(_ points: [SpatialPoint]) throws {
        guard (3...maximumVertices).contains(points.count) else { throw SpatialError.invalid("외곽선은 3~256개 꼭짓점으로 입력하세요.") }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
            throw SpatialError.invalid("외곽선 좌표는 ±1,000,000m 이내의 유한한 값이어야 합니다.")
        }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            guard hypot(a.x - b.x, a.y - b.y) > 0.0001 else { throw SpatialError.invalid("외곽선의 연속 꼭짓점이 중복됐거나 너무 가깝습니다.") }
            let c = points[(i + 2) % points.count]
            if abs(cross(a, b, c)) <= epsilon,
               (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) < 0 {
                throw SpatialError.invalid("외곽선의 변이 되짚어 겹칩니다.")
            }
            for j in (i + 1)..<points.count {
                if j == i + 1 || (i == 0 && j == points.count - 1) { continue }
                if intersects(a, b, points[j], points[(j + 1) % points.count]) {
                    throw SpatialError.invalid("외곽선의 변이 교차하거나 서로 닿습니다. 단순 다각형을 입력하세요.")
                }
            }
        }
        guard area(points) > 0.0001 else { throw SpatialError.invalid("외곽선은 면적이 있는 다각형이어야 합니다.") }
    }

    /// Translate to the first point to avoid cancellation for distant local origins.
    static func area(_ points: [SpatialPoint]) -> Double {
        guard let origin = points.first, points.count >= 3 else { return 0 }
        return abs((1..<(points.count - 1)).reduce(0) { $0 + cross(origin, points[$1], points[$1 + 1]) }) / 2
    }

    private static func text(_ value: String, _ field: String, limit: Int = 256) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SpatialError.invalid("\(field)은 제어문자 없이 1~\(limit)자로 입력하세요.")
        }
    }
    private static func cross(_ a: SpatialPoint, _ b: SpatialPoint, _ c: SpatialPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func onSegment(_ a: SpatialPoint, _ b: SpatialPoint, _ p: SpatialPoint) -> Bool {
        abs(cross(a, b, p)) <= epsilon && p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon
            && p.y >= min(a.y, b.y) - epsilon && p.y <= max(a.y, b.y) + epsilon
    }
    private static func intersects(_ a: SpatialPoint, _ b: SpatialPoint, _ c: SpatialPoint, _ d: SpatialPoint) -> Bool {
        let x = cross(a, b, c), y = cross(a, b, d), z = cross(c, d, a), w = cross(c, d, b)
        if ((x > epsilon && y < -epsilon) || (x < -epsilon && y > epsilon)) &&
            ((z > epsilon && w < -epsilon) || (z < -epsilon && w > epsilon)) { return true }
        return onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b)
    }
}
