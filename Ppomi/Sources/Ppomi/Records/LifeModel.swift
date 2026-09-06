import Foundation

/// Private, source-backed records. An omitted metric means unknown, never zero.
struct LifeEntity: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case person, organization, account, property, device }
    var id: String
    var kind: Kind
    var name: String
    init(id: String = UUID().uuidString, kind: Kind, name: String) {
        self.id = id; self.kind = kind; self.name = name
    }
}

struct LifeMetric: Codable, Equatable, Identifiable {
    var code: String
    var title: String
    var value: Double
    var unit: String
    var id: String { code }
    init(code: String, title: String, value: Double, unit: String) {
        self.code = code; self.title = title; self.value = value; self.unit = unit
    }

    static let units: [String: Set<String>] = [
        "weight": ["kg"], "bodyFatPercent": ["%"], "skeletalMuscleMass": ["kg"],
        "bodyFatMass": ["kg"], "bmi": ["kg/m2"], "waistHipRatio": ["ratio"], "extracellularWaterRatio": ["ratio"],
        "visceralFatLevel": ["level"], "energy": ["kcal"], "protein": ["g"],
        "carbohydrate": ["g"], "fat": ["g"], "duration": ["min"], "steps": ["count"],
        "distance": ["km"], "wellbeing": ["score/5"], "amount": ["KRW", "USD", "EUR", "JPY"],
        "balance": ["KRW", "USD", "EUR", "JPY"]
    ]

