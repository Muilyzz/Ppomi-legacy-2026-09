// 🔒 나: 계정과 자동입력 프로필. 로그인 전엔 로그인만(보호할 게 없다). 로그인 뒤엔 Touch ID·Mac 암호 한 번 뒤에 프로필과 로그아웃.
// 아이패드의 같은 자리 버튼과 같은 흐름. 메뉴·설정 창엔 없다.
import SwiftUI

struct MeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var close: (() -> Void)? = nil
    @State private var account = GoogleAccount.session
    @State private var unlocked = false
    @State private var unlocking = false
    @State private var signingIn = false
    @State private var error: String?
    @State private var pending: [PendingDevice] = []   // 승인을 기다리는 기기(Windows·iPad·새 Mac·웹). 이 Mac 이 승인해야 기록 키를 받는다
    @State private var deciding: String?
    private let pendingRefresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(session: account, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account?.name ?? "나").font(.ppomi(4, weight: .medium))
                    if let account { Text(account.email).font(.ppomi(1)).foregroundStyle(.fg2) }
                }
                Spacer()
                Button("닫기") { if let close { close() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 16))
            Form {
                Section("계정") {
                    if let account {
                        Text(account.registered ? "Google · 기기 등록됨" : "Google · 기기 등록 전").foregroundStyle(.fg2)
                        Button("로그아웃", role: .destructive) { GoogleAccount.shared.signOut(); self.account = nil; unlocked = false }
                    } else {
                        HStack {
                            Button("Google 계정으로 로그인") { Task { await signIn() } }.disabled(signingIn)
                            if signingIn { ProgressView().controlSize(.ppomiSmall) }
                        }
                        Text("아이패드와 같은 계정으로 로그인하면 같은 장부를 봅니다").font(.ppomi(1)).foregroundStyle(.fg2)
                    }
                }
                if let account, account.registered {
                    Section("기기 승인") {
                        if pending.isEmpty {
                            Text("승인을 기다리는 기기가 없습니다").foregroundStyle(.fg2)
                        }
                        ForEach(pending) { device in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.label)
                                    Text(device.platformName).font(.ppomi(1)).foregroundStyle(.fg2)
                                }
                                Spacer()
                                if deciding == device.id { ProgressView().controlSize(.ppomiSmall) }
                                Button("승인") { Task { await decide(device, approve: true) } }
                                Button("거절", role: .destructive) { Task { await decide(device, approve: false) } }
                            }
                            .disabled(deciding != nil)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("\(device.label) · \(device.platformName) 승인 대기")
                        }
                        Text("같은 Google 계정으로 로그인한 새 기기입니다. 승인한 기기에만 이 Mac 이 기록 키를 감싸 전달합니다").font(.ppomi(1)).foregroundStyle(.fg2)
                    }
                }
                if account != nil {
                    if unlocked {
                        IdentityProfilesView()
                    } else {
                        Section("자동입력 기본정보") {
                            HStack {
                                Button { Task { await unlock() } } label: { Label("지문으로 열기", systemImage: "lock.fill") }.disabled(unlocking)
                                if unlocking { ProgressView().controlSize(.ppomiSmall) }
                            }
                            Text(IdentityVault.shared.isAvailable ? "Secure Enclave 키로 잠겨 있습니다 · 지문 없이는 이 Mac 도 읽지 못합니다" : "이 Mac 에는 Secure Enclave 가 없어 키체인 잠금만 적용됩니다")
                                .font(.ppomi(1)).foregroundStyle(.fg2)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.bad) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480 * max(1, AppSettings.uiScale), height: 620 * max(1, AppSettings.uiScale))
        .ppomiTheme()
        .onAppear { unlocked = IdentityVault.shared.isUnlocked }
        .task { await loadPending() }
        .onReceive(pendingRefresh) { _ in Task { await loadPending() } }
    }

    /// 승인 대기 목록. 로그인·등록 전이거나 서버가 닿지 않으면 비운다(오류 배너는 결정할 때만).
    private func loadPending() async {
        guard account?.registered == true, deciding == nil else { return }
        let devices = await Task.detached { try? GoogleAccount.pendingDevices() }.value
        if let devices, devices != pending { pending = devices }
    }
    private func decide(_ device: PendingDevice, approve: Bool) async {
        deciding = device.id; error = nil
        defer { deciding = nil }
        do {
            try await Task.detached {
                if approve { try GoogleAccount.approve(device.id) } else { try GoogleAccount.revoke(device.id) }
            }.value
            pending.removeAll { $0.id == device.id }
        } catch { self.error = (approve ? "승인 실패: " : "거절 실패: ") + SharedServerClient.safe(error).description }
        await loadPending()
    }

    private func unlock() async {
        unlocking = true; error = nil
        defer { unlocking = false }
        do {
            try await IdentityVault.shared.unlock(reason: "자동입력 프로필을 보려면 확인이 필요합니다")
            try await Task.detached { try IdentityProfileStore.shared.migrateToVault() }.value   // 예전 평문 항목이 있으면 금고 형식으로
            unlocked = true
        } catch { unlocked = false; self.error = "잠금 해제 안 됨" }
    }
    private func signIn() async {
        signingIn = true; error = nil
        do { account = try await GoogleAccount.shared.signIn() }
        catch { self.error = "로그인 실패: " + SharedServerClient.safe(error).description }
        signingIn = false
    }
}

/// 구글 프로필 사진, 없으면 이니셜, 로그인 전엔 실루엣. Mac·아이패드 같은 모양.
struct AvatarView: View {
    let session: MacSession?
    let size: CGFloat
    var body: some View {
        Group {
            if let session, let url = session.avatarURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { initial(session) }
            } else if let session { initial(session) }
            else { Image(systemName: "person.crop.circle").resizable().foregroundStyle(.fg2) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    private func initial(_ session: MacSession) -> some View {
        ZStack {
            Circle().fill(Color.accentSoft)
            Text(String((session.name ?? session.email).prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Color.accentFg)
        }
    }
}
