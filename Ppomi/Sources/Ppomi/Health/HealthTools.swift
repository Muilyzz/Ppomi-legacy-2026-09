import Foundation
import CoreFoundation

/// The voice and MCP channels write the same private records as the health view.
/// Agent arguments can describe a report or an estimate, never certify a record.
enum HealthTools {
    static let kinds: Set<LifeRecord.Kind> = [.measurement, .meal, .exercise, .checkIn]
    static let specs: [ToolSpec] = [
        Tools.T("health_records", "비공개 건강 기록을 발생 시각 최신순으로 읽는다. 기본 대상은 나(self), 다른 사람은 등록된 person ID를 명시한다. 금융 기록은 제외. 실측·사용자 보고·AI 추정·검토 상태를 구분하고, 미기록을 0 또는 안 했음으로 해석하지 마라.",
            ["subjectID": ("string", "기본 self; 등록된 사람 ID"), "kind": ("string", "선택: measurement, meal, exercise, checkIn"),
             "since": ("string", "선택: 포함할 시작 시각, 시간대 포함 ISO8601"), "before": ("string", "선택: 제외할 끝 시각, 시간대 포함 ISO8601"),
             "limit": ("integer", "기본 30, 1~100건")]),
        Tools.T("record_health", "사용자가 기록해 달라고 한 체성분·식사·운동·컨디션 한 건을 비공개 저장한다. reported는 사용자가 말한 내용만, aiEstimate는 AI 추정 수치이며 섞지 말고 따로 저장한다. 발생 시각이 불명확하면 묻고, 모르는 값은 생략한다. 사용자 확인 상태는 부여할 수 없다. sourceID는 원본 발화/기록의 안정적인 고유 ID로 재시도에 그대로 사용한다.",
            ["subjectID": ("string", "기본 self; 등록된 사람 ID"), "kind": ("string", "measurement, meal, exercise, checkIn 중 하나"),
             "occurredAt": ("string", "시간대 포함 ISO8601, 예: 2026-09-06T12:30:00+09:00"),
             "sourceID": ("string", "원본 발화/기록의 고유 ID. 같은 사실 재시도는 같은 ID, 별도 추정은 다른 ID"),
             "attribution": ("string", "reported 또는 aiEstimate"),
             "metrics": ("string", "선택: JSON 배열 문자열 [{\"code\":\"weight\",\"title\":\"체중\",\"value\":72.3,\"unit\":\"kg\"}]. 체성분 kg/%/kg/m2/ratio/level, 식사 energy:kcal·protein/carbohydrate/fat:g, 운동 duration:min·steps:count·distance:km·energy:kcal, 컨디션 wellbeing:score/5. 모르는 항목 생략"),
             "note": ("string", "선택: 사용자가 보고한 식사·운동 등 내용. 추정은 명시"), "device": ("string", "선택: 사용자가 알려준 측정 기기")],
            ["kind", "occurredAt", "sourceID", "attribution"]),
        Tools.T("inbody_capture", "현재 iPhone 미러링의 본인 인바디 결과 화면 한 장에서 날짜와 체성분을 읽어 비공개 건강 기록 및 원본 증빙으로 저장한다. 인바디 상세/결과 목록을 연 뒤 호출. phone_screen과 같은 동의·권한·폰 상태 검사를 통과해야 한다. 앱 열기·로그인·스크롤은 하지 않는다. OCR 결과는 미검토 상태로 보관한다.")
    ]

    static func records(_ arguments: [String: Any], store: LifeStore) throws -> String {
        try allowed(arguments, ["subjectID", "kind", "since", "before", "limit"])
        let subject = try person(arguments, store: store)
        let kind = try optionalString("kind", arguments).map { raw -> LifeRecord.Kind in
            guard let kind = LifeRecord.Kind(rawValue: raw), kinds.contains(kind) else { throw LifeError.validation("건강 기록 종류가 아닙니다.") }
            return kind
        }
        let since = try optionalDate("since", arguments), before = try optionalDate("before", arguments)
        if let since, let before, since >= before { throw LifeError.validation("시작 시각은 끝 시각보다 빨라야 합니다.") }
        let limit: Int
        if let raw = arguments["limit"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (1...100).contains(number.doubleValue) else { throw LifeError.validation("limit는 1~100 정수여야 합니다.") }
            limit = number.intValue
        } else { limit = 30 }
        let matching = try store.allRecords().filter { record in
            record.subjectID == subject.id && kinds.contains(record.kind) && (kind == nil || record.kind == kind) &&
                (since == nil || record.occurredAt >= since!) && (before == nil || record.occurredAt < before!)
        }.sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
        let values = try matching.prefix(limit).map { record -> [String: Any] in
            var value = try object(record)
            if let note = record.note, note.count > 2_000 {
                value["note"] = String(note.prefix(2_000)); value["noteTruncated"] = true
            }
            return value
        }
        return try json(["subject": object(subject), "records": values, "totalMatching": matching.count,
                         "returned": values.count, "truncated": values.count < matching.count])
    }

