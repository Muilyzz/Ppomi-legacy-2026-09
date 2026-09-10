import XCTest
@testable import Ppomi

final class DailyReportTests: XCTestCase {
    func testNextFireIsTodayBeforeNineAndTomorrowAfter() {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let night = cal.date(bySettingHour: 22, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(cal.component(.hour, from: DailyReport.nextFire(after: morning)), 21)
        XCTAssertTrue(cal.isDate(DailyReport.nextFire(after: morning), inSameDayAs: morning))
        XCTAssertTrue(cal.isDate(DailyReport.nextFire(after: night), inSameDayAs: cal.date(byAdding: .day, value: 1, to: night)!))
    }
}
