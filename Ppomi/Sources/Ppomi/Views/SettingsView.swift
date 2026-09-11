// 설정 창(⌘,)엔 시작하기(권한)만. 계정·자동입력 프로필은 작업대의 🔒 나 시트(MeSheet). 장부 경로는 자동 감지, 내 이름은 "나" 프로필, 글자 크기는 OS, 보조 눈은 서버, 도착 인사는 뽀미의 판단.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var items: [Permissions.Item] = []   // the 시작하기 rows, re-read every 2 s while the window is up
    @State private var telemetry = false                 // state table "telemetry:on" (Telemetry.swift reads it)
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()


    var body: some View {
        Form {
            Section("시작하기") {
                if !Permissions.ready {
                    Text("시스템 설정 › 개인정보 보호 및 보안에서 손쉬운 사용과 화면 기록을 켜세요. 목록에 뽀미가 있으면 체크하고, 화면 기록을 켠 뒤에는 아래 ‘뽀미 다시 실행’을 누르세요.")
                        .foregroundStyle(Color.bad)
                }
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






    /// Invalid input keeps the stored address; a valid one is normalized, stored and ends any live agent session.


}
