import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HealthEditorTarget: Identifiable {
    let id = UUID()
    var record: LifeRecord?
    var subjectID: String
    init(record: LifeRecord) { self.record = record; subjectID = record.subjectID }
    init(subjectID: String) { self.subjectID = subjectID }
}

struct HealthRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: HealthEditorTarget
    let model: HealthModel
    @State private var kind: LifeRecord.Kind
    @State private var date: Date
    @State private var values: [String: String]
    @State private var note: String
    @State private var device: String
    @State private var estimate: Bool
    @State private var attachment: URL?
    @State private var error: String?
    @State private var saving = false

    init(target: HealthEditorTarget, model: HealthModel) {
        self.target = target; self.model = model
        _kind = State(initialValue: target.record?.kind ?? .meal)
        _date = State(initialValue: target.record?.occurredAt ?? Date())
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: (target.record?.metrics ?? []).map { ($0.code, String($0.value)) }))
        _note = State(initialValue: target.record?.note ?? "")
        _device = State(initialValue: target.record?.device ?? "")
        _estimate = State(initialValue: target.record?.method == .aiEstimate)
    }

    private var fields: [(code: String, title: String, unit: String)] { HealthEntry.fields(for: kind) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.record == nil ? "생활 기록" : "기록 수정").font(.title2.bold())
            Form {
                Picker("종류", selection: $kind) {
                    ForEach([LifeRecord.Kind.meal, .exercise, .checkIn, .measurement], id: \.self) { Text($0.title).tag($0) }
                }.disabled(target.record != nil)
                DatePicker("발생 시각", selection: $date, displayedComponents: [.date, .hourAndMinute])
                if kind == .measurement { TextField("측정 기기 (선택)", text: $device) }
                ForEach(fields, id: \.code) { field in
                    HStack {
                        Text(field.title).frame(width: 110, alignment: .leading)
                        TextField("미기록", text: Binding(get: { values[field.code] ?? "" }, set: { values[field.code] = $0 }))
                        Text(field.unit).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    }
                }
                Text("모르는 수치는 비워 두세요. 사진만으로 영양소나 운동량을 채우지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("수치에 AI 추정이 포함되어 있음", isOn: $estimate)
                Text(kind == .meal ? "먹은 음식·양·메모" : kind == .exercise ? "운동 종류·메모" : "메모").font(.headline)
                TextEditor(text: $note).frame(height: 95).border(.secondary.opacity(0.3))
                HStack {
                    Button("사진·결과지 첨부…") { chooseAttachment() }
                    if let attachment { Text(attachment.lastPathComponent).font(.caption).lineLimit(1) }
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("이 Mac의 비공개 기록에 저장됩니다").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "저장 중…" : "저장") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530).disabled(saving)
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .pdf]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { attachment = panel.url }
    }
    private func save() {
        do {
            let metrics = try HealthEntry.metrics(kind: kind, values: values)
            var record = target.record ?? LifeRecord(subjectID: target.subjectID, kind: kind, occurredAt: date,
                                                     sourceName: "직접 기록", method: .manual)
            record.occurredAt = date; record.metrics = metrics
            record.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
            record.device = device.isEmpty ? nil : device
            record.method = estimate ? .aiEstimate : .manual
            record.review = .unreviewed
            // Evidence-only entries become valid after the chosen file is copied by the store.
            if attachment == nil { try record.validate() }
            let draft = record, file = attachment, previous = target.record
            saving = true; error = nil
            Task {
                let result = await Task.detached { () -> Result<Void, Error> in
                    Result {
                        let store = try LifeStore(); var value = draft
                        if let file {
                            let evidence = try store.addEvidence(from: file)
                            if !value.evidenceIDs.contains(evidence.id) { value.evidenceIDs.append(evidence.id) }
                        }
                        if let previous { try store.revise(value, reason: "기록 편집 화면에서 직접 수정", expectedPrevious: previous) }
                        else { _ = try store.save(value) }
                    }
                }.value
                saving = false
                switch result {
                case .success: model.reload(); model.message = "기록을 저장했습니다."; dismiss()
                case .failure(let e): error = e.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

enum HealthEntry {
    static func fields(for kind: LifeRecord.Kind) -> [(code: String, title: String, unit: String)] {
        switch kind {
        case .measurement: return InBodyImport.fields.map { ($0.code, $0.title, $0.unit) } + [("waistHipRatio", "허리엉덩이비", "ratio")]
        case .meal: return [("energy", "열량", "kcal"), ("protein", "단백질", "g"), ("carbohydrate", "탄수화물", "g"), ("fat", "지방", "g")]
        case .exercise: return [("duration", "운동 시간", "min"), ("distance", "거리", "km"), ("steps", "걸음 수", "count"), ("energy", "소모 열량", "kcal")]
        case .checkIn: return [("wellbeing", "컨디션 (1~5)", "score/5")]
        default: return []
        }
    }
    static func metrics(kind: LifeRecord.Kind, values: [String: String]) throws -> [LifeMetric] {
        try fields(for: kind).compactMap { field in
            let raw = (values[field.code] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            guard raw.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil, let value = Double(raw) else {
                throw LifeError.validation("\(field.title)에 숫자를 입력해 주세요. 소수점은 점(.)을 사용합니다.")
            }
            let metric = LifeMetric(code: field.code, title: field.title, value: value, unit: field.unit)
            try metric.validate(); return metric
        }
    }
}

struct HealthRecordDetail: View {
    @Environment(\.dismiss) private var dismiss
    let record: LifeRecord
    let onEdit: () -> Void
    let onReviewed: () -> Void
    @State private var evidence: [LifeEvidence] = []
    @State private var revisions: [LifeRevision] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(record.kind.title).font(.title2.bold()); Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(record.kind == .habit ? "확인 시각" : "발생 시각", value: record.occurredAt.formatted(date: .complete, time: .shortened))
                    if record.kind == .habit {
                        LabeledContent("습관", value: record.activityID ?? "미기록")
                        LabeledContent("활동 날짜", value: record.activityDay ?? "미기록")
                        LabeledContent("날짜 기준", value: record.activityTimeZone ?? "미기록")
                        LabeledContent("완료 표시", value: record.activityStatus == .retracted ? "취소됨" : "기록됨")
                    }
                    LabeledContent("수집 시각", value: record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("출처", value: record.sourceName)
                    if let device = record.device { LabeledContent("기기", value: device) }
                    LabeledContent("기록 방식", value: record.method.title)
                    LabeledContent("검토", value: record.review == .userConfirmed ? "직접 확인" : "검토 전")
                    Divider()
                    ForEach(record.metrics) { metric in
                        LabeledContent(metric.title, value: "\(metric.value.formatted()) \(metric.unit)")
                    }
                    if let note = record.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                    if !evidence.isEmpty {
                        Divider(); Text("원본 근거").font(.headline)
                        ForEach(evidence) { item in Button(item.originalName, systemImage: "doc.viewfinder") { open(item) } }
                    }
                    if !revisions.isEmpty {
                        Divider(); Text("수정 이력 · \(revisions.count)회").font(.headline)
                        ForEach(revisions) { revision in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.replacedAt.formatted() + " · " + revision.reason).font(.caption)
                                Text("이전 값: " + revision.previous.metrics.map { "\($0.title) \($0.value.formatted()) \($0.unit)" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }.padding(.trailing, 8)
            }
            HStack {
                Button("수정") { onEdit() }.disabled(record.kind == .habit)
                Spacer()
                Button("원본과 직접 확인했어요") { onReviewed() }.disabled(record.review == .userConfirmed)
            }
        }.padding(24).frame(width: 540, height: 630)
        .task {
            do {
                let store = try LifeStore()
                evidence = try store.evidence().filter { record.evidenceIDs.contains($0.id) }
                revisions = try store.revisions(recordID: record.id)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func open(_ item: LifeEvidence) {
        do {
            guard let url = try LifeStore().managedEvidenceURL(id: item.id) else { throw LifeError.missing("이 Mac에 원본 파일이 없습니다.") }
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
}
