import SwiftUI

/// Keeps the editor's draft in memory until Save; the live store writes only to Keychain.
fileprivate struct IdentityProfileViewStore {
    var list: () throws -> [IdentityProfile]
    var save: (IdentityProfile) throws -> Void
    var delete: (String) throws -> Void

    static let keychain = Self(
        list: { try IdentityProfileStore.shared.list() },
        save: { try IdentityProfileStore.shared.save($0) },
        delete: { try IdentityProfileStore.shared.delete(id: $0) }
    )
}

struct IdentityProfilesView: View {
    @State private var profiles: [IdentityProfile] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var editor: Editor?
    private let store: IdentityProfileViewStore

    private struct Editor: Identifiable {
        var profile: IdentityProfile
        var isNew: Bool
        var id: String { profile.id }
    }

    init() { store = .keychain }
    fileprivate init(store: IdentityProfileViewStore) { self.store = store }

    var body: some View {
        // 사람마다 자기 계정으로 로그인하므로 프로필은 "나" 하나뿐(가족은 각자). 추가·새로고침 버튼 없음: 보일 때 읽고, 대화·예금주 캡처가 채운다.
        Section("자동입력 기본정보") {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.bad)
                    .accessibilityIdentifier("identity-profiles-error")
            } else if !loaded {
                ProgressView("불러오는 중")
            } else if let profile = profiles.first(where: { $0.id == "self" }) {
                HStack(spacing: 12) {
                    IdentityProfileSummary(profile: profile)
                    Spacer()
                    Button("보기·편집") { editor = Editor(profile: profile, isNew: false) }
                        .accessibilityLabel("기본정보 보기 및 편집")
                }
            } else {
                HStack {
                    Text("등록된 정보 없음").foregroundStyle(.fg2)
                    Spacer()
                    Button("입력") { editor = Editor(profile: IdentityProfile(id: "self", label: "나"), isNew: true) }
                }
            }
            Text("폼 자동 입력용 · 대화에서 말하거나 은행 앱 예금주를 읽어 채움 · 비밀번호·인증번호 저장 안 함")
                .font(.ppomi(1)).foregroundStyle(.fg2)
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .sheet(item: $editor, onDismiss: reload) { selection in
            IdentityProfileEditor(profile: selection.profile, isNew: selection.isNew, store: store)
        }
    }

    private func reload() {
        do {
            profiles = try store.list()
            loaded = true
            errorMessage = nil
        } catch {
            profiles = []
            loaded = false
            errorMessage = "불러오기 실패 · \(error.localizedDescription)"
        }
    }

}

private struct IdentityProfileSummary: View {
    let profile: IdentityProfile

    /// 지문을 댄 뒤에만 보이는 자리라 값을 그대로 쓴다. 가림은 잠금 없이 목록이 보이던 때의 것이었다.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.label).fontWeight(.medium)
            Text(["이름 " + (profile.name ?? "미등록"), "생년월일 " + (profile.birthDate ?? "미등록")].joined(separator: " · "))
                .font(.ppomi(1)).foregroundStyle(.fg2)
            Text(["휴대폰 " + (profile.phone.map(Self.phone) ?? "미등록"), IdentityProfileCarrier.label(for: profile.carrier)].joined(separator: " · "))
                .font(.ppomi(1)).foregroundStyle(.fg2)
            if profile.businessName != nil || profile.businessRegistrationNumber != nil {
                Text(["상호 " + (profile.businessName ?? "미등록"), "사업자번호 " + (profile.businessRegistrationNumber.map(Self.business) ?? "미등록")].joined(separator: " · "))
                    .font(.ppomi(1)).foregroundStyle(.fg2)
            }
            ForEach((profile.bankProfiles ?? [:]).keys.sorted(), id: \.self) { bankID in
                if let bank = profile.bankProfiles?[bankID] {
                    Text([IdentityProfileBank.label(for: bankID), "고객명 " + (bank.customerName ?? "미등록"), "출금계좌 " + (bank.accountNumber ?? "미등록")].joined(separator: " · "))
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                        .accessibilityIdentifier("identity-bank-summary-\(bankID)")
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    /// 01012345678 → 010-1234-5678. 다른 길이는 그대로.
    private static func phone(_ digits: String) -> String {
        guard digits.count == 11, digits.allSatisfy(\.isNumber) else { return digits }
        return digits.prefix(3) + "-" + digits.dropFirst(3).prefix(4) + "-" + digits.suffix(4)
    }
    /// 1234567890 → 123-45-67890.
    private static func business(_ digits: String) -> String {
        guard digits.count == 10, digits.allSatisfy(\.isNumber) else { return digits }
        return digits.prefix(3) + "-" + digits.dropFirst(3).prefix(2) + "-" + digits.suffix(5)
    }
}

private enum IdentityProfileBank {
    static func label(for id: String) -> String {
        id == "kb" ? "KB국민은행 (kb)" : "은행 \(id)"
    }
}

private enum IdentityProfileCarrier {
    static let options: [(value: String, label: String)] = [
        ("skt", "SKT"), ("kt", "KT"), ("lgu", "LG U+"),
        ("skt_mvno", "SKT 알뜰폰"), ("kt_mvno", "KT 알뜰폰"), ("lgu_mvno", "LG U+ 알뜰폰")
    ]

    static func label(for value: String?) -> String {
        options.first(where: { $0.value == value })?.label ?? "통신사 미등록"
    }
}

private struct IdentityProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IdentityProfile
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    private let isNew: Bool
    private let store: IdentityProfileViewStore

    init(profile: IdentityProfile, isNew: Bool, store: IdentityProfileViewStore) {
        _draft = State(initialValue: profile)
        self.isNew = isNew
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "기본정보 등록" : "기본정보 편집").font(.ppomi(3, weight: .medium))
                Spacer()
            }
            .padding()

