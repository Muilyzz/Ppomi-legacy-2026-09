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
            Text(target.record == nil ? "생활 기록" : "기록 수정").font(.ppomi(4, weight: .medium))
            Form {
                Picker("종류", selection: $kind) {
                    ForEach([LifeRecord.Kind.meal, .exercise, .checkIn, .measurement], id: \.self) { Text($0.title).tag($0) }
                }.disabled(target.record != nil)
                DatePicker("시각", selection: $date, displayedComponents: [.date, .hourAndMinute])
                if kind == .measurement { TextField("기기", text: $device) }
                ForEach(fields, id: \.code) { field in
                    HStack {
                        Text(field.title).frame(minWidth: 110, alignment: .leading)
                        TextField("미기록", text: Binding(get: { values[field.code] ?? "" }, set: { values[field.code] = $0 }))
                        Text(field.unit).foregroundStyle(.fg2).frame(minWidth: 60, alignment: .leading)
                    }
                }
                Text("모르면 비움")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
                Toggle("AI 추정 포함", isOn: $estimate)
                Text(kind == .meal ? "음식·양·메모" : kind == .exercise ? "운동·메모" : "메모").font(.ppomi(3, weight: .medium))
                TextEditor(text: $note).frame(minHeight: 95 * AppSettings.uiScale).border(.line2)
                HStack {
                    Button("첨부…") { chooseAttachment() }
                    if let attachment { Text(attachment.lastPathComponent).font(.ppomi(1)).lineLimit(1) }
                }
            }
            if let error { Text(error).foregroundStyle(.bad).font(.ppomi(2)) }
            HStack {
                Text(SharedRecordVault.enabled ? "암호화 서버 저장 · 첨부는 이 Mac" : "이 Mac에 저장").font(.ppomi(1)).foregroundStyle(.fg2)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "저장 중…" : "저장") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530).disabled(saving).background(.bg).ppomiTheme()
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
                        try SharedRecordsSource.publishIfEnabled("health")
                    }
                }.value
                saving = false
                switch result {
                case .success: model.reload(); model.message = "저장됨"; dismiss()
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
                throw LifeError.validation("\(field.title): 숫자만 (소수점 .)")
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
            HStack { Text(record.kind.title).font(.ppomi(4, weight: .medium)); Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("시각", value: record.occurredAt.formatted(date: .complete, time: .shortened))
                    if record.kind == .habit {
                        LabeledContent("습관", value: record.activityID ?? "미기록")
                        LabeledContent("날짜", value: record.activityDay ?? "미기록")
                        LabeledContent("시간대", value: record.activityTimeZone ?? "미기록")
                        LabeledContent("완료", value: record.activityStatus == .retracted ? "취소됨" : "기록됨")
                    }
                    LabeledContent("수집", value: record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("출처", value: record.sourceName)
                    if let device = record.device { LabeledContent("기기", value: device) }
                    LabeledContent("방식", value: record.method.title)
                    LabeledContent("검토", value: record.review == .userConfirmed ? "직접 확인" : "검토 전")
                    Divider()
                    ForEach(record.metrics) { metric in
                        LabeledContent(metric.title, value: "\(metric.value.formatted()) \(metric.unit)")
                    }
                    if let note = record.note { Text(note).font(.ppomi(2)).foregroundStyle(.fg2) }
                    if !evidence.isEmpty {
                        Divider(); Text("근거").font(.ppomi(3, weight: .medium))
                        ForEach(evidence) { item in Button(item.originalName, systemImage: "doc.viewfinder") { open(item) } }
                    }
                    if !revisions.isEmpty {
                        Divider(); Text("수정 · \(revisions.count)회").font(.ppomi(3, weight: .medium))
                        ForEach(revisions) { revision in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.replacedAt.formatted() + " · " + revision.reason).font(.ppomi(1))
                                Text("이전 " + revision.previous.metrics.map { "\($0.title) \($0.value.formatted()) \($0.unit)" }.joined(separator: " · "))
                                    .font(.ppomi(1)).foregroundStyle(.fg2)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.bad) }
                }.padding(.trailing, 8)
            }
            HStack {
                Button("수정") { onEdit() }.disabled(record.kind == .habit)
                Spacer()
                Button("직접 확인") { onReviewed() }.disabled(record.review == .userConfirmed)
            }
        }.padding(24).frame(width: 540, height: 630).background(.bg).ppomiTheme()
        .task {
            do {
                if SharedRecordVault.enabled {
                    let archive = try await Task.detached { try SharedRecordsSource.decode(SharedHealthArchive.self, name: "health").archive }.value
                    evidence = archive.evidence.filter { record.evidenceIDs.contains($0.id) }
                    revisions = archive.revisions.filter { $0.previous.id == record.id }
                } else {
                    let store = try LifeStore()
                    evidence = try store.evidence().filter { record.evidenceIDs.contains($0.id) }
                    revisions = try store.revisions(recordID: record.id)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func open(_ item: LifeEvidence) {
        do {
            guard let url = try LifeStore().managedEvidenceURL(id: item.id) else { throw LifeError.missing("원본 없음") }
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
}
