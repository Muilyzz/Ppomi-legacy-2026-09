import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HealthView: View {
    @Environment(\.recordsPageIsActive) private var isActive
    @StateObject private var model = HealthModel()
    @State private var range = 0
    @State private var editor: HealthEditorTarget?
    @State private var selected: LifeRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.bad).font(.ppomi(2))
                }
                if !model.message.isEmpty { Text(model.message).font(.ppomi(1)).foregroundStyle(.fg2).accessibilityIdentifier("health-import-status") }
                if model.busy || model.loading { ProgressView("읽는 중…") }
                SunCareCard(model: model)
                HealthMeasurementsView(records: model.records, range: $range)
                HealthWeeklySummaryView(records: model.records)
                HealthHistoryView(records: model.records, subjectID: model.subjectID) { selected = $0 }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.surface)
        .ppomiTheme()
        .task(id: isActive) {
            guard isActive else { return }
            await model.reloadSnapshot()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await model.refreshIfChanged()
            }
        }
        .sheet(item: $editor) { target in HealthRecordEditor(target: target, model: model) }
        .sheet(item: $selected) { record in
            HealthRecordDetail(record: record, onEdit: {
                selected = nil
                DispatchQueue.main.async { editor = HealthEditorTarget(record: record) }
            }, onReviewed: {
                model.perform { store in try store.markReviewed(id: record.id, expectedPrevious: record); return "직접 확인 표시됨" }
                selected = nil
            })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("몸과 생활").font(.ppomi(6, weight: .medium)).tracking(-0.01 * Fonts.size(6))
                    Text("측정·식사·움직임").font(.ppomi(2)).foregroundStyle(.fg2)
                }
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로 읽기")
                    .disabled(model.busy || model.loading)
            }
            ViewThatFits(in: .horizontal) {
                HStack { captureButton; addButton; moreMenu }
                VStack(alignment: .leading) { captureButton; HStack { addButton; moreMenu } }
            }.disabled(model.busy || model.loading || model.subjectID.isEmpty)
            if model.people.count > 1 {
                Picker("대상", selection: $model.subjectID) {
                    ForEach(model.people) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 300)
            }
        }
    }
    private var captureButton: some View {
        Button("인바디 화면 읽기", systemImage: "iphone.and.arrow.forward") {
            model.perform { try InBodyImport.capture(to: $0) }
        }.buttonStyle(.borderedProminent).foregroundStyle(.onAccent).accessibilityIdentifier("inbody-capture")
            .disabled(model.subjectID != model.selfID)
            .help("내 기록으로")
    }
    private var addButton: some View {
        Button("기록 추가", systemImage: "plus") { editor = HealthEditorTarget(subjectID: model.subjectID) }
    }
    private var moreMenu: some View {
        Menu("가져오기·내보내기") {
            Button("인바디 이미지…") { importFile(image: true) }
                .disabled(model.subjectID != model.selfID)
            Button("JSON 가져오기…") { importFile(image: false) }
            Divider()
            Button("JSON 저장…") { exportFile(schema: false) }
            Button("JSON-LD 저장…") { exportFile(schema: true) }
            Button("예시 저장…") { saveFile(data: { try LifeExamples.importTemplate() }, name: "ppomi-records-example.json") }
            Divider()
            Button("금융 장부 반영") {
                model.perform { try LifeFinanceImport.run(to: $0) }
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
            return "\(result.inserted)건 추가 · 중복 \(result.duplicates)건"
        }
    }
    private func exportFile(schema: Bool) {
        saveFile(data: {
            if SharedRecordVault.enabled {
                let archive = try SharedRecordsSource.decode(SharedHealthArchive.self, name: "health").archive
                return try schema ? LifeSchema.export(archive) : LifeJSON.encoder().encode(archive)
            }
            let store = try LifeStore(); return try schema ? store.exportJSONLD() : store.exportJSON()
        },
                 name: schema ? "ppomi-records.jsonld" : "ppomi-records.json")
    }
    private func saveFile(data: @escaping () throws -> Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.perform { _ in
            try data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "저장됨"
        }
    }
}
