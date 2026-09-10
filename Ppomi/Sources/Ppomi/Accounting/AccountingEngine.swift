import Foundation

/// Shared journal mechanics. Account names and activity subjects never select code paths here.
enum AccountingEngine {
    static func validate(_ archive: AccountingArchive) throws {
        guard archive.formatVersion == 1 else { throw AccountingError.validation("지원하지 않는 회계 자료 버전입니다.") }
        let books = try indexed(archive.books, kind: "장부", id: \.id)
        let accounts = try indexed(archive.accounts, kind: "계정", id: \.id)
        let entries = try indexed(archive.entries, kind: "분개", id: \.id)
        var units: [String: AccountingUnit] = [:]
        for book in archive.books {
            try text(book.id, "장부 ID"); try text(book.name, "장부 이름"); try text(book.ownerID, "장부 소유자 ID")
            // Legacy owner references obey the original text rule. Do not invalidate an old archive
            // by applying a newly introduced scope's stricter ID format to its inferred display scope.
            try book.scope?.validate()
            if let scopeOwner = book.scope?.ownerID, scopeOwner != book.ownerID {
                throw AccountingError.validation("장부 소유자 ID와 구분의 소유자 ID가 일치해야 합니다: \(book.id)")
            }
            let unit = book.unit
            try text(unit.id, "단위 ID"); try text(unit.name, "단위 이름"); try text(unit.symbol, "단위 표시")
            guard (0...18).contains(unit.scale) else { throw AccountingError.validation("단위의 소수 자릿수는 0~18이어야 합니다.") }
            guard book.kind != .financial || unit.dimension == .currency else {
                throw AccountingError.validation("재무 장부는 화폐 단위로만 기록합니다. 시간·수량은 자원 장부를 사용하세요.")
            }
            if let previous = units[unit.id], previous != unit {
                throw AccountingError.validation("같은 단위 ID에 서로 다른 정의가 있습니다: \(unit.id)")
            }
            units[unit.id] = unit
        }
        try RecordScope.validateConsistency(archive.books.compactMap(\.scope))
        for account in archive.accounts {
            try text(account.id, "계정 ID"); try text(account.name, "계정 이름")
            guard books[account.bookID] != nil else { throw AccountingError.validation("계정의 장부가 없습니다: \(account.bookID)") }
            if let parentID = account.parentID {
                guard let parent = accounts[parentID], parent.bookID == account.bookID, parent.kind == account.kind else {
                    throw AccountingError.validation("상위 계정은 같은 장부·계정 유형이어야 합니다: \(parentID)")
                }
            }
            try noCycle(start: account.id, label: "계정 계층", next: { accounts[$0]?.parentID })
        }
        var successors: [String: String] = [:], assessmentRoots: [String: String] = [:]
        var sourceIdentities: Set<[String]> = []
        for entry in archive.entries {
            try validateEntryShape(entry)
            guard books[entry.bookID] != nil else { throw AccountingError.validation("분개의 장부가 없습니다: \(entry.bookID)") }
            for posting in entry.postings {
                guard let account = accounts[posting.accountID], account.bookID == entry.bookID else {
                    throw AccountingError.validation("모든 분개 항목은 같은 장부의 등록 계정을 사용해야 합니다: \(posting.accountID)")
                }
            }
            switch entry.layer {
            case .recorded:
                guard entry.assessment == nil else { throw AccountingError.validation("원본 분개에 평가를 덮어쓸 수 없습니다. 별도 조정 분개를 사용하세요.") }
                if let sourceRecordID = entry.sourceRecordID,
                   !sourceIdentities.insert([entry.bookID, entry.source, sourceRecordID]).inserted {
                    throw AccountingError.conflict("같은 출처 기록이 서로 다른 분개로 중복됐습니다: \(sourceRecordID)")
                }
            case .adjustment:
                guard let assessment = entry.assessment else { throw AccountingError.validation("조정 분개에는 평가 근거가 필요합니다.") }
                try validateAssessment(assessment)
                guard let source = entries[assessment.sourceEntryID], source.layer == .recorded,
                      source.bookID == entry.bookID, source.eventID == entry.eventID else {
                    throw AccountingError.validation("평가는 같은 장부·활동의 원본 분개를 참조해야 합니다.")
                }
                if let replacedID = assessment.replacesEntryID {
                    guard let replaced = entries[replacedID], replaced.layer == .adjustment,
                          replaced.bookID == entry.bookID, replaced.eventID == entry.eventID,
                          replaced.assessment?.sourceEntryID == assessment.sourceEntryID else {
                        throw AccountingError.validation("대체할 평가는 같은 원본 분개의 기존 조정이어야 합니다.")
                    }
                    guard successors[replacedID] == nil else { throw AccountingError.conflict("같은 평가를 두 번 대체할 수 없습니다: \(replacedID)") }
                    successors[replacedID] = entry.id
                } else {
                    guard assessmentRoots[assessment.sourceEntryID] == nil else {
                        throw AccountingError.conflict("이미 평가가 있는 원본입니다. 기존 평가를 대체해 수정하세요: \(assessment.sourceEntryID)")
                    }
                    assessmentRoots[assessment.sourceEntryID] = entry.id
                }
                try noCycle(start: entry.id, label: "평가 이력", next: { entries[$0]?.assessment?.replacesEntryID })
            }
        }
    }

