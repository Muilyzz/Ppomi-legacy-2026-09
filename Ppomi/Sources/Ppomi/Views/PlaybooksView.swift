import SwiftUI
import AppKit

struct PlaybooksView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.recordsPageIsActive) private var isActive
    @StateObject private var model = PlaybooksModel()
    @State private var selected: String?
    @State private var importError: String?
    @State private var browserError: String?
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("앱 플레이북").font(.ppomi(6, weight: .medium)).tracking(-0.01 * Fonts.size(6))
                        Text("절차와 재생 기록").font(.ppomi(2)).foregroundStyle(.fg2)
                    }
                    Spacer()
                    Button(action: importPlaybook) { Label(importing ? "가져오는 중…" : "가져오기", systemImage: "square.and.arrow.down") }
                        .help("가져오기")
                        .disabled(importing)
                    Button(action: model.reload) { Image(systemName: "arrow.clockwise") }.help("새로고침")
                        .disabled(model.loading)
                }
                if !model.issues.isEmpty {
                    DisclosureGroup("읽기 실패 \(model.issues.count)개") {
                        ForEach(model.issues) { issue in
                            Text("\(issue.directory.lastPathComponent): \(issue.message)").font(.ppomi(2)).textSelection(.enabled)
                        }
                    }.foregroundStyle(.fg2)
                }
                if let entry = model.entries.first(where: { $0.id == selected }) {
                    Button { selected = nil } label: { Label("모든 앱", systemImage: "chevron.left") }
                    detail(entry)
                } else {
                    if model.entries.isEmpty, model.loading {
                        ProgressView("읽는 중…")
                    } else if model.entries.isEmpty {
                        ContentUnavailableView("플레이북 없음", systemImage: "books.vertical", description: Text("폴더 가져오기"))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(model.entries) { entry in
                            Button { selected = entry.id } label: { card(entry) }.buttonStyle(.plain)
                                .accessibilityLabel("\(entry.record.name), \(entry.record.summary), \(entry.status)")
                        }
                    }
                    if !model.common.isEmpty {
                        DisclosureGroup("공통 규칙") { Text(model.common).font(.ppomi(2)).textSelection(.enabled).padding(.top, 8) }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .ppomiTheme()
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await model.reloadSnapshot()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: state.ledgerVersion) { _, _ in if isActive { model.reload() } }
        .onChange(of: model.entries.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected) { self.selected = nil }
        }
        .alert("가져오기 실패", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("열기 실패", isPresented: Binding(get: { browserError != nil }, set: { if !$0 { browserError = nil } })) {
            Button("확인", role: .cancel) { browserError = nil }
        } message: { Text(browserError ?? "") }
    }

    private func importPlaybook() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "플레이북 폴더"
        panel.message = "manifest.json이 있는 폴더"
        panel.prompt = "가져오기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let imported = try await Task.detached {
                    let record = try PlaybookCatalog.install(from: url, in: Playbooks.dir)
                    try SharedRecordsSource.publishIfEnabled("playbooks")
                    return record
                }.value
                await model.reloadSnapshot()
                selected = imported.id
            } catch { importError = error.localizedDescription }
        }
    }

    private func icon(_ entry: PlaybookEntry) -> some View {
        Group {
            if let image = model.icons[entry.id] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.ppomi(6)).foregroundStyle(.fg2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }

    private func card(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon(entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.record.name).font(.ppomi(3, weight: .medium))
                    Text(entry.installation).font(.ppomi(1)).foregroundStyle(.fg2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.fg2)
            }
            Text(entry.record.summary).font(.ppomi(2)).frame(maxWidth: .infinity, alignment: .leading)
            Label(entry.status, systemImage: entry.replayed.isEmpty ? "clock" : "checkmark.circle")
                .font(.ppomi(1)).foregroundStyle(entry.replayed.isEmpty ? Color.fg2 : Color.accentFg)
            Text("명세 \(entry.stepCount)단계 · 동작 \(entry.footprints.count)개")
                .font(.ppomi(1)).foregroundStyle(.fg2)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(.surface2, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
    }

    private func detail(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) { icon(entry); VStack(alignment: .leading, spacing: 4) {
                Text(entry.record.name).font(.ppomi(4, weight: .medium))
                Text(entry.record.summary).foregroundStyle(.fg2)
                Text("버전 \(entry.record.manifest.version) · \(entry.installation)").font(.ppomi(1)).foregroundStyle(.fg2)
            } }
            if let url = entry.record.manifest.launch.browserURL {
                Button {
                    Task {
                        do { try await Task.detached { try MacBrowser.open(url) }.value }
                        catch { browserError = error.localizedDescription }
                    }
                } label: { Label("Chrome 열기", systemImage: "arrow.up.right.square") }
                Text("로그인은 브라우저에서").font(.ppomi(1)).foregroundStyle(.fg2)
            }
            if let url = entry.record.manifest.launch.windowsURL {
                Button {
                    Task {
                        do { try await Task.detached { try Desk.open(url.absoluteString) }.value }
                        catch { browserError = error.localizedDescription }
                    }
                } label: { Label("Windows에서 열기", systemImage: "arrow.up.right.square") }
                Text("exe·공동인증서는 Parallels Windows에서").font(.ppomi(1)).foregroundStyle(.fg2)
            }
            replayEvidence(entry)
            capabilities(entry)
            GroupBox("사람 차례") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.record.manifest.humanSteps.enumerated()), id: \.offset) { _, step in Text(step) }
                    if entry.record.manifest.humanSteps.isEmpty { Text("없음 · 공통 승인 규칙 적용").foregroundStyle(.fg2) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("사용법") { Text(entry.record.guideText).font(.ppomi(2)).textSelection(.enabled).padding(.top, 8) }
            DisclosureGroup("명세") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Playbooks.definition(entry.record))
                    Text(entry.footprints.map { "\($0.glyph) \($0.target)\n전: \($0.fingerprintBefore.joined(separator: ", "))\n후: \($0.fingerprintAfter.joined(separator: ", "))" }.joined(separator: "\n\n"))
                }.font(.ppomiMono(1)).textSelection(.enabled).padding(.top, 8)
            }
        }
    }

    private func replayEvidence(_ entry: PlaybookEntry) -> some View {
        GroupBox("재생 검증") {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.status).font(.ppomi(3, weight: .medium))
                Text("버전 \(entry.record.manifest.version) 동작별 재생 기록").font(.ppomi(1)).foregroundStyle(.fg2)
                ForEach(entry.replayed, id: \.id) { footprint in
                    Label("\(footprint.glyph) \(footprint.target) · 성공 \(entry.replayOK(footprint)) · 실패 \(entry.replayFail(footprint))", systemImage: "checkmark.circle")
                }
                if entry.replayed.isEmpty { Text("성공 기록 없음").foregroundStyle(.fg2) }
                if entry.evidence.replayFail > 0 { Text("재생 실패 \(entry.evidence.replayFail)회").font(.ppomi(1)).foregroundStyle(.fg2) }
                if entry.evidence.historicalOK > 0 || entry.evidence.historicalFail > 0 {
                    Text("누적 성공 \(entry.evidence.historicalOK) · 실패 \(entry.evidence.historicalFail) (재생·수동 합산)")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func capabilities(_ entry: PlaybookEntry) -> some View {
        GroupBox("기능") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(entry.record.manifest.capabilities, id: \.id) { capability in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(capability.title).font(.ppomi(3, weight: .medium))
                        Text(capability.description).font(.ppomi(2)).foregroundStyle(.fg2)
                        if !capability.inputs.isEmpty {
                            Text("입력").font(.ppomi(2, weight: .medium))
                            ForEach(capability.inputs, id: \.name) { input in
                                Text("\(input.label) · \(input.required ? "필수" : "선택")").font(.ppomi(2))
                            }
                        }
                        ForEach(Array(capability.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.fg2)
                                Text(step.title)
                            }
                        }
                    }
                }
                if entry.record.manifest.capabilities.isEmpty { Text("명세 없음").foregroundStyle(.fg2) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
