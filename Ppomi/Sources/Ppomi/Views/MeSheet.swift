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
