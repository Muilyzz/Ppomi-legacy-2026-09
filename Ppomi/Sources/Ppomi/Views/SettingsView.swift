// 설정: 연결, 장부, 내 정보와 자동입력 기본정보. API 키와 자동입력 기본정보는 Keychain에 저장한다.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var apiKey = ""              // only what was pasted now; the stored key is never read back into a field
    @State private var hasKey = false
    @State private var baseURL = AppSettings.baseURL
    @State private var model = AppSettings.model
    @State private var agentEndpoint = UserDefaults.standard.string(forKey: AgentNativePolicy.endpointPreference) ?? ""
    @State private var agentEndpointBad = false
    @State private var visionEnabled = AppSettings.visionEnabled
    @State private var uiScale = AppSettings.uiScale
    @State private var dbPath = AppSettings.dbPath
    @State private var me = AppSettings.me
    @State private var applyingLedger = false
    @State private var ledgerSettingsError: String?
    @State private var ledgerSettingsApplied = false
    @State private var checking = false
    @State private var connection: Connection = .unknown
    @State private var items: [Permissions.Item] = []   // the 시작하기 rows, re-read every 2 s while the window is up
    @State private var telemetry = false                 // state table "telemetry:on" (Telemetry.swift reads it)
    @FocusState private var keyFocus: Bool
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Connection { case unknown, ok(String), fail(String) }

    var body: some View {
        Form {
            Section("시작하기") {
                ForEach(items) { i in
                    HStack {
                        Text(i.ok == nil ? "·" : i.ok! ? "✓" : "✗").fontWeight(.medium).frame(minWidth: 16)
                            .foregroundStyle(i.ok == nil ? Color.fg2 : i.ok! ? Color.accentFg : Color.bad)
                        VStack(alignment: .leading) { Text(i.name); Text(i.note).font(.ppomi(1)).foregroundStyle(.fg2) }
                        Spacer()
                        if !i.button.isEmpty { Button(i.button, action: i.open) }
                    }
                }
                Text(items.allSatisfy { $0.ok != false } ? "준비됨" : Permissions.ready ? "손·눈 준비됨 · 나머지 선택" : "손쉬운 사용·화면 기록 필요")
                    .foregroundStyle(Permissions.ready ? Color.accentFg : Color.bad)
                Toggle("실행 결과 보내기 (성공·실패·걸음 번호)", isOn: Binding(get: { telemetry }, set: { on in
                    telemetry = on
                    try? DB(path: AppSettings.dbPath, writable: true).setState("telemetry:on", on ? "1" : "0")
                }))
            }
            Section("글자 크기") {
                Picker("글자 크기", selection: $uiScale) {
                    Text("1×").tag(1.0); Text("1.5×").tag(1.5); Text("2×").tag(2.0); Text("3×").tag(3.0)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("settings-ui-scale")
                .onChange(of: uiScale) { _, scale in
                    AppSettings.uiScale = scale
                    Fonts.scale.value = scale                                               // every ppomiTheme() root re-renders
                    NotificationCenter.default.post(name: Fonts.scaleChanged, object: nil)   // native labels and the chat page
                }
            }
            Section("연결") {
                SecureField("API 키", text: $apiKey, prompt: Text(hasKey ? "새 키" : "키 붙여넣기"))
                    .focused($keyFocus)
                if hasKey {
                    HStack {
                        Text("키체인 저장됨").foregroundStyle(.fg2)
                        Spacer()
                        Button("삭제") { deleteKey() }
                    }
                }
                TextField("기본 URL", text: $baseURL)
                TextField("모델", text: $model)
                HStack {
                    Button("저장·확인") { Task { await saveAndCheck() } }.disabled(checking)
                    if checking { ProgressView().controlSize(.ppomiSmall) }
                    connectionText
                }
                HStack {
                    TextField("에이전트 서버", text: $agentEndpoint)
                        .autocorrectionDisabled()
                        .onSubmit(saveAgentEndpoint)
                    if agentEndpointBad { Text("주소 확인").font(.ppomi(3)).foregroundStyle(.bad) }
                }
            }
            SharedServerSettingsView()
            Section("화면 보조") {
                Toggle("VLM 보조 눈", isOn: $visionEnabled)
                    .onChange(of: visionEnabled) { _, enabled in AppSettings.visionEnabled = enabled }
                Text("OCR 부족 시 화면을 OpenAI에 전송 · 비용 발생")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
                Text("모델 \(AppSettings.visionModel) · 관찰만")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
                Text("인증 화면 제외 · 개인정보 자동 가림 아님")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
            }
            Section("장부") {
                TextField("DB 경로", text: $dbPath)
                    .disabled(applyingLedger)
                    .onChange(of: dbPath) { _, _ in ledgerDraftChanged() }
                TextField("내 이름", text: $me)
                    .disabled(applyingLedger)
                    .onChange(of: me) { _, _ in ledgerDraftChanged() }
                Text("이 이름 입금 = 내 계좌 이체")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
                HStack {
                    Button("적용") { Task { await applyLedgerSettings() } }
                        .disabled(applyingLedger)
                    if applyingLedger { ProgressView().controlSize(.ppomiSmall) }
                    else if ledgerSettingsApplied { Text("적용됨").foregroundStyle(.fg2) }
                }
                if let ledgerSettingsError { Text(ledgerSettingsError).foregroundStyle(.bad) }
                HStack { ledgerText }
            }
            IdentityProfilesView()
        }
        .formStyle(.grouped)
        .frame(width: 480 * max(1, uiScale))
        .ppomiTheme()
        .onAppear {
            hasKey = Keychain.apiKey() != nil
            telemetry = (try? DB(path: AppSettings.dbPath).state("telemetry:on")) == "1"
            recheckItems()
        }
        .onReceive(recheck) { _ in recheckItems() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheckItems() }   // back from System Settings: re-read at once
    }

    private func recheckItems() { items = Permissions.items { keyFocus = true } }

    private func clearLedgerFeedback() {
        ledgerSettingsError = nil
        ledgerSettingsApplied = false
    }

    private func ledgerDraftChanged() {
        if dbPath != AppSettings.dbPath || me != AppSettings.me { clearLedgerFeedback() }
    }

    @MainActor private func applyLedgerSettings() async {
        applyingLedger = true
        clearLedgerFeedback()
        defer { applyingLedger = false }
        do {
            try await state.applyLedgerSettings(dbPath: dbPath, me: me)
            dbPath = AppSettings.dbPath
            me = AppSettings.me
            ledgerSettingsApplied = true
        } catch {
            ledgerSettingsError = "적용 실패: \(error)"
        }
    }

    @ViewBuilder private var connectionText: some View {
        switch connection {
        case .unknown: EmptyView()
        case .ok(let s): Text(s).foregroundStyle(.fg2)
        case .fail(let s): Text(s).foregroundStyle(.bad)
        }
    }

    @ViewBuilder private var ledgerText: some View {
        if let e = state.ledgerError { Text(e).foregroundStyle(.bad).lineLimit(2) }
        else if let l = state.ledger { Text("계좌 \(l.accounts.count)개 · 분개 \(l.lines.count)줄").foregroundStyle(.fg2) }
    }

    /// Invalid input keeps the stored address; a valid one is normalized, stored and ends any live agent session.
    private func saveAgentEndpoint() {
        if let url = try? AgentNativePolicy.save(endpoint: agentEndpoint) {
            agentEndpoint = url.absoluteString; agentEndpointBad = false
        } else {
            agentEndpoint = UserDefaults.standard.string(forKey: AgentNativePolicy.endpointPreference) ?? ""; agentEndpointBad = true
        }
    }

    private func deleteKey() {
        do { try Keychain.deleteAPIKey(); hasKey = false; connection = .unknown }
        catch { connection = .fail(error.localizedDescription) }
    }

    /// Persist URL/model/key, then prove the connection: GET /models, and on a Vercel gateway also GET /credits.
    @MainActor private func saveAndCheck() async {
        checking = true
        defer { checking = false }
        AppSettings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            do { try Keychain.setAPIKey(pasted); apiKey = ""; hasKey = true }
            catch { connection = .fail(error.localizedDescription); return }
        }
        guard let key = Keychain.apiKey() else { connection = .fail("API 키 없음"); return }
        guard let url = URL(string: AppSettings.baseURL), let host = url.host else { connection = .fail("URL 오류"); return }
        let client = LLMClient(baseURL: url, apiKey: key)
        do {
            var line = "연결됨 · \(try await client.listModels().count)개 모델"
            if host.contains("vercel"), let balance = try? await client.credits().balance {
                line += " · 남은 예산 $\(String(format: "%.2f", balance))"
            }
            connection = .ok(line)
        } catch {
            connection = .fail(error.localizedDescription)
        }
    }
}
