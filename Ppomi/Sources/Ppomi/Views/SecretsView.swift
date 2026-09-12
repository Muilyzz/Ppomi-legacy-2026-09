import AppKit
import SwiftUI

/// 「상태·비밀」: Storybook secrets tree, native. Locked + masked until OS step-up. Copy is pasteboard only.
struct SecretsView: View {
    @Environment(\.recordsPageIsActive) private var isActive
    @State private var unlocked = false
    @State private var unlocking = false
    @State private var error: String?
    @State private var blob: Any = SecretsVault.fixture()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("로컬 시크릿").font(.ppomi(6, weight: .medium))
                    Spacer()
                    Text(unlocked ? "열림" : "잠김").font(.ppomi(1)).foregroundStyle(.fg2)
                        .accessibilityIdentifier("secrets-badge")
                }
                if !chips.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.key) { chip in
                            Text("\(chip.key) · \(chip.chip)")
                                .font(.ppomi(1))
                                .foregroundStyle(.fg2)
                                .accessibilityIdentifier("secrets-chip")
                        }
                    }
                }
                HStack {
                    if unlocked {
                        Button("잠그기", action: relock)
                            .accessibilityIdentifier("secrets-lock")
                    } else {
                        Button("인증하고 열기") { Task { await unlock() } }
                            .disabled(unlocking)
                            .accessibilityIdentifier("secrets-unlock")
                        if unlocking { ProgressView().controlSize(.ppomiSmall) }
                    }
                    Text("이 Mac 에서만 열람 · 복사. 채팅·서버로 보내지 않음")
                        .font(.ppomi(1)).foregroundStyle(.fg2)
                }
                if let error { Text(error).foregroundStyle(.bad).font(.ppomi(2)) }
                if SecretsTree.asObject(blob) == nil && SecretsTree.asArray(blob) == nil {
                    Text("시크릿 없음").font(.ppomi(2)).foregroundStyle(.fg2)
                } else {
                    SecretsBranch(label: "blob", path: [], node: blob, unlocked: unlocked, expanded: unlocked)
                        .id(unlocked)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.surface)
        .ppomiTheme()
        .onAppear { reload() }
        .onChange(of: isActive) { _, active in
            if !active { relock() }
        }
    }

    private var chips: [SecretsTree.Chip] { SecretsTree.chips(of: blob) }

    private func reload() {
        blob = SecretsVault.snapshot(unlocked: unlocked)
    }

    private func unlock() async {
        unlocking = true
        error = nil
        defer { unlocking = false }
        do {
            try await SecretsGate.unlock()
            unlocked = true
            reload()
        } catch {
            unlocked = false
            self.error = "잠금 해제 안 됨"
        }
    }

    private func relock() {
        unlocked = false
        error = nil
        reload()
    }
}

private struct SecretsBranch: View {
    let label: String
    let path: [String]
    let node: Any
    let unlocked: Bool
    let expanded: Bool
    @State private var open: Bool

    init(label: String, path: [String], node: Any, unlocked: Bool, expanded: Bool) {
        self.label = label
        self.path = path
        self.node = node
        self.unlocked = unlocked
        self.expanded = expanded
        _open = State(initialValue: expanded && path.count < SecretsTree.maxDepth)
    }

    var body: some View {
        if path.count >= SecretsTree.maxDepth {
            HStack {
                Text("…").font(.ppomi(2))
                Text("…").font(.ppomi(1)).foregroundStyle(.fg2)
            }
        } else if SecretsTree.isContainer(node) {
            DisclosureGroup(isExpanded: $open) {
                ForEach(Array(SecretsTree.children(node).enumerated()), id: \.offset) { _, child in
                    SecretsBranch(label: child.key, path: path + [child.path], node: child.value,
                                  unlocked: unlocked, expanded: expanded)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label).font(.ppomi(2, weight: .medium))
                    Text("\(SecretsTree.children(node).count)").font(.ppomi(1)).foregroundStyle(.fg2)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.ppomi(2))
                Text(SecretsTree.display(path: path, value: node, unlocked: unlocked))
                    .font(.ppomi(2))
                    .foregroundStyle(unlocked ? Color.fg : Color.fg2)
                    .textSelection(unlocked ? .enabled : .disabled)
                if unlocked, SecretsTree.isSecretLeaf(node) {
                    Button("복사") { copyLocal(SecretsTree.stringish(node)) }
                        .font(.ppomi(1))
                        .accessibilityIdentifier("secrets-copy")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func copyLocal(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