    func validate() throws {
        guard let accepted = Self.units[code], accepted.contains(unit) else {
            throw LifeError.validation("지원하지 않는 측정 항목 또는 단위: \(code) / \(unit)")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.isFinite else {
            throw LifeError.validation("측정 이름과 유효한 숫자가 필요합니다.")
        }
        if code != "amount" && code != "balance" && value < 0 {
            throw LifeError.validation("\(title)은 음수일 수 없습니다.")
        }
        if ["weight", "bmi", "waistHipRatio"].contains(code) && value == 0 {
            throw LifeError.validation("\(title)의 0은 측정값으로 저장할 수 없습니다. 모르면 항목을 비워 주세요.")
        }
        if code == "bodyFatPercent" && value > 100 { throw LifeError.validation("체지방률은 100% 이하여야 합니다.") }
        if code == "extracellularWaterRatio" && value > 1 { throw LifeError.validation("세포외수분비는 0~1 범위여야 합니다.") }
        if code == "wellbeing" && !(1...5).contains(value) { throw LifeError.validation("컨디션은 1~5점으로 기록합니다.") }
        if ["steps", "visceralFatLevel"].contains(code) && value.rounded() != value {
            throw LifeError.validation("\(title)은 정수여야 합니다.")
        }
    }
}

struct LifeRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case measurement, meal, exercise, checkIn, habit, financialSnapshot, financialTransaction
        var title: String {
            switch self {
            case .measurement: return "몸의 변화"
            case .meal: return "식사"
            case .exercise: return "운동"
            case .checkIn: return "컨디션"
            case .habit: return "습관"
            case .financialSnapshot: return "자산 관측"
            case .financialTransaction: return "금융 거래"
            }
        }
    }
    enum Method: String, Codable, CaseIterable {
        case api, ocr, manual, legacyImport, aiEstimate
        var title: String {
            switch self {
            case .api: return "API에서 가져옴"
            case .ocr: return "화면·결과지에서 읽음"
            case .manual: return "직접 기록"
            case .legacyImport: return "기존 장부에서 가져옴"
            case .aiEstimate: return "AI 추정"
            }
        }
    }
    enum Review: String, Codable { case unreviewed, userConfirmed }
    enum ActivityStatus: String, Codable { case completed, retracted }
    var id: String
    var subjectID: String
    var kind: Kind
    var occurredAt: Date
    var recordedAt: Date
    var sourceName: String
    var sourceRecordID: String?
    var method: Method
    var review: Review
    var metrics: [LifeMetric]
    var note: String?
    var device: String?
    var evidenceIDs: [String]
    var activityID: String?
    var activityStatus: ActivityStatus?
    var activityDay: String?
    var activityTimeZone: String?

    init(id: String = UUID().uuidString, subjectID: String, kind: Kind, occurredAt: Date,
         recordedAt: Date = Date(), sourceName: String, sourceRecordID: String? = nil,
         method: Method, review: Review = .unreviewed, metrics: [LifeMetric] = [],
         note: String? = nil, device: String? = nil, evidenceIDs: [String] = [],
         activityID: String? = nil, activityStatus: ActivityStatus? = nil,
         activityDay: String? = nil, activityTimeZone: String? = nil) {
        self.id = id; self.subjectID = subjectID; self.kind = kind; self.occurredAt = occurredAt
        self.recordedAt = recordedAt; self.sourceName = sourceName; self.sourceRecordID = sourceRecordID
        self.method = method; self.review = review; self.metrics = metrics; self.note = note
        self.device = device; self.evidenceIDs = evidenceIDs
        self.activityID = activityID; self.activityStatus = activityStatus
        self.activityDay = activityDay; self.activityTimeZone = activityTimeZone
    }

    static func isValidActivityID(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
    }

    func validate() throws {
        for text in [id, subjectID, sourceName] {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else {
                throw LifeError.validation("기록 ID·대상·출처가 필요합니다.")
            }
        }
        if let sourceRecordID, sourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LifeError.validation("출처의 기록 ID가 없으면 빈 문자열 대신 생략하세요.")
        }
        guard occurredAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970.isFinite else {
            throw LifeError.validation("발생 시각과 수집 시각이 필요합니다.")
        }
        guard Set(metrics.map(\.code)).count == metrics.count else { throw LifeError.validation("한 기록에 같은 측정 항목이 중복됐습니다.") }
        guard Set(evidenceIDs).count == evidenceIDs.count else { throw LifeError.validation("증빙 ID가 중복됐습니다.") }
        guard (note?.count ?? 0) <= 20_000 else { throw LifeError.validation("메모는 20,000자까지 저장합니다.") }
        for metric in metrics { try metric.validate() }
        if kind == .habit {
            guard let activityID, Self.isValidActivityID(activityID), activityStatus != nil else {
                throw LifeError.validation("습관에는 안정적인 activityID와 completed/retracted 상태가 필요합니다.")
            }
            guard method == .manual else { throw LifeError.validation("습관 완료는 사용자가 직접 말하거나 누른 사실만 기록합니다. 추정으로 완료 처리할 수 없습니다.") }
            guard let activityDay, let activityTimeZone, let zone = TimeZone(identifier: activityTimeZone),
                  Self.isValidActivityDay(activityDay, timeZone: zone) else {
                throw LifeError.validation("습관에는 실제 행동 날짜 activityDay(YYYY-MM-DD)와 activityTimeZone이 필요합니다.")
            }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day], from: occurredAt)
            let reportDay = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            guard activityDay <= reportDay else {
                throw LifeError.validation("보고 시각보다 미래인 날짜의 습관을 완료 처리할 수 없습니다.")
            }
        } else if activityID != nil || activityStatus != nil || activityDay != nil || activityTimeZone != nil {
            throw LifeError.validation("activity 필드는 습관 기록에만 사용할 수 있습니다.")
        }
        let allowed: Set<String>
        switch kind {
        case .measurement: allowed = ["weight", "bodyFatPercent", "skeletalMuscleMass", "bodyFatMass", "bmi", "waistHipRatio", "extracellularWaterRatio", "visceralFatLevel"]
        case .meal: allowed = ["energy", "protein", "carbohydrate", "fat"]
        case .exercise: allowed = ["duration", "steps", "distance", "energy"]
        case .checkIn: allowed = ["wellbeing"]
        case .habit: allowed = []
        case .financialSnapshot: allowed = ["balance"]
        case .financialTransaction: allowed = ["amount"]
        }
        guard metrics.allSatisfy({ allowed.contains($0.code) }) else { throw LifeError.validation("기록 종류와 측정 항목이 맞지 않습니다.") }
        if [.measurement, .financialSnapshot, .financialTransaction].contains(kind) && metrics.isEmpty { throw LifeError.validation("측정값이 하나 이상 필요합니다.") }
        if [.meal, .exercise, .checkIn].contains(kind), metrics.isEmpty,
           (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidenceIDs.isEmpty {
            throw LifeError.validation("내용이나 수치, 사진 중 하나를 기록해 주세요.")
        }
    }

    static func isValidActivityDay(_ value: String, timeZone: TimeZone) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// Recollection timestamps and review do not change the source's observed fact.
    func sameSourceFact(as other: LifeRecord) -> Bool {
        var candidate = self
        candidate.id = other.id; candidate.recordedAt = other.recordedAt; candidate.review = other.review
        candidate.metrics.sort { $0.code < $1.code }
        candidate.evidenceIDs.sort()
        var existing = other; existing.metrics.sort { $0.code < $1.code }; existing.evidenceIDs.sort()
        return candidate == existing
    }
}

