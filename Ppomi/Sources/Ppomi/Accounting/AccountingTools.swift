import Foundation
import CoreFoundation

/// One API for every account and activity. The client supplies classifications and estimates;
/// the app validates balanced entries and keeps the recorded and assessment layers separate.
enum AccountingTools {
    static let names: Set<String> = ["accounting_records", "accounting_import", "accounting_reclassify", "accounting_template"]
    static let specs: [ToolSpec] = [
        Tools.T("accounting_records", "범용 분개장의 장부·단위·계정과목·원본/평가 분개를 읽는다. 개인·사업·소유자별 필터를 함께 적용하며 scopeByBookID는 각 장부의 구분을 명시한다. 장부별 차대가 일치하며 서로 다른 장부나 돈과 시간을 합산하지 않는다. history=true는 교체된 평가까지 반환한다. 장부가 비었으면 accounting_template으로 규격을 확인한다.",
            ["bookID": ("string", "선택: 특정 장부 ID. 구분 필터와 일치해야 함"), "entryID": ("string", "선택: 과거 기록을 포함한 정확한 분개 ID 조회"),
             "scopeKind": ("string", "선택: unclassified(미분류), personal(개인), business(사업). 기존 구분 없는 장부는 미분류"),
             "ownerID": ("string", "선택: 구분에 명시된 소유자 ID. 이름이나 계정과목으로 추정하지 않음"),
             "businessID": ("string", "선택: 사업 ID. 이것만 지정하면 business 구분으로 조회하며 다른 구분과 함께 지정할 수 없음"),
             "eventID": ("string", "선택: 같은 활동의 금전/시간 기록 조회"), "history": ("boolean", "기본 false: 유효한 평가만. entryID 조회는 이전 평가도 가능"),
             "limit": ("integer", "최신 분개 최대 건수, 기본 100, 1~1000"), "offset": ("integer", "선택: 이전 응답의 nextOffset, 기본 0. 조회 도중 새 기록이 추가되면 첫 페이지부터 다시 조회")]),
        Tools.T("accounting_import", "사용자가 기록하려는 장부·계정과목·분개를 공통 JSON 규격으로 비공개 저장한다. accounting_template으로 규격을 확인한다. 장부 scope는 개인이면 kind=personal와 ownerID, 사업이면 kind=business와 ownerID·businessID를 명시하며 생략한 기존 자료는 미분류다. 같은 소유자의 여러 사업도 별도 장부로 구분한다. 기존 ID는 동일 내용 재시도만 허용하며 충돌·불균형은 전체 취소한다. 원본 layer=recorded는 보고/관측 사실, AI의 자산화 판단은 layer=adjustment와 assessment에 별도 저장한다. 시간은 kind=resource 장부, 금액/수량은 unit.scale에 따른 정수 최소단위다. 이름으로 소유권·효율·수익을 추측하지 마라. 저장은 송금/결제 승인과 무관하다.",
            ["archive": ("string", "JSON 문자열 {formatVersion:1,books:[],accounts:[],entries:[]}. 이미 등록된 정의는 생략 가능. 날짜는 시간대 포함 ISO8601")], ["archive"]),
        Tools.T("accounting_reclassify", "원본 분개의 한 항목 중 지정 비율을 다른 계정과목으로 재분류하는 관리용 평가를 추가한다. 원본은 보존하고 차대는 자동 생성한다. AI가 판단한 비율과 신뢰도를 구분하고 근거를 명시한다. 고정 기본 자산화 비율은 없다. 원본당 평가 체인은 하나이며 replacesEntryID는 이전 평가 전체를 교체한다. 여러 항목 동시 배분은 accounting_import의 복수 postings 조정을 쓴다. 돈과 시간에 같은 함수가 적용된다.",
            ["id": ("string", "이 평가의 고유 ID. 재시도는 동일 ID"), "sourceEntryID": ("string", "원본 recorded 분개 ID"),
             "postingIndex": ("integer", "원본 postings의 0부터 시작하는 위치"), "targetAccountID": ("string", "같은 장부의 대상 계정 ID"),
             "basisPoints": ("integer", "배분 비율 0~10000. 6000=60%. 0은 기존 평가 철회에만 사용"),
             "rationale": ("string", "평가 근거와 가정"), "confidenceBasisPoints": ("integer", "평가 신뢰도 0~10000, 배분 비율과 별개"),
             "model": ("string", "선택: 판단한 모델/평가자"), "replacesEntryID": ("string", "선택: 교체할 현재 평가 ID"),
             "recordedAt": ("string", "선택: 평가 기록 시각. 생략 시 최초 저장 시각, 재시도에는 유지")],
            ["id", "sourceEntryID", "postingIndex", "targetAccountID", "basisPoints", "rationale", "confidenceBasisPoints"]),
        Tools.T("accounting_template", "범용 분개장 JSON 규격과 가상 사례를 읽는다. 예시 사용자·지출·시간·비율은 실제 자료가 아니며 자동 저장하지 않는다. 새 활동은 새로운 종류의 코드 대신 계정과목과 분개 데이터로 정의한다.")
    ]