            Form {
                Section("프로필") {
                    TextField("구분 이름", text: $draft.label, prompt: Text("나·가족 호칭"))
                    Text("가족별 저장 · 대화에서 지정")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                }
                Section("자동 입력 정보") {
                    TextField("이름", text: field(\.name))
                    TextField("생년월일", text: field(\.birthDate), prompt: Text("YYYY-MM-DD"))
                    TextField("휴대폰 번호", text: field(\.phone), prompt: Text("숫자만"))
                    Picker("통신사", selection: field(\.carrier)) {
                        Text("선택 안 함").tag("")
                        ForEach(IdentityProfileCarrier.options, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Text("빈 항목은 비움")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                }
                Section("사업자 정보") {
                    TextField("상호", text: field(\.businessName), prompt: Text("사업자등록증 상호"))
                    TextField("사업자등록번호", text: field(\.businessRegistrationNumber), prompt: Text("10자리"))
                    Text("저장 ≠ 사업자 인증·가입")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                }
                ForEach(bankIDs, id: \.self) { bankID in
                    Section(IdentityProfileBank.label(for: bankID)) {
                        TextField("고객명", text: bankField(bankID, \.customerName), prompt: Text("통장 표기 그대로"))
                            .accessibilityIdentifier("identity-bank-customer-name-\(bankID)")
                        TextField("출금계좌번호", text: bankField(bankID, \.accountNumber), prompt: Text("숫자"))
                            .accessibilityIdentifier("identity-bank-account-number-\(bankID)")
                        Text("비밀번호·OTP·주민번호 저장 안 함")
                            .font(.ppomi(1)).foregroundStyle(.fg2)
                        if draft.bankProfiles?[bankID] != nil {
                            Button("은행 정보 지우기", role: .destructive) { removeBank(bankID) }
                                .accessibilityIdentifier("identity-bank-remove-\(bankID)")
                            Text("저장 시 이 은행 정보만 삭제")
                                .font(.ppomi(1)).foregroundStyle(.fg2)
                        }
                    }
                }
                Section {
                    Text("저장 시 키체인 반영 · 인증은 직접")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.bad)
                            .accessibilityIdentifier("identity-profile-editor-error")
                    }
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()

            Divider()
            HStack {
                if !isNew {
                    Button("프로필 삭제", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 700)
        .ppomiTheme()
        .confirmationDialog("프로필 삭제?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { delete() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("키체인에서 삭제")
        }
    }

    private func field(_ keyPath: WritableKeyPath<IdentityProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Keep the KB entry available without creating a stored bank record until a field is edited.
    /// Existing banks retain their explicit IDs; the UI does not infer a bank from account digits.
    private var bankIDs: [String] {
        ["kb"] + (draft.bankProfiles ?? [:]).keys.filter { $0 != "kb" }.sorted()
    }

    private func bankField(_ bankID: String, _ keyPath: WritableKeyPath<IdentityBankProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft.bankProfiles?[bankID]?[keyPath: keyPath] ?? "" },
            set: { value in
                var banks = draft.bankProfiles ?? [:]
                var bank = banks[bankID] ?? IdentityBankProfile()
                bank[keyPath: keyPath] = value.isEmpty ? nil : value
                if bank.customerName == nil && bank.accountNumber == nil { banks.removeValue(forKey: bankID) }
                else { banks[bankID] = bank }
                draft.bankProfiles = banks.isEmpty ? nil : banks
            }
        )
    }

    private func removeBank(_ bankID: String) {
        var banks = draft.bankProfiles ?? [:]
        banks.removeValue(forKey: bankID)
        draft.bankProfiles = banks.isEmpty ? nil : banks
    }

    private func save() {
        do {
            try store.save(draft.validated())
            dismiss()
        } catch {
            errorMessage = "저장 실패 · \(error.localizedDescription)"
        }
    }

    private func delete() {
        do {
            try store.delete(draft.id)
            dismiss()
        } catch {
            errorMessage = "삭제 실패 · \(error.localizedDescription)"
        }
    }
}

#Preview("기본정보 없음") {
    Form {
        IdentityProfilesView(store: .init(list: { [] }, save: { _ in }, delete: { _ in }))
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 420)
}

#Preview("가족 프로필") {
    Form {
        IdentityProfilesView(store: .init(
            list: { [IdentityProfile(id: "self", label: "나"), IdentityProfile(id: "family", label: "가족")] },
            save: { _ in }, delete: { _ in }
        ))
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 520)
}

#Preview("기본정보 편집") {
    IdentityProfileEditor(
        profile: IdentityProfile(id: "self", label: "나"), isNew: false,
        store: .init(list: { [] }, save: { _ in }, delete: { _ in })
    )
}

#Preview("은행 기본정보 편집") {
    IdentityProfileEditor(
        profile: IdentityProfile(id: "self", label: "합성 프로필", bankProfiles: [
            "kb": IdentityBankProfile(customerName: "합성 고객", accountNumber: "000123456789"),
            "sample-bank": IdentityBankProfile(customerName: "합성 다른 은행 고객")
        ]), isNew: false,
        store: .init(list: { [] }, save: { _ in }, delete: { _ in })
    )
}

#Preview("키체인 읽기 오류") {
    Form {
        IdentityProfilesView(store: .init(
            list: {
                throw NSError(domain: "IdentityProfilePreview", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "키체인 잠금 해제 후 새로고침"
                ])
            },
            save: { _ in }, delete: { _ in }
        ))
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 420)
}