    /// Recorded entries plus only the latest successor of each adjustment chain.
    /// These remain separate postings; callers group them by assessment.sourceEntryID for comparison.
    static func entries(in archive: AccountingArchive, bookID: String, includeAdjustments: Bool) throws -> [AccountingEntry] {
        try validate(archive)
        guard archive.books.contains(where: { $0.id == bookID }) else { throw AccountingError.validation("장부를 찾을 수 없습니다: \(bookID)") }
        let superseded = Set(archive.entries.compactMap { $0.assessment?.replacesEntryID })
        return archive.entries.filter {
            $0.bookID == bookID && ($0.layer == .recorded || (includeAdjustments && !superseded.contains($0.id)))
        }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id < $1.id
        }
    }

    /// Signed balances in one book's minor units: debit positive, credit negative.
    /// Parent accounts are not rolled up here, so a trial balance never counts children twice.
    static func balances(in archive: AccountingArchive, bookID: String, includeAdjustments: Bool) throws -> [String: Int] {
        let effective = try entries(in: archive, bookID: bookID, includeAdjustments: includeAdjustments)
        var totals = Dictionary(uniqueKeysWithValues: archive.accounts.filter { $0.bookID == bookID }.map { ($0.id, 0) })
        for entry in effective {
            for posting in entry.postings {
                totals[posting.accountID] = try add(totals[posting.accountID] ?? 0,
                    posting.side == .debit ? posting.amount : -posting.amount)
            }
        }
        return totals
    }

    /// Nets a prepared source-plus-active-adjustments group into one visible journal.
    /// The caller selects active entries with entries(in:bookID:includeAdjustments:) once for the archive.
    static func netPostings(_ entries: [AccountingEntry]) throws -> [AccountingPosting] {
        guard Set(entries.map(\.bookID)).count <= 1 else { throw AccountingError.validation("서로 다른 장부의 분개를 합산할 수 없습니다.") }
        var totals: [String: Int] = [:]
        for entry in entries {
            try validateEntryShape(entry)
            for posting in entry.postings {
                totals[posting.accountID] = try add(totals[posting.accountID] ?? 0,
                    posting.side == .debit ? posting.amount : -posting.amount)
            }
        }
        return try totals.keys.sorted().compactMap { accountID in
            guard let amount = totals[accountID], amount != 0 else { return nil }
            let magnitude: Int
            if amount < 0 {
                let (value, overflow) = 0.subtractingReportingOverflow(amount)
                guard !overflow else { throw AccountingError.validation("순분개 금액이 정수 저장 범위를 초과했습니다.") }
                magnitude = value
            } else { magnitude = amount }
            return AccountingPosting(accountID: accountID, side: amount > 0 ? .debit : .credit, amount: magnitude)
        }
    }

    /// Reclassifies one posting without changing the original source fact.
    /// Rounds to the nearest minor unit, ties upward, without overflowing amount * basisPoints.
    static func reclassify(source: AccountingEntry, postingIndex: Int, targetAccountID: String, basisPoints: Int,
                           id: String, assessment: AccountingAssessment, recordedAt: Date) throws -> AccountingEntry {
        try validateEntryShape(source)
        guard source.layer == .recorded, source.assessment == nil, assessment.sourceEntryID == source.id else {
            throw AccountingError.validation("재분류는 평가가 없는 원본 분개를 참조해야 합니다.")
        }
        try validateAssessment(assessment)
        try text(id, "조정 분개 ID"); try text(targetAccountID, "재분류 대상 계정")
        guard source.postings.indices.contains(postingIndex) else { throw AccountingError.validation("재분류할 분개 항목을 찾을 수 없습니다.") }
        guard (0...10_000).contains(basisPoints) else { throw AccountingError.validation("재분류 비율은 0~100%이어야 합니다.") }
        let original = source.postings[postingIndex]
        if basisPoints == 0 {
            guard assessment.replacesEntryID != nil else {
                throw AccountingError.validation("0%는 추가 재분류가 필요하지 않습니다. 기존 평가를 철회할 때만 저장합니다.")
            }
            let withdrawal = AccountingEntry(id: id, eventID: source.eventID, bookID: source.bookID,
                occurredAt: source.occurredAt, recordedAt: recordedAt, memo: source.memo, source: source.source,
                postings: [], layer: .adjustment, assessment: assessment)
            try validateEntryShape(withdrawal)
            return withdrawal
        }
        guard targetAccountID != original.accountID else { throw AccountingError.validation("재분류 대상은 원래 계정과 달라야 합니다.") }
        let whole = try multiply(original.amount / 10_000, basisPoints)
        let fraction = try add(try multiply(original.amount % 10_000, basisPoints), 5_000) / 10_000
        let amount = try add(whole, fraction)
        guard amount > 0 else { throw AccountingError.validation("재분류 금액이 최소 기록 단위보다 작습니다.") }
        let result = AccountingEntry(id: id, eventID: source.eventID, bookID: source.bookID,
            occurredAt: source.occurredAt, recordedAt: recordedAt, memo: source.memo, source: source.source,
            postings: [.init(accountID: targetAccountID, side: original.side, amount: amount),
                       .init(accountID: original.accountID, side: original.side.opposite, amount: amount)],
            layer: .adjustment, assessment: assessment)
        try validateEntryShape(result)
        return result
    }

    private static func validateEntryShape(_ entry: AccountingEntry) throws {
        try text(entry.id, "분개 ID"); try text(entry.eventID, "활동 ID"); try text(entry.bookID, "장부 ID")
        try text(entry.source, "출처")
        guard entry.memo.count <= 20_000 else { throw AccountingError.validation("분개 메모는 20,000자까지 저장합니다.") }
        if let sourceRecordID = entry.sourceRecordID { try text(sourceRecordID, "출처 기록 ID") }
        for date in [entry.occurredAt, entry.recordedAt] {
            guard date.timeIntervalSince1970.isFinite, LifeJSON.parseTimestamp(LifeJSON.timestamp(date)) != nil else {
                throw AccountingError.validation("분개의 발생·기록 시각이 유효하지 않습니다.")
            }
        }
        // A replacement with no postings explicitly withdraws the earlier estimate; it cannot create a source fact.
        let withdrawal = entry.layer == .adjustment && entry.assessment?.replacesEntryID != nil && entry.postings.isEmpty
        guard entry.postings.count >= 2 || withdrawal else { throw AccountingError.validation("분개에는 두 개 이상의 차변·대변 항목이 필요합니다.") }
        var debit = 0, credit = 0
        for posting in entry.postings {
            try text(posting.accountID, "분개 계정 ID")
            guard posting.amount > 0 else { throw AccountingError.validation("분개 금액은 양의 정수여야 합니다. 방향은 차변·대변으로 표시하세요.") }
            if posting.side == .debit { debit = try add(debit, posting.amount) }
            else { credit = try add(credit, posting.amount) }
        }
        guard debit == credit else { throw AccountingError.validation("분개의 차변과 대변 합계가 일치하지 않습니다.") }
    }

    private static func validateAssessment(_ assessment: AccountingAssessment) throws {
        try text(assessment.sourceEntryID, "평가 원본 분개 ID")
        guard !assessment.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assessment.rationale.count <= 20_000, (0...10_000).contains(assessment.confidenceBasisPoints) else {
            throw AccountingError.validation("평가에는 근거와 0~100% 범위의 신뢰도가 필요합니다.")
        }
        if let model = assessment.model { try text(model, "평가 모델") }
        if let replaced = assessment.replacesEntryID { try text(replaced, "대체 평가 ID") }
    }

    private static func text(_ value: String, _ name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 500 else {
            throw AccountingError.validation("\(name)은 비어 있지 않은 500자 이하 문자열이어야 합니다.")
        }
    }

    private static func indexed<T>(_ values: [T], kind: String, id: KeyPath<T, String>) throws -> [String: T] {
        var output: [String: T] = [:]
        for value in values {
            let key = value[keyPath: id]
            guard output[key] == nil else { throw AccountingError.validation("\(kind) ID가 중복됐습니다: \(key)") }
            output[key] = value
        }
        return output
    }

    private static func noCycle(start: String, label: String, next: (String) -> String?) throws {
        var visited: Set<String> = [], current: String? = start
        while let id = current {
            guard visited.insert(id).inserted else { throw AccountingError.validation("\(label)에 순환 참조가 있습니다: \(id)") }
            current = next(id)
        }
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AccountingError.validation("분개 합계가 정수 저장 범위를 초과했습니다.") }
        return value
    }

    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw AccountingError.validation("분개 계산이 정수 저장 범위를 초과했습니다.") }
        return value
    }
}