    static func execute(_ name: String, _ arguments: [String: Any], path: String) throws -> String {
        switch name {
        case "accounting_template":
            try allowed(arguments, [])
            return String(decoding: try AccountingCatalog.templateData(), as: UTF8.self)
        case "accounting_records":
            try allowed(arguments, ["bookID", "entryID", "eventID", "history", "limit", "offset", "scopeKind", "ownerID", "businessID"])
            let bookID = try string("bookID", arguments)
            let scope = try scopeFilter(arguments)
            let entryID = try string("entryID", arguments), eventID = try string("eventID", arguments)
            let history = try boolean("history", arguments) ?? false
            let limit = try integer("limit", arguments, range: 1...1000) ?? 100
            let offset = try integer("offset", arguments, range: 0...1_000_000_000) ?? 0
            let archive = try AccountingStore(path: path).snapshot()
            if let bookID, !archive.books.contains(where: { $0.id == bookID }) {
                throw LifeError.missing("장부 ID를 찾을 수 없습니다: \(bookID)")
            }
            if let bookID, let selected = archive.books.first(where: { $0.id == bookID }), !scope.matches(selected.effectiveScope) {
                throw LifeError.validation("장부 ID와 개인·사업·소유자 구분 필터가 일치하지 않습니다: \(bookID)")
            }
            let books = archive.books.filter { (bookID == nil || $0.id == bookID) && scope.matches($0.effectiveScope) }
            let bookIDs = Set(books.map(\.id))
            let entries = try (history || entryID != nil ? archive.entries.filter { bookIDs.contains($0.bookID) } :
                books.flatMap { try AccountingEngine.entries(in: archive, bookID: $0.id, includeAdjustments: true) })
                .filter { (entryID == nil || $0.id == entryID) && (eventID == nil || $0.eventID == eventID) }
                .sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
            let page = Array(entries.dropFirst(offset).prefix(limit))
            let next = offset + page.count
            let selected = AccountingArchive(books: books, accounts: archive.accounts.filter { bookIDs.contains($0.bookID) }, entries: page)
            let scopeByBookID = try Dictionary(uniqueKeysWithValues: books.map { ($0.id, try object($0.effectiveScope)) })
            return try json(["data": object(selected), "scopeByBookID": scopeByBookID,
                             "totalMatching": entries.count, "truncated": next < entries.count,
                             "nextOffset": next < entries.count ? next as Any : NSNull(), "history": history || entryID != nil,
                             "note": "조회 결과는 부분집합이며 완전한 백업은 앱의 JSON 내보내기를 사용합니다. 평가 원본은 entryID로 조회할 수 있습니다."])
        case "accounting_import":
            try allowed(arguments, ["archive"])
            let raw = try required("archive", arguments)
            guard raw.utf8.count <= 4_000_000 else { throw LifeError.validation("한 번에 가져올 JSON은 4MB 이하여야 합니다.") }
            let archive = try LifeJSON.decoder().decode(AccountingArchive.self, from: Data(raw.utf8))
            let inserted = try AccountingStore(path: path).importArchive(archive)
            return try json(["status": inserted == 0 ? "duplicate" : "inserted", "inserted": inserted])
        case "accounting_reclassify":
            try allowed(arguments, ["id", "sourceEntryID", "postingIndex", "targetAccountID", "basisPoints", "rationale", "confidenceBasisPoints", "model", "replacesEntryID", "recordedAt"])
            let id = try required("id", arguments), sourceID = try required("sourceEntryID", arguments)
            let target = try required("targetAccountID", arguments), rationale = try required("rationale", arguments)
            guard let posting = try integer("postingIndex", arguments, range: 0...10000),
                  let ratio = try integer("basisPoints", arguments, range: 0...10000),
                  let confidence = try integer("confidenceBasisPoints", arguments, range: 0...10000) else {
                throw LifeError.validation("postingIndex·basisPoints·confidenceBasisPoints가 필요합니다.")
            }
            let store = try AccountingStore(path: path), archive = try store.snapshot()
            guard let source = archive.entries.first(where: { $0.id == sourceID }) else {
                throw LifeError.missing("원본 분개를 찾을 수 없습니다: \(sourceID)")
            }
            let date: Date
            if let rawDate = try string("recordedAt", arguments) {
                guard let parsed = LifeJSON.parseTimestamp(rawDate) else { throw LifeError.validation("recordedAt은 시간대 포함 ISO8601이어야 합니다.") }
                date = parsed
            } else {
                date = archive.entries.first(where: { $0.id == id })?.recordedAt ?? Date()
            }
            let assessment = AccountingAssessment(sourceEntryID: sourceID, rationale: rationale, confidenceBasisPoints: confidence,
                model: try string("model", arguments), replacesEntryID: try string("replacesEntryID", arguments))
            let entry = try AccountingEngine.reclassify(source: source, postingIndex: posting, targetAccountID: target,
                basisPoints: ratio, id: id, assessment: assessment, recordedAt: date)
            let inserted: Int
            do {
                inserted = try store.importArchive(AccountingArchive(entries: [entry]))
            } catch {
                // Overlapping retries may both create their default timestamp before either commits.
                // Adopt the winner's timestamp only when every caller-supplied field agrees.
                if arguments["recordedAt"] == nil,
                   let winner = try? store.snapshot().entries.first(where: { $0.id == id }) {
                    var retry = entry
                    retry.recordedAt = winner.recordedAt
                    if retry == winner {
                        return try json(["status": "duplicate", "entry": object(winner), "layer": "adjustment"])
                    }
                }
                throw error
            }
            return try json(["status": inserted == 0 ? "duplicate" : "inserted", "entry": object(entry), "layer": "adjustment"])
        default:
            throw LifeError.validation("알 수 없는 분개장 도구입니다.")
        }
    }

