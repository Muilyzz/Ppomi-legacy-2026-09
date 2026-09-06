import Foundation

/// A log of the user's confirmation, not a timer, adherence score, or inference from a photograph.
enum SunCare {
    static let activityID = "sunscreen"
    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }
    enum LogResult: Equatable { case recorded(String), alreadyRecorded(String), restored(String) }
    struct Day: Identifiable, Equatable {
        enum Status: String { case completed, unrecorded }
        var date: Date
        var dayKey: String
        var dayLabel: String
        var status: Status
        var id: String { dayKey }
        var isCompleted: Bool { status == .completed }
    }
    struct Summary: Equatable {
        var last7DaysCount: Int
        var last28DaysCount: Int
        var todayCompleted: Bool
        var cells: [Day]
    }

    /// Called only by an explicit user report/button. `at` is the confirmation time for this day;
    /// it does not claim to know the actual application time.
    @discardableResult
    static func logApplication(subjectID: String, at: Date, to store: LifeStore,
                               calendar: Calendar = defaultCalendar) throws -> LogResult {
        try requirePerson(subjectID, store: store)
        let day = dayKey(at, calendar: calendar)
        let existing = try store.allRecords().filter { isApplication($0, subjectID: subjectID) && $0.activityDay == day }
        if let completed = existing.first(where: { $0.activityStatus == .completed }) { return .alreadyRecorded(completed.id) }
        let sourceID = subjectID + ":" + activityID + ":" + calendar.timeZone.identifier + ":" + day
        let note = "이 날짜에 선크림을 발랐다고 확인한 기록입니다. 표시 시각은 확인 시각이며 실제 도포 시각은 별도 기록하지 않았습니다."
        if let previous = existing.first(where: { $0.sourceName == "Ppomi habit" && $0.sourceRecordID == sourceID }) {
            var value = previous
            value.activityStatus = .completed; value.occurredAt = at; value.note = note; value.review = .unreviewed
            try store.revise(value, reason: "사용자가 선크림 완료를 다시 확인함", expectedPrevious: previous)
            return .restored(value.id)
        }
        let value = LifeRecord(subjectID: subjectID, kind: .habit, occurredAt: at,
                               sourceName: "Ppomi habit", sourceRecordID: sourceID, method: .manual,
                               note: note, activityID: activityID, activityStatus: .completed,
                               activityDay: day, activityTimeZone: calendar.timeZone.identifier)
        switch try store.save(value) {
        case .inserted(let id): return .recorded(id)
        case .duplicate(let id): return .alreadyRecorded(id)
        }
    }

    /// Explicitly retracts this day's reports, including both button and spoken reports.
    /// The day returns to unrecorded; it does not become an assertion that sunscreen was not used.
    @discardableResult
    static func retractApplication(subjectID: String, on date: Date, to store: LifeStore,
                                   calendar: Calendar = defaultCalendar) throws -> Int {
        try requirePerson(subjectID, store: store)
        let day = dayKey(date, calendar: calendar)
        let previous = try store.allRecords().filter {
            isApplication($0, subjectID: subjectID) && $0.activityStatus == .completed && $0.activityDay == day
        }
        for record in previous {
            var value = record; value.activityStatus = .retracted; value.review = .unreviewed
            try store.revise(value, reason: "사용자가 이 날짜의 선크림 완료 표시를 취소함", expectedPrevious: record)
        }
        return previous.count
    }

    static func summary(records: [LifeRecord], subjectID: String, now: Date,
                        calendar: Calendar = defaultCalendar) -> Summary {
        let today = calendar.startOfDay(for: now)
        let completed = Set(records.filter {
            isApplication($0, subjectID: subjectID) && $0.activityStatus == .completed && $0.occurredAt <= now
        }.compactMap(\.activityDay))
        let cells = (-27...0).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = dayKey(date, calendar: calendar)
            let parts = calendar.dateComponents([.month, .day], from: date)
            return Day(date: date, dayKey: key, dayLabel: "\(parts.month ?? 0)/\(parts.day ?? 0)",
                       status: completed.contains(key) ? .completed : .unrecorded)
        }
        return Summary(last7DaysCount: cells.suffix(7).filter(\.isCompleted).count,
                       last28DaysCount: cells.filter(\.isCompleted).count,
                       todayCompleted: cells.last?.isCompleted ?? false, cells: cells)
    }

    static func dayKey(_ date: Date, calendar: Calendar = defaultCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private static func isApplication(_ record: LifeRecord, subjectID: String) -> Bool {
        record.subjectID == subjectID && record.kind == .habit && record.activityID == activityID && record.method == .manual &&
            record.activityDay != nil && record.activityTimeZone != nil
    }
    private static func requirePerson(_ id: String, store: LifeStore) throws {
        guard let person = try store.entity(id: id), person.kind == .person else { throw LifeError.validation("등록된 사람의 ID가 필요합니다.") }
    }
}