struct LifeEvidence: Codable, Identifiable, Equatable {
    var id: String
    var originalName: String
    var sha256: String
    var recordedAt: Date
    /// Evidence metadata can be exported; private filesystem paths cannot be imported.
}

struct LifeRevision: Codable, Identifiable, Equatable {
    var id: String
    var recordID: String
    var replacedAt: Date
    var reason: String
    var previous: LifeRecord
}

enum LifeSaveResult: Equatable { case inserted(String), duplicate(String) }
struct LifeImportResult: Equatable { var inserted: Int = 0; var duplicates: Int = 0 }

struct LifeArchive: Codable {
    var formatVersion: Int = 1
    var entities: [LifeEntity]
    var records: [LifeRecord]
    var evidence: [LifeEvidence] = []
    var revisions: [LifeRevision] = []

    init(formatVersion: Int = 1, entities: [LifeEntity], records: [LifeRecord], evidence: [LifeEvidence] = [], revisions: [LifeRevision] = []) {
        self.formatVersion = formatVersion; self.entities = entities; self.records = records
        self.evidence = evidence; self.revisions = revisions
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, entities, records, evidence, revisions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        entities = try c.decode([LifeEntity].self, forKey: .entities)
        records = try c.decode([LifeRecord].self, forKey: .records)
        evidence = try c.decodeIfPresent([LifeEvidence].self, forKey: .evidence) ?? []
        revisions = try c.decodeIfPresent([LifeRevision].self, forKey: .revisions) ?? []
    }
}

enum LifeError: LocalizedError {
    case validation(String), database(String), conflict(String), missing(String)
    var errorDescription: String? {
        switch self {
        case .validation(let m), .database(let m), .conflict(let m), .missing(let m): return m
        }
    }
}

enum LifeJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(timestamp(date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(); let raw = try c.decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO8601 시각에 시간대가 필요합니다: 2026-09-06T08:00:00+09:00")
            }
            return date
        }
        return decoder
    }
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func parseTimestamp(_ raw: String) -> Date? {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        if raw.contains(".") { f.formatOptions.insert(.withFractionalSeconds) }
        guard let date = f.date(from: raw) else { return nil }
        let offset: Int
        if raw.hasSuffix("Z") { offset = 0 }
        else {
            let suffix = String(raw.suffix(6)); let hours = Int(suffix.dropFirst().prefix(2)) ?? 99
            let minutes = Int(suffix.suffix(2)) ?? 99
            guard hours <= 14, minutes <= 59, hours < 14 || minutes == 0 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (suffix.first == "-" ? -1 : 1)
        }
        let verify = DateFormatter(); verify.locale = Locale(identifier: "en_US_POSIX")
        verify.calendar = Calendar(identifier: .gregorian); verify.timeZone = TimeZone(secondsFromGMT: offset)
        verify.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard verify.string(from: date) == String(raw.prefix(19)) else { return nil }
        return date
    }
}
