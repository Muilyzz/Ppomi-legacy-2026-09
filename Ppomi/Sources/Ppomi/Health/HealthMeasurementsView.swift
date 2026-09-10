import SwiftUI
import Charts

/// The measurement section owns display composition; its range belongs to the retained page.
struct HealthMeasurementsView: View {
    let records: [LifeRecord]
    @Binding var range: Int

    private var measurements: [LifeRecord] { records.filter { $0.kind == .measurement } }
    private var plotted: [LifeRecord] {
        let start = range == 0 ? Date.distantPast : Calendar.current.date(byAdding: .month, value: -range, to: Date())!
        return measurements.filter { $0.occurredAt >= start }.sorted { $0.occurredAt < $1.occurredAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if measurements.isEmpty { emptyState } else {
                latestMetrics
                Picker("기간", selection: $range) {
                    Text("전체").tag(0); Text("1년").tag(12); Text("3개월").tag(3); Text("1개월").tag(1)
                }.pickerStyle(.segmented).frame(maxWidth: 380)
                ForEach(["weight", "skeletalMuscleMass", "bodyFatPercent"], id: \.self) { code in
                    HealthMetricChart(records: plotted, code: code)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "waveform.path.ecg").font(.ppomi(6)).foregroundStyle(.accentFg)
            Text("첫 측정").font(.ppomi(4, weight: .medium))
            Text("인바디 앱 › 더보기 › 인바디결과관리 열고 ‘인바디 화면 읽기’")
                .foregroundStyle(.fg2)
            Text("지금은 화면·이미지만")
                .font(.ppomi(1)).foregroundStyle(.fg2)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.surface2, in: RoundedRectangle(cornerRadius: 16))
    }
    private var latestMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let record = measurements.first(where: { $0.method != .aiEstimate }) {
                Text("최근 측정 · \(record.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(record.device ?? "기기 미기록")")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 10) {
                    ForEach(record.metrics.prefix(7)) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(metric.title).font(.ppomi(1)).foregroundStyle(.fg2)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(metric.value.formatted(.number.precision(.fractionLength(0...3)))).font(.ppomi(6, weight: .medium)).tracking(-0.01 * Fonts.size(6)).monospacedDigit()
                                Text(metric.unit == "kg/m2" ? "kg/m²" : metric.unit).font(.ppomi(1)).foregroundStyle(.fg2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.surface2, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

struct HealthWeeklySummaryView: View {
    let records: [LifeRecord]
    var body: some View { weeklySummary }

    private var weeklySummary: some View {
        let summary = HealthSummary(records: records)
        return VStack(alignment: .leading, spacing: 10) {
            Text("최근 7일").font(.ppomi(3, weight: .medium))
            Text(summary.text).font(.ppomi(2)).foregroundStyle(.fg2)
            Text("미기록 ≠ 0")
                .font(.ppomi(1)).foregroundStyle(.fg2)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.surface2, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct HealthMetricChart: View {
    let records: [LifeRecord]
    let code: String
    private struct Point: Identifiable { var id: String; var date: Date; var value: Double; var device: String }
    private var points: [Point] {
        records.compactMap { r in r.metrics.first { $0.code == code }.map { .init(id: r.id, date: r.occurredAt, value: $0.value, device: (r.device ?? "기기 미기록") + " · " + r.method.title) } }
    }
    var body: some View {
        let field = InBodyImport.fields.first { $0.code == code }!
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(field.title).font(.ppomi(3, weight: .medium)); Text(field.unit).font(.ppomi(1)).foregroundStyle(.fg2); Spacer(); Text("\(points.count)회").font(.ppomi(1)).foregroundStyle(.fg2) }
            if points.isEmpty { Text("측정 없음").font(.ppomi(2)).foregroundStyle(.fg2).frame(height: 120) }
            else {
                Chart(points) { point in
                    PointMark(x: .value("측정일", point.date), y: .value(field.title, point.value))
                        .foregroundStyle(by: .value("기기", point.device)).symbolSize(35)
                }
                .chartForegroundStyleScale(range: [Color.accent, .fg, .accentFg, .fg2])
                .chartYScale(domain: yDomain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine().foregroundStyle(.line); AxisTick().foregroundStyle(.line); AxisValueLabel().foregroundStyle(.fg2) } }
                .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(.line); AxisValueLabel().foregroundStyle(.fg2) } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 155)
                .accessibilityLabel("\(field.title) 추이 · \(points.count)건")
            }
        }.padding(18).background(.surface2, in: RoundedRectangle(cornerRadius: 14))
    }
    private var yDomain: ClosedRange<Double> {
        let lo = points.map(\.value).min() ?? 0, hi = points.map(\.value).max() ?? 1
        let padding = max((hi - lo) * 0.2, 0.5)
        return max(0, lo - padding)...(hi + padding)
    }
}
