import SwiftUI

struct SharedServerSettingsView: View {
    @State private var host = ""
    @State private var deviceID = ""
    @State private var workspace = ""
    @State private var configured = false
    @State private var connected = false
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Section("공유 서버") {
            if configured {
                LabeledContent("서버", value: host)
                LabeledContent("이 Mac", value: deviceID)
                    .textSelection(.enabled).font(.ppomi(1))
                if !workspace.isEmpty { LabeledContent("작업공간", value: workspace) }
            }
            HStack {
                Button("연결 확인") { Task { await refresh() } }.disabled(checking)
                if checking { ProgressView().controlSize(.ppomiSmall) }
                else { Text(connected ? "연결됨" : configured ? "연결 확인 필요" : "설정되지 않음").foregroundStyle(.fg2) }
            }
            if let error { Text(error).font(.ppomi(1)).foregroundStyle(.bad) }
            Text(SharedRecordVault.enabled
                 ? "상단 기록은 서버에서 확인한 암호화 자료를 표시합니다. 수집 원본과 첨부 원본은 이 Mac에 보관하며, 복호화 키는 이 Mac의 키체인에 있습니다."
                 : "공유 작업과 절차·규칙은 서버의 버전을 기준으로 확정합니다. 기존 로컬 장부와 기록은 자동 전송하지 않습니다.")
                .font(.ppomi(1)).foregroundStyle(.fg2)
        }
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !checking else { return }
        checking = true; error = nil
        defer { checking = false }
        let result = await Task.detached(priority: .utility) { () -> Result<[String: Any], SharedServerError> in
            do { return .success(try SharedServerClient.shared.status()) }
            catch { return .failure(SharedServerClient.safe(error)) }
        }.value
        switch result {
        case .success(let status):
            configured = status["configured"] as? Bool ?? false
            connected = status["connected"] as? Bool ?? false
            host = status["host"] as? String ?? ""
            deviceID = status["deviceId"] as? String ?? ""
            let context = status["context"] as? [String: Any]
            workspace = (context?["workspace"] as? [String: Any])?["name"] as? String ?? ""
            error = status["error"] as? String
        case .failure(let failure):
            connected = false; error = failure.description
        }
    }
}