    private static func allowed(_ arguments: [String: Any], _ keys: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: keys) else { throw LifeError.validation("허용되지 않은 분개장 인자입니다.") }
    }
    private static func scopeFilter(_ arguments: [String: Any]) throws -> RecordScopeFilter {
        let kind: RecordScope.Kind?
        if let raw = try string("scopeKind", arguments) {
            guard let parsed = RecordScope.Kind(rawValue: raw) else {
                throw LifeError.validation("scopeKind는 unclassified, personal, business 중 하나여야 합니다.")
            }
            kind = parsed
        } else { kind = nil }
        let businessID = try string("businessID", arguments)
        let filter = RecordScopeFilter(kind: kind ?? (businessID == nil ? nil : .business),
                                       ownerID: try string("ownerID", arguments), businessID: businessID)
        try filter.validate()
        return filter
    }
    private static func string(_ key: String, _ arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LifeError.validation("\(key)는 빈 값이 아닌 문자열이어야 합니다.")
        }
        return value
    }
    private static func required(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = try string(key, arguments) else { throw LifeError.validation("\(key)가 필요합니다.") }
        return value
    }
    private static func integer(_ key: String, _ arguments: [String: Any], range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
            throw LifeError.validation("\(key)는 \(range.lowerBound)~\(range.upperBound) 정수여야 합니다.")
        }
        return number.intValue
    }
    private static func boolean(_ key: String, _ arguments: [String: Any]) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw LifeError.validation("\(key)는 true 또는 false여야 합니다.")
        }
        return number.boolValue
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: LifeJSON.encoder().encode(value))
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
