// 설정: 시작하기(권한), 계정(구글 로그인), 음성, 장부, 자동입력 기본정보(Keychain). 글자 크기는 OS 텍스트 크기, 보조 눈의 모델·비용은 서버 몫.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var account = GoogleAccount.session      // 계정 = 구글 로그인(아이패드와 같은 흐름)
    @State private var signingIn = false
    @State private var accountError: String?
    @State private var dbPath = AppSettings.dbPath
    @State private var me = AppSettings.me
    @State private var applyingLedger = false
    @State private var ledgerSettingsError: String?
    @State private var ledgerSettingsApplied = false
    @State private var items: [Permissions.Item] = []   // the 시작하기 rows, re-read every 2 s while the window is up
    @State private var telemetry = false                 // state table "telemetry:on" (Telemetry.swift reads it)
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()


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
            Section("계정") {
                if let account {
                    Text(account.registered ? "로그인됨 · \(account.email) · 기기 등록됨" : "로그인됨 · \(account.email) · 기기 등록 전").foregroundStyle(.fg2)
                    Button("로그아웃", role: .destructive) { GoogleAccount.shared.signOut(); self.account = nil }
                } else {
                    HStack {
                        Button("Google 계정으로 로그인") { Task { await signIn() } }.disabled(signingIn)
                        if signingIn { ProgressView().controlSize(.ppomiSmall) }
                    }
                    Text("아이패드와 같은 계정으로 로그인하면 같은 장부를 봅니다").font(.ppomi(1)).foregroundStyle(.fg2)
                }
                if let accountError { Text(accountError).foregroundStyle(.bad) }
            }
            Section("음성") {
                Toggle("뽀미야 라고 부르면 듣기", isOn: Binding(get: { state.voiceOn }, set: { state.voiceOn = $0; AppSettings.wakeWord = $0 }))
                Toggle("폰이 연결되면 뽀미가 먼저 말하기", isOn: Binding(get: { state.greetOnArrival }, set: { _ in state.toggleGreet() }))
                Text("통화는 대화 입력창의 전화 버튼, 수집은 대화에서 \"수집해\"").font(.ppomi(1)).foregroundStyle(.fg2)
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
        .frame(width: 480 * max(1, AppSettings.uiScale))
        .ppomiTheme()
        .onAppear {
            telemetry = (try? DB(path: AppSettings.dbPath).state("telemetry:on")) == "1"
            recheckItems()
        }
        .onReceive(recheck) { _ in recheckItems() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheckItems() }   // back from System Settings: re-read at once
    }

    private func recheckItems() { items = Permissions.items() }

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


    @ViewBuilder private var ledgerText: some View {
        if let e = state.ledgerError { Text(e).foregroundStyle(.bad).lineLimit(2) }
        else if let l = state.ledger { Text("계좌 \(l.accounts.count)개 · 분개 \(l.lines.count)줄").foregroundStyle(.fg2) }
    }

    /// Invalid input keeps the stored address; a valid one is normalized, stored and ends any live agent session.


}

extension SettingsView {
    func signIn() async {
        signingIn = true; accountError = nil
        do { account = try await GoogleAccount.shared.signIn() }
        catch { accountError = "로그인 실패: " + SharedServerClient.safe(error).description }
        signingIn = false
    }
}