    static func record(_ arguments: [String: Any], store: LifeStore) throws -> String {
        try allowed(arguments, ["subjectID", "kind", "occurredAt", "sourceID", "attribution", "metrics", "note", "device"])
        guard let kind = LifeRecord.Kind(rawValue: try requiredString("kind", arguments)), kinds.contains(kind) else {
            throw LifeError.validation("measurement, meal, exercise, checkIn만 건강 기록으로 저장합니다.")
        }
        let occurredAt = try requiredDate("occurredAt", arguments)
        let sourceID = try requiredString("sourceID", arguments)
        guard sourceID.count <= 200 else { throw LifeError.validation("sourceID는 200자 이하여야 합니다.") }
        let attribution = try requiredString("attribution", arguments)
        let method: LifeRecord.Method
        switch attribution {
        case "reported": method = .manual
        case "aiEstimate": method = .aiEstimate
        default: throw LifeError.validation("attribution은 reported 또는 aiEstimate여야 합니다.")
        }
        var metrics: [LifeMetric] = []
        if let raw = try optionalString("metrics", arguments) {
            guard raw.utf8.count <= 16_384 else { throw LifeError.validation("측정 항목이 너무 큽니다.") }
            metrics = try JSONDecoder().decode([LifeMetric].self, from: Data(raw.utf8))
            guard metrics.count <= 16 else { throw LifeError.validation("측정 항목은 최대 16개입니다.") }
        }
        let note = try optionalString("note", arguments), device = try optionalString("device", arguments)
        if let device, device.count > 500 { throw LifeError.validation("기기 이름은 500자 이하여야 합니다.") }
        let subject = try person(arguments, store: store)
        let record = LifeRecord(subjectID: subject.id, kind: kind, occurredAt: occurredAt,
            sourceName: "Ppomi agent", sourceRecordID: subject.id + ":" + sourceID,
            method: method, review: .unreviewed, metrics: metrics, note: note, device: device)
        let result = try store.save(record)
        let id: String, status: String
        switch result {
        case .inserted(let value): id = value; status = "inserted"
        case .duplicate(let value): id = value; status = "duplicate"
        }
        let saved = try store.record(id: id)
        return try json(["status": status, "recordID": id, "subjectID": subject.id, "attribution": attribution,
                         "review": saved?.review.rawValue ?? "unreviewed", "sourceName": record.sourceName])
    }

    static func validateCaptureArguments(_ arguments: [String: Any]) throws { try allowed(arguments, []) }

    private static func person(_ arguments: [String: Any], store: LifeStore) throws -> LifeEntity {
        let id = try optionalString("subjectID", arguments) ?? "self"
        if id == "self" { return try store.ensureSelfEntity() }
        guard let subject = try store.entity(id: id), subject.kind == .person else {
            throw LifeError.validation("등록된 사람의 subjectID가 필요합니다. 이름이나 계좌 ID로 대신하지 마세요.")
        }
        return subject
    }
    private static func allowed(_ arguments: [String: Any], _ names: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: names) else { throw LifeError.validation("허용되지 않은 인자가 있습니다. 검토·승인은 에이전트 인자로 지정할 수 없습니다.") }
    }
    private static func optionalString(_ key: String, _ arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LifeError.validation("\(key)는 빈 값이 아닌 문자열이어야 합니다. 모르면 생략하세요.")
        }
        return value
    }
    private static func requiredString(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = try optionalString(key, arguments) else { throw LifeError.validation("\(key)가 필요합니다.") }
        return value
    }
    private static func optionalDate(_ key: String, _ arguments: [String: Any]) throws -> Date? {
        guard let raw = try optionalString(key, arguments) else { return nil }
        guard let date = LifeJSON.parseTimestamp(raw) else { throw LifeError.validation("\(key)는 시간대 포함 ISO8601이어야 합니다.") }
        return date
    }
    private static func requiredDate(_ key: String, _ arguments: [String: Any]) throws -> Date {
        guard let date = try optionalDate(key, arguments) else { throw LifeError.validation("\(key)가 필요합니다.") }
        return date
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: LifeJSON.encoder().encode(value)) as! [String: Any]
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
