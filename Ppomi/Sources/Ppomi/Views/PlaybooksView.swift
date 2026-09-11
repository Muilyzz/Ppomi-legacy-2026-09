import SwiftUI
import AppKit

struct PlaybooksView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.recordsPageIsActive) private var isActive
    @StateObject private var model = PlaybooksModel()
    @State private var importError: String?
    @State private var browserError: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            }.padding([.horizontal, .top], 20)
            if !model.issues.isEmpty {
                DisclosureGroup("읽기 실패 \(model.issues.count)개") {
                    ForEach(model.issues) { issue in
                        Text("\(issue.directory.lastPathComponent): \(issue.message)").font(.ppomi(2)).textSelection(.enabled)
                    }
                }.foregroundStyle(.fg2).padding(.horizontal, 20)
            }
            if model.entries.isEmpty, model.loading {
                ProgressView("읽는 중…").padding(20)
            } else if model.entries.isEmpty {
                ContentUnavailableView("플레이북 없음", systemImage: "books.vertical", description: Text("폴더 가져오기"))
            } else {
                // 계정과목표 같은 한 나무(자리 › 패키지 › 기능) + 고른 패키지의 명세 나무·판정·발자국 — Web/playbooks.html
                WebPage(html: PlaybooksPage.html(model.entries), onMessage: { m in
                    guard let body = m as? [String: Any] else { return }
                    if let id = body["open"] as? String { open(id) }
                    if let id = body["pathColdStart"] as? String, id == "kb-enterprise" { state.runKBColdStart() }
                })
            }
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
        .alert("가져오기 실패", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("열기 실패", isPresented: Binding(get: { browserError != nil }, set: { if !$0 { browserError = nil } })) {
            Button("확인", role: .cancel) { browserError = nil }
        } message: { Text(browserError ?? "") }
    }

    /// '…에서 열기': 브라우저 패키지는 Mac Chrome, Windows 패키지는 Parallels. 로그인은 그 창에서 사람이.
    private func open(_ id: String) {
        guard let entry = model.entries.first(where: { $0.id == id }) else { return }
        let launch = entry.record.manifest.launch
        Task {
            do {
                if let url = launch.browserURL { try await Task.detached { try MacBrowser.open(url) }.value }
                else if let url = launch.windowsURL { try await Task.detached { try Desk.open(url.absoluteString) }.value }
            } catch { browserError = error.localizedDescription }
        }
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
                _ = imported   // 새 패키지는 나무에 제자리(categories.json 에 없으면 '기타')로 뜬다
            } catch { importError = error.localizedDescription }
        }
    }
}
