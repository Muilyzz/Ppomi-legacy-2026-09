import Foundation

struct HealthSummary {
    let text: String
    init(records: [LifeRecord], now: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let dated = records.filter { $0.occurredAt >= cutoff && $0.occurredAt <= now }
        let estimates = dated.filter { $0.method == .aiEstimate }
        let week = dated.filter { $0.method != .aiEstimate }
        let meals = week.filter { $0.kind == .meal }, workouts = week.filter { $0.kind == .exercise }
        let minutes = workouts.flatMap(\.metrics).filter { $0.code == "duration" }
        let checkIns = week.filter { $0.kind == .checkIn }.flatMap(\.metrics).filter { $0.code == "wellbeing" }
        let food = meals.isEmpty ? "식사 없음" : "식사 \(meals.count)건"
        let exercise = workouts.isEmpty ? "운동 없음" : "운동 \(workouts.count)건" + (minutes.isEmpty ? " · 시간 미기록" : " · \(minutes.reduce(0) { $0 + $1.value }.formatted())분")
        let wellbeing = checkIns.isEmpty ? "컨디션 없음" : "컨디션 평균 \((checkIns.reduce(0) { $0 + $1.value } / Double(checkIns.count)).formatted(.number.precision(.fractionLength(1))))/5 · \(checkIns.count)건"
        text = ([food, exercise, wellbeing] + (estimates.isEmpty ? [] : ["AI 추정 \(estimates.count)건 제외"])).joined(separator: "\n")
    }
}
