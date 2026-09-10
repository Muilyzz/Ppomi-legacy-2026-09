import Foundation

/// 정례 결산(비서의 일일 보고): 매일 정해진 시각에 오늘 지출을 톡으로만 남긴다. 전화는 절대 하지 않는다(docs/ui-tree.md).
enum DailyReport {
    static let hour = 21
    /// `after` 다음에 오는 첫 보고 시각(오늘 21:00이 지났으면 내일 21:00).
    static func nextFire(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }
}
