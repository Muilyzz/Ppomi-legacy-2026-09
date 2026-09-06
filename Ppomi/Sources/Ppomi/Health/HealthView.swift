import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

@MainActor
// Ledger.Observation shadows the Observation framework macro; match existing app ownership.
final class HealthModel: ObservableObject {
    @Published var allHealthRecords: [LifeRecord] = []
    @Published var people: [LifeEntity] = []
    @Published var subjectID = ""
    @Published var selfID = ""
    var records: [LifeRecord] { allHealthRecords.filter { $0.subjectID == subjectID } }
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?

    func reload() {
        do {
            let store = try LifeStore()
            selfID = try store.ensureSelfEntity().id
            people = try store.entities().filter { $0.kind == .person }
            if !people.contains(where: { $0.id == subjectID }) { subjectID = selfID }
            allHealthRecords = try store.allRecords().filter { ![.financialSnapshot, .financialTransaction].contains($0.kind) }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    func perform(_ action: @escaping (LifeStore) throws -> String) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try action(LifeStore()) }
            }.value
            busy = false
            switch result {
            case .success(let text): reload(); message = text
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct HealthView: View {
    @StateObject private var model = HealthModel()
    @State private var range = 0
    @State private var editor: HealthEditorTarget?
    @State private var selected: LifeRecord?

    private var measurements: [LifeRecord] { model.records.filter { $0.kind == .measurement } }
    private var plotted: [LifeRecord] {
        let start = range == 0 ? Date.distantPast : Calendar.current.date(byAdding: .month, value: -range, to: Date())!
        return measurements.filter { $0.occurredAt >= start }.sorted { $0.occurredAt < $1.occurredAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("health-import-status") }
                if model.busy { ProgressView("기록 읽는 중…") }
                if measurements.isEmpty { emptyState } else {
                    latestMetrics
                    Picker("기간", selection: $range) {
                        Text("전체").tag(0); Text("1년").tag(12); Text("3개월").tag(3); Text("1개월").tag(1)
                    }.pickerStyle(.segmented).frame(maxWidth: 380)
                    ForEach(["weight", "skeletalMuscleMass", "bodyFatPercent"], id: \.self) { code in
                        HealthMetricChart(records: plotted, code: code)
                    }
                }
                weeklySummary
                recordList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.045))
        .task { model.reload() }
        .sheet(item: $editor) { target in HealthRecordEditor(target: target, model: model) }
        .sheet(item: $selected) { record in
            HealthRecordDetail(record: record, onEdit: {
                selected = nil
                DispatchQueue.main.async { editor = HealthEditorTarget(record: record) }
            }, onReviewed: {
                model.perform { store in try store.markReviewed(id: record.id, expectedPrevious: record); return "기록을 직접 확인한 것으로 표시했습니다." }
                selected = nil
            })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("몸과 생활").font(.system(size: 26, weight: .semibold))
                    Text("측정, 식사, 움직임을 같은 시간 위에서").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("기록 새로 읽기")
            }
            ViewThatFits(in: .horizontal) {
                HStack { captureButton; addButton; moreMenu }
                VStack(alignment: .leading) { captureButton; HStack { addButton; moreMenu } }
            }.disabled(model.busy)
            if model.people.count > 1 {
                Picker("기록 대상", selection: $model.subjectID) {
                    ForEach(model.people) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 300)
            }
        }
    }
    private var captureButton: some View {
        Button("현재 인바디 화면 읽기", systemImage: "iphone.and.arrow.forward") {
            model.perform { try InBodyImport.capture(to: $0) }
        }.buttonStyle(.borderedProminent).tint(Color(red: 0.15, green: 0.48, blue: 0.48)).accessibilityIdentifier("inbody-capture")
            .disabled(model.subjectID != model.selfID)
            .help("연결된 인바디 앱은 내 기록으로 가져옵니다")
    }
    private var addButton: some View {
        Button("기록 추가", systemImage: "plus") { editor = HealthEditorTarget(subjectID: model.subjectID) }
    }
    private var moreMenu: some View {
        Menu("가져오기·내보내기") {
            Button("인바디 결과 이미지 가져오기…") { importFile(image: true) }
                .disabled(model.subjectID != model.selfID)
            Button("기록 JSON 가져오기…") { importFile(image: false) }
            Divider()
            Button("전체 기록 JSON 저장…") { exportFile(schema: false) }
            Button("Schema.org JSON-LD 저장…") { exportFile(schema: true) }
            Button("가져오기 예시 저장…") { saveFile(data: { try LifeExamples.importTemplate() }, name: "ppomi-records-example.json") }
            Divider()
            Button("기존 금융 장부를 공통 기록에 반영") {
                model.perform { try LifeFinanceImport.run(to: $0) }
            }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 32)).foregroundStyle(.mint)
            Text("첫 측정부터 시작하세요").font(.title3.bold())
            Text("인바디 앱의 더보기 → 인바디결과관리에서 목록이나 측정 상세를 열고 ‘현재 인바디 화면 읽기’를 누르세요. 읽은 값은 원본과 함께 검토 전 기록으로 저장됩니다.")
                .foregroundStyle(.secondary)
            Text("기기와 API 연결 조건은 확인 후 연결합니다. 지금은 앱에 보이는 기록과 결과 이미지를 가져올 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
    private var latestMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let record = measurements.first(where: { $0.method != .aiEstimate }) {
                Text("최근 측정 · \(record.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(record.device ?? "기기 미기록")")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 10) {
                    ForEach(record.metrics.prefix(7)) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(metric.title).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(metric.value.formatted(.number.precision(.fractionLength(0...3)))).font(.system(size: 25, weight: .medium, design: .rounded))
                                Text(metric.unit == "kg/m2" ? "kg/m²" : metric.unit).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
    private var weeklySummary: some View {
        let summary = HealthSummary(records: model.records)
        return VStack(alignment: .leading, spacing: 10) {
            Text("최근 7일 돌아보기").font(.headline)
            Text(summary.text).font(.callout).foregroundStyle(.secondary)
            Text("함께 변한 패턴을 살펴보는 기록입니다. 미기록은 ‘안 함’이나 0으로 계산하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private var recordList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("기록과 근거 · \(model.records.count)건").font(.headline)
            ForEach(model.records.prefix(300)) { record in
                Button { selected = record } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: record.kind == .measurement ? "chart.xyaxis.line" : record.kind == .meal ? "fork.knife" : record.kind == .exercise ? "figure.walk" : "sun.max")
                            .foregroundStyle(.mint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.kind.title + " · " + record.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                            Text(record.metrics.map { "\($0.title) \($0.value.formatted()) \($0.unit)" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if record.kind != .measurement, let note = record.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text([record.sourceName, record.device, record.method.title, record.review == .userConfirmed ? "직접 확인" : "검토 전"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(record.review == .userConfirmed ? Color.secondary : Color.orange)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
    private func importFile(image: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = image ? [.image] : [.json]; panel.allowsMultipleSelection = false
        panel.prompt = "가져오기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.perform { store in
            if image { return try InBodyImport.importImage(url, to: store) }
            let result = try store.importJSON(Data(contentsOf: url))
            return "\(result.inserted)건 가져옴 · 기존 기록 \(result.duplicates)건"
        }
    }
    private func exportFile(schema: Bool) {
        saveFile(data: { let store = try LifeStore(); return try schema ? store.exportJSONLD() : store.exportJSON() },
                 name: schema ? "ppomi-records.jsonld" : "ppomi-records.json")
    }
    private func saveFile(data: @escaping () throws -> Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.perform { _ in
            try data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "선택한 파일에 저장했습니다."
        }
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
            HStack { Text(field.title).font(.headline); Text(field.unit).font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(points.count)회 측정").font(.caption).foregroundStyle(.secondary) }
            if points.isEmpty { Text("이 기간에 기록된 측정이 없습니다").font(.callout).foregroundStyle(.secondary).frame(height: 120) }
            else {
                Chart(points) { point in
                    PointMark(x: .value("측정일", point.date), y: .value(field.title, point.value))
                        .foregroundStyle(by: .value("기기", point.device)).symbolSize(35)
                }
                .chartYScale(domain: yDomain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 155)
                .accessibilityLabel(field.title + " 측정 추이, " + String(points.count) + "건. 빈 날짜에는 측정값을 만들지 않습니다.")
            }
        }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
    private var yDomain: ClosedRange<Double> {
        let lo = points.map(\.value).min() ?? 0, hi = points.map(\.value).max() ?? 1
        let padding = max((hi - lo) * 0.2, 0.5)
        return max(0, lo - padding)...(hi + padding)
    }
}

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
        let food = meals.isEmpty ? "식사: 아직 기록이 없습니다." : "식사 \(meals.count)건 기록."
        let exercise = workouts.isEmpty ? "운동: 아직 기록이 없습니다." : "운동 \(workouts.count)건" + (minutes.isEmpty ? " · 시간 미기록." : " · 기록된 시간 \(minutes.reduce(0) { $0 + $1.value }.formatted())분.")
        let wellbeing = checkIns.isEmpty ? "컨디션: 아직 기록이 없습니다." : "기록된 컨디션 평균 \((checkIns.reduce(0) { $0 + $1.value } / Double(checkIns.count)).formatted(.number.precision(.fractionLength(1))))/5 · \(checkIns.count)건."
        text = ([food, exercise, wellbeing] + (estimates.isEmpty ? [] : ["AI 추정 \(estimates.count)건은 위 건수·합계에서 제외했습니다."]) + ["다음 행동은 이 기록을 보고 한 가지씩 정해 보세요."]).joined(separator: "\n")
    }
}
