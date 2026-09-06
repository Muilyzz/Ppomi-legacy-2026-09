import XCTest
@testable import Ppomi

final class HealthEntryTests: XCTestCase {
    func testBlankNutritionIsMissingAndInvalidNumberDoesNotSilentlyDisappear() throws {
        XCTAssertTrue(try HealthEntry.metrics(kind: .meal, values: ["energy": " ", "protein": ""]).isEmpty)
        XCTAssertThrowsError(try HealthEntry.metrics(kind: .meal, values: ["energy": "약 500"]))
        XCTAssertThrowsError(try HealthEntry.metrics(kind: .meal, values: ["energy": "1,250"]))
        XCTAssertThrowsError(try HealthEntry.metrics(kind: .checkIn, values: ["wellbeing": "8"]))
        XCTAssertThrowsError(try HealthEntry.metrics(kind: .exercise, values: ["steps": "12.5"]))
        let metrics = try HealthEntry.metrics(kind: .meal, values: ["energy": "420", "weight": "75"])
        XCTAssertEqual(metrics.map(\.code), ["energy"])
    }

    func testSummaryCountsObservedRecordsAndExcludesFutureAndOldRecords() throws {
        let now = try XCTUnwrap(LifeJSON.parseTimestamp("2026-09-06T12:00:00+09:00"))
        func record(_ kind: LifeRecord.Kind, days: Double, metrics: [LifeMetric] = []) -> LifeRecord {
            LifeRecord(subjectID: "synthetic-person", kind: kind, occurredAt: now.addingTimeInterval(days * 86400),
                       sourceName: "synthetic", method: .manual, metrics: metrics, note: "가상 테스트")
        }
        let text = HealthSummary(records: [record(.meal, days: -1), record(.meal, days: -9), record(.meal, days: 1),
                                           record(.exercise, days: -1), record(.exercise, days: -2, metrics: [.init(code: "duration", title: "시간", value: 30, unit: "min")])], now: now).text
        XCTAssertTrue(text.contains("식사 1건"))
        XCTAssertTrue(text.contains("운동 2건"))
        XCTAssertTrue(text.contains("기록된 시간 30분"))
        XCTAssertTrue(text.contains("컨디션: 아직 기록이 없습니다"))
        let empty = HealthSummary(records: [], now: now).text
        XCTAssertFalse(empty.contains("0분"))
        XCTAssertFalse(empty.contains("평균 0"))
        var estimate = record(.exercise, days: -1, metrics: [.init(code: "duration", title: "시간", value: 90, unit: "min")])
        estimate.method = .aiEstimate
        let separate = HealthSummary(records: [record(.exercise, days: -1), estimate], now: now).text
        XCTAssertTrue(separate.contains("운동 1건 · 시간 미기록"))
        XCTAssertTrue(separate.contains("AI 추정 1건"))
        XCTAssertFalse(separate.contains("90분"))
    }
}
