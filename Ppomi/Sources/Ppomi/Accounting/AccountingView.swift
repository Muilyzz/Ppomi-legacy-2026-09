import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Every book uses the same journal. Account names and units come from the archive.
struct AccountingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.recordsPageIsActive) private var isActive
    @State private var archive = AccountingArchive()
    @State private var bookID = ""
    @State private var scopeFilter = RecordScopeFilter()
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var busy = false
    @State private var error: String?
    @State private var message = ""

    private var visibleBooks: [AccountingBook] { archive.books.filter { scopeFilter.matches($0.effectiveScope) } }
    // Match the scope immediately, before onChange synchronizes the picker selection.
    private var selectedBook: AccountingBook? { visibleBooks.first { $0.id == bookID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.ppomi(2)).foregroundStyle(.bad).textSelection(.enabled)
                    .accessibilityIdentifier("accounting-error")
            }
            if !message.isEmpty {
                Text(message).font(.ppomi(1)).foregroundStyle(.fg2)
                    .accessibilityIdentifier("accounting-status")
            }
            if loading { ProgressView("읽는 중…") }
            if let book = selectedBook {
                AccountingJournal(archive: archive, book: book)
            } else if !loading, error == nil {
                if archive.books.isEmpty { emptyState }
                else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("해당 장부 없음").foregroundStyle(.fg2)
                        Button("전체") { scopeFilter = RecordScopeFilter() }
                    }
                    .accessibilityIdentifier("accounting-scope-empty")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.surface)
        .ppomiTheme()
        .task(id: isActive) {
            guard isActive else { return }
            await reload()
        }
        .onChange(of: scopeFilter) { _, _ in synchronizeSelection() }
        .onChange(of: state.ledgerVersion) { _, _ in if isActive { Task { await reload() } } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("분개장").font(.ppomi(6, weight: .medium)).tracking(-0.01 * Fonts.size(6))
                    Text("원본과 평가 조정 비교")
                        .font(.ppomi(2)).foregroundStyle(.fg2)
                }
                Spacer(minLength: 8)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로 읽기").accessibilityLabel("새로 읽기")
                    .accessibilityIdentifier("accounting-refresh")
                    .disabled(loading || busy)
            }
            RecordScopeFilterView(scopes: archive.books.map(\.effectiveScope), filter: $scopeFilter)
                .accessibilityIdentifier("accounting-scope-filter")
            if archive.books.contains(where: { $0.effectiveScope.kind == .unclassified }) {
                Text("구분 없는 장부 = 미분류")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
            }
            HStack {
                if !visibleBooks.isEmpty {
                    Picker("장부", selection: $bookID) {
                        ForEach(visibleBooks, id: \.id) { book in
                            Text("\(book.name) · \(book.effectiveScope.label) · \(book.unit.symbol)").tag(book.id)
                        }
                    }
                    .frame(maxWidth: 420)
                    .accessibilityIdentifier("accounting-book-picker")
                }
                Spacer(minLength: 0)
                Menu("가져오기·내보내기") {
                    Button("JSON 가져오기…", action: importFile)
                    Button("기존 장부", action: importLegacy)
                    Button("JSON 저장…") {
                        saveFile(name: "ppomi-accounting.json") { try LifeJSON.encoder().encode(SharedRecordsSource.accounting()) }
                    }
                    Divider()
                    Button("예시 저장…") {
                        saveFile(name: "ppomi-accounting-example.json") { try AccountingCatalog.templateData() }
                    }
                }
                .accessibilityIdentifier("accounting-file-menu")
                .disabled(loading || busy)
            }
            if busy { ProgressView("처리 중…").controlSize(.ppomiSmall) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("장부 없음", systemImage: "book.closed")
                .font(.ppomi(4, weight: .medium))
            Text("JSON 가져오기 · 예시 파일 참고")
            Text("개인·사업 구분 · 장부별 단위 · 잔액 합산 없음")
                .foregroundStyle(.fg2)
            Button("JSON 가져오기…", action: importFile).disabled(busy)
        }
        .font(.ppomi(2))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface2, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("accounting-empty")
    }

    @MainActor private func reload() async {
        guard !busy else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        let result = await Task.detached(priority: .utility) {
            Result { try SharedRecordsSource.accounting() }
        }.value
        guard !Task.isCancelled, generation == loadGeneration else { return }
        switch result {
        case .success(let archive): apply(archive)
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    @MainActor private func apply(_ snapshot: AccountingArchive) {
        archive = snapshot
        synchronizeSelection()
        error = nil
    }

    private func synchronizeSelection() {
        if !visibleBooks.contains(where: { $0.id == bookID }) { bookID = visibleBooks.first?.id ?? "" }
    }

    @MainActor private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "가져오기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let imported = try LifeJSON.decoder().decode(AccountingArchive.self, from: Data(contentsOf: url))
            let count = try AccountingStore().importArchive(imported)
            return "\(count)건 추가 · 중복 유지"
        }
    }

    @MainActor private func importLegacy() {
        guard let ledger = state.ledger, state.ledgerError == nil else {
            error = "금융 장부 먼저 읽기 · 설정 확인"
            return
        }
        let expanded = (AppSettings.dbPath as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        let namespace = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        perform {
            let imported = try AccountingLegacyAdapter.archive(ledger: ledger, namespace: namespace)
            let count = try AccountingStore().importArchive(imported)
            return "\(count)건 추가 · 원본 유지"
        }
    }

    @MainActor private func saveFile(name: String, data: @escaping () throws -> Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "\(url.lastPathComponent) 저장됨"
        }
    }

    @MainActor private func perform(_ operation: @escaping () throws -> String) {
        guard !loading, !busy else { return }
        busy = true
        error = nil
        message = ""
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    let status = try operation()
                    try SharedRecordsSource.publishIfEnabled("accounting")
                    return (status, try SharedRecordsSource.accounting())
                }
            }.value
            busy = false
            switch result {
            case .success(let (status, snapshot)): apply(snapshot); message = status
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

private struct AccountingJournal: View {
    let archive: AccountingArchive
    let book: AccountingBook

    private var recorded: [AccountingEntry] {
        archive.entries.filter { $0.bookID == book.id && $0.layer == .recorded }
            .sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
    }

    private var effective: Result<[AccountingEntry], Error> {
        Result { try AccountingEngine.entries(in: archive, bookID: book.id, includeAdjustments: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(book.effectiveScope.label) · \(book.kind == .financial ? "금융" : "관리") · 단위 \(book.unit.name) (\(book.unit.symbol))")
                .font(.ppomi(1)).foregroundStyle(.fg2).textSelection(.enabled)
            switch effective {
            case .success(let entries): journal(entries: entries)
            case .failure(let failure):
                Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                    .font(.ppomi(2)).foregroundStyle(.bad).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("accounting-journal")
    }

    private func journal(entries: [AccountingEntry]) -> some View {
        let grouped = Dictionary(grouping: entries.filter { $0.layer == .adjustment }, by: { $0.assessment?.sourceEntryID ?? "" })
        return GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if recorded.isEmpty {
                                Text("분개 없음")
                                    .foregroundStyle(.fg2).padding(20)
                            }
                            ForEach(recorded, id: \.id) { entry in
                                AccountingComparisonRow(entry: entry, adjustments: grouped[entry.id] ?? [],
                                                        book: book, accounts: archive.accounts)
                            }
                        } header: {
                            HStack(alignment: .top, spacing: 16) {
                                columnHeading(book.kind == .financial ? "일반 장부" : "사용 기록", subtitle: "원본 분개")
                                columnHeading("관리 장부", subtitle: "평가 조정 반영")
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(.surface)
                        }
                    }
                    .frame(width: max(geometry.size.width, 680), alignment: .topLeading)
                }
        }
    }

    private func columnHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.ppomi(3, weight: .medium))
            Text(subtitle).font(.ppomi(1)).foregroundStyle(.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountingComparisonRow: View {
    let entry: AccountingEntry
    let adjustments: [AccountingEntry]
    let book: AccountingBook
    let accounts: [AccountingAccount]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.memo.isEmpty ? "분개" : entry.memo).font(.ppomi(2, weight: .medium))
                    Spacer()
                    Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.ppomi(1)).monospacedDigit().foregroundStyle(.fg2)
                }
                Text("활동 \(entry.eventID) · 출처 \(entry.source)")
                    .font(.ppomi(1)).foregroundStyle(.fg2).textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 16) {
                AccountingPostingList(postings: entry.postings, accounts: accounts, unit: book.unit)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 12) {
                    switch Result(catching: { try AccountingEngine.netPostings([entry] + adjustments) }) {
                    case .success(let postings):
                        if postings.isEmpty {
                            Text("잔액 없음").font(.ppomi(1)).foregroundStyle(.fg2)
                        } else {
                            AccountingPostingList(postings: postings, accounts: accounts, unit: book.unit)
                        }
                    case .failure(let failure):
                        Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                            .font(.ppomi(1)).foregroundStyle(.bad)
                    }
                    if adjustments.isEmpty {
                        Text("평가 없음")
                            .font(.ppomi(1)).foregroundStyle(.fg2)
                    }
                    ForEach(adjustments, id: \.id) { adjustment in
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("평가 조정").font(.ppomi(1, weight: .medium)).foregroundStyle(.accentFg)
                            if let assessment = adjustment.assessment {
                                Text(assessment.rationale).font(.ppomi(1)).foregroundStyle(.fg2)
                                    .textSelection(.enabled)
                                Text("신뢰도 \(AccountingDisplay.percent(assessment.confidenceBasisPoints)) · \(assessment.model ?? "모델 미기재")")
                                    .font(.ppomi(1)).foregroundStyle(.fg2)
                                Text("기록 \(adjustment.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.ppomi(1)).foregroundStyle(.fg2)
                                if let previous = assessment.replacesEntryID {
                                    Text("대체 \(previous)")
                                        .font(.ppomi(1)).foregroundStyle(.fg2).textSelection(.enabled)
                                }
                            }
                            DisclosureGroup("조정 분개") {
                                if adjustment.postings.isEmpty {
                                    Text("없음").font(.ppomi(1)).foregroundStyle(.fg2)
                                } else {
                                    AccountingPostingList(postings: adjustment.postings, accounts: accounts, unit: book.unit)
                                        .padding(.top, 8)
                                }
                            }.font(.ppomi(1))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .background(.surface2, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounting-entry-\(entry.id)")
    }
}

private struct AccountingPostingList: View {
    let postings: [AccountingPosting]
    let accounts: [AccountingAccount]
    let unit: AccountingUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(postings.enumerated()), id: \.offset) { _, posting in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(posting.side == .debit ? "차변" : "대변")
                        .font(.ppomi(1, weight: .medium)).foregroundStyle(.fg2)
                        .fixedSize()
                    Text(AccountingDisplay.accountName(posting.accountID, accounts: accounts))
                        .font(.ppomi(1)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(AccountingDisplay.amount(posting.amount, unit: unit))
                        .font(.ppomi(1)).monospacedDigit().fixedSize()
                }
            }
        }
    }
}

private enum AccountingDisplay {
    static func amount(_ amount: Int, unit: AccountingUnit) -> String {
        let value = Decimal(amount) / pow(Decimal(10), unit.scale)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = unit.scale
        formatter.maximumFractionDigits = unit.scale
        return "\(formatter.string(from: NSDecimalNumber(decimal: value)) ?? value.description) \(unit.symbol)"
    }

    static func percent(_ basisPoints: Int) -> String {
        let value = Decimal(basisPoints) / 100
        return "\(NSDecimalNumber(decimal: value).stringValue)%"
    }

    static func accountName(_ id: String, accounts: [AccountingAccount]) -> String {
        var path: [String] = []
        var currentID: String? = id
        var visited = Set<String>()
        while let nextID = currentID, visited.insert(nextID).inserted,
              let account = accounts.first(where: { $0.id == nextID }) {
            path.append(account.name)
            currentID = account.parentID
        }
        return path.isEmpty ? id : path.reversed().joined(separator: " / ")
    }
}
