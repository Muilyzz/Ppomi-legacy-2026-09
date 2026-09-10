import SwiftUI

/// Pagination limits the initial render without making older records unreachable.
struct HealthHistoryView: View {
    let records: [LifeRecord]
    let subjectID: String
    let onSelect: (LifeRecord) -> Void
    @State private var visibleCount = 300
    private var remaining: Int { max(0, records.count - visibleCount) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("기록 · \(records.count)건").font(.ppomi(3, weight: .medium))
            ForEach(records.prefix(visibleCount)) { record in
                Button { onSelect(record) } label: { HealthRecordRow(record: record) }
                    .buttonStyle(.plain)
                Divider()
            }
            if remaining > 0 {
                Button("더 보기 · \(remaining)건") {
                    visibleCount += min(300, remaining)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("health-history-load-more")
            }
        }
        .onChange(of: subjectID) { _, _ in visibleCount = 300 }
    }
}

private struct HealthRecordRow: View {
    let record: LifeRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.accentFg).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ppomi(2))
                Text(record.metrics.map { "\($0.title) \($0.value.formatted()) \($0.unit)" }.joined(separator: " · "))
                    .font(.ppomi(1)).foregroundStyle(.fg2).lineLimit(2)
                if record.kind != .measurement, let note = record.note {
                    Text(note).font(.ppomi(1)).foregroundStyle(.fg2).lineLimit(2)
                }
                Text([record.sourceName, record.device, record.method.title, record.review == .userConfirmed ? "직접 확인" : "검토 전"].compactMap { $0 }.joined(separator: " · "))
                    .font(.ppomi(1)).foregroundStyle(record.review == .userConfirmed ? Color.fg2 : Color.accentFg)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.ppomi(1)).foregroundStyle(.fg2)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch record.kind {
        case .measurement: "chart.xyaxis.line"
        case .meal: "fork.knife"
        case .exercise: "figure.walk"
        default: "sun.max"
        }
    }

    private var title: String {
        guard record.kind == .habit else {
            return record.kind.title + " · " + record.occurredAt.formatted(date: .abbreviated, time: .shortened)
        }
        let title = record.activityID == "sunscreen" ? "선크림" : "습관"
        let day = record.activityDay ?? "날짜 미기록"
        return title + " · " + day + (record.activityStatus == .retracted ? " · 취소" : " · 완료")
    }
}
