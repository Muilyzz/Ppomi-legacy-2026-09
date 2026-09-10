import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpatialAssetsView: View {
    @Environment(\.recordsPageIsActive) private var isActive
    @State private var archive = SpatialArchive()
    @State private var scopeFilter = RecordScopeFilter()
    @State private var selectedID = ""
    @State private var preview: SpatialAsset?
    @State private var wireframe = false
    @State private var resetToken = 0
    @State private var busy = false
    @State private var error: String?
    @State private var message = ""
    private let storePath: String

    init(storePath: String = SpatialStore.defaultPath) { self.storePath = storePath }

    private var visibleAssets: [SpatialAsset] { archive.assets.filter { $0.matches(scopeFilter) } }
    private var scopes: [RecordScope] { archive.assets.flatMap(\.effectiveScopes) + (preview?.effectiveScopes ?? []) }
    private var selected: SpatialAsset? {
        if let preview { return preview.matches(scopeFilter) ? preview : nil }
        return visibleAssets.first { $0.id == selectedID }
    }

    var body: some View {
        GeometryReader { geometry in
            // A short records pane scrolls as a whole. The same scene keeps its camera when focus
            // grows the pane, rather than switching to a different view hierarchy at a threshold.
            ScrollView {
                content(viewerHeight: max(420, geometry.size.height - 250))
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.surface)
        .ppomiTheme()
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await reload()
                if !SharedRecordVault.enabled { return }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: scopeFilter) { _, _ in if preview == nil { selectVisibleAsset() } }
        .accessibilityIdentifier("spatial-assets-page")
    }

    private func content(viewerHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.ppomi(2)).foregroundStyle(.bad).textSelection(.enabled) }
            if !message.isEmpty { Text(message).font(.ppomi(1)).foregroundStyle(.fg2) }
            if busy { ProgressView("처리 중…").controlSize(.ppomiSmall) }
            if let asset = selected {
                if preview != nil || asset.isSynthetic {
                    HStack {
                        Label("가상 예시", systemImage: "cube.transparent").foregroundStyle(.accentFg)
                        if preview != nil {
                            Text("미리보기").foregroundStyle(.fg2)
                            Spacer()
                            Button("닫기", action: closeExample)
                        }
                    }.font(.ppomi(1))
                }
                viewer(asset).frame(height: viewerHeight)
            } else if !busy, error == nil {
                if archive.assets.isEmpty, preview == nil { emptyState }
                else { noMatchingState }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("건축물 3D").font(.ppomi(6, weight: .medium)).tracking(-0.01 * Fonts.size(6))
                    Text("외곽선·높이 · 출처 표시")
                        .font(.ppomi(2)).foregroundStyle(.fg2)
                }
                Spacer(minLength: 8)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로 읽기").accessibilityLabel("새로 읽기").disabled(busy)
            }
            RecordScopeFilterView(scopes: scopes, filter: $scopeFilter)
            HStack(spacing: 12) {
                if !visibleAssets.isEmpty, preview == nil {
                    Picker("자산", selection: $selectedID) {
                        ForEach(visibleAssets) { asset in Text(asset.title).tag(asset.id) }
                    }
                    .frame(maxWidth: 360)
                    .onChange(of: selectedID) { _, _ in preview = nil }
                    .accessibilityIdentifier("spatial-asset-picker")
                }
                Spacer(minLength: 0)
                Button("가상 예시", action: showExample).disabled(busy)
                    .accessibilityIdentifier("spatial-example-preview")
                Menu("가져오기·내보내기") {
                    Button("JSON 가져오기…", action: importFile)
                    Button("JSON 저장…") {
                        let path = storePath
                        saveFile(name: "ppomi-spatial-assets.json") { try SpatialStore.encode(SharedRecordsSource.spatial(path: path)) }
                    }
                    Divider()
                    Button("예시 저장…") { saveFile(name: "ppomi-spatial-example.json", data: SpatialCatalog.templateData) }
                }.disabled(busy).accessibilityIdentifier("spatial-file-menu")
            }
        }
    }

    private var noMatchingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("해당 자료 없음")
            Text("구분 없는 자료 = 미분류").foregroundStyle(.fg2)
            Button("전체") { scopeFilter = RecordScopeFilter() }
            if preview != nil { Button("닫기", action: closeExample) }
        }.font(.ppomi(2)).padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "building.2.crop.circle").font(.ppomi(6)).foregroundStyle(.accentFg)
            Text("자료 없음").font(.ppomi(4, weight: .medium))
            Text("외곽선·높이(m) JSON 가져오기")
            Text("가상 예시로 회전·확대 체험")
                .foregroundStyle(.fg2)
            Button("JSON 가져오기…", action: importFile)
        }
        .font(.ppomi(2)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface2, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("spatial-empty")
    }

    private func viewer(_ asset: SpatialAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(asset.title).font(.ppomi(3, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Toggle("윤곽선", isOn: $wireframe).toggleStyle(.checkbox).accessibilityIdentifier("spatial-wireframe")
                Button("시점 초기화") { resetToken += 1 }.accessibilityIdentifier("spatial-camera-reset")
            }
            GeometryReader { geometry in
                if geometry.size.width >= 800 {
                    HStack(alignment: .top, spacing: 16) {
                        scene(asset).frame(maxWidth: .infinity, maxHeight: .infinity)
                        details(asset).frame(width: 270, height: geometry.size.height)
                    }
                } else {
                    VStack(spacing: 12) {
                        scene(asset).frame(height: max(170, geometry.size.height * 0.57))
                        details(asset).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.frame(minHeight: 320)
        }
    }

    private func scene(_ asset: SpatialAsset) -> some View {
        SpatialSceneView(asset: asset, wireframe: wireframe, resetToken: resetToken, isActive: isActive)
            .overlay(alignment: .bottomLeading) {
                Text("드래그 회전 · 스크롤 확대")
                    .font(.ppomi(1)).foregroundStyle(.fg).padding(9)
                    .background(.surface, in: RoundedRectangle(cornerRadius: 8)).padding(12)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func details(_ asset: SpatialAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("연결").font(.ppomi(3, weight: .medium))
                    Text("대상 ID · \(asset.entityID)")
                    Text("자료 ID · \(asset.id)")
                    ForEach(asset.accountIDs, id: \.self) { Text("미검증 참조 · \($0)").foregroundStyle(.fg2) }
                }.font(.ppomi(1)).textSelection(.enabled)
                ownershipDetails(asset)
                usageDetails(asset)
                Divider()
                Text("치수 · m").font(.ppomi(3, weight: .medium))
                ForEach(asset.parts) { part in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(part.title).font(.ppomi(2, weight: .medium))
                            Spacer(minLength: 4)
                            HStack(spacing: 4) {
                                Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: SpatialScene.color(part.provenance.kind)))
                                Text(part.provenance.kind.title)
                            }.font(.ppomi(1)).foregroundStyle(.fg2)
                        }
                        Text("높이 \(number(part.height))m · 기준면 \(number(part.elevation))m")
                        Text("면적 \(number(SpatialGeometry.area(part.footprint)))m² · 꼭짓점 \(part.footprint.count)")
                            .foregroundStyle(.fg2)
                        Text(part.provenance.note).foregroundStyle(.fg2)
                        Text("출처 ID · \(part.provenance.sourceRecordID)").foregroundStyle(.fg2)
                    }
                    .font(.ppomi(1)).textSelection(.enabled).padding(12)
                    .background(.surface2, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("면적 = 외곽선 계산값 · 연면적·가치 아님")
                    .font(.ppomi(1)).foregroundStyle(.fg2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }

    private func ownershipDetails(_ asset: SpatialAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("소유").font(.ppomi(3, weight: .medium))
            if asset.ownerships.isEmpty { Text("미입력").foregroundStyle(.fg2) }
            ForEach(asset.ownerships) { ownership in
                VStack(alignment: .leading, spacing: 5) {
                    Text("소유자 · \(ownership.ownerID)")
                    Text("지분 · \(ratio(ownership.shareBasisPoints))")
                    Text(ownership.note).foregroundStyle(.fg2)
                    Text("출처 ID · \(ownership.sourceRecordID)").foregroundStyle(.fg2)
                }
            }
        }.font(.ppomi(1)).textSelection(.enabled)
    }

    private func usageDetails(_ asset: SpatialAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("사용").font(.ppomi(3, weight: .medium))
            if asset.usages.isEmpty { Text("미입력").foregroundStyle(.fg2) }
            ForEach(asset.usages.filter { scopeFilter.matches($0.scope) }) { usage in
                VStack(alignment: .leading, spacing: 6) {
                    Text(usage.scope.label).font(.ppomi(2, weight: .medium))
                    Text("배분 · \(ratio(usage.allocationBasisPoints))")
                    Text(usage.note).foregroundStyle(.fg2)
                    Text("출처 ID · \(usage.sourceRecordID)").foregroundStyle(.fg2)
                    if usage.accountLinks.isEmpty { Text("계정 연결 없음").foregroundStyle(.fg2) }
                    ForEach(usage.accountLinks, id: \.self) { link in
                        Text("계정 · \(link.bookID) / \(link.accountID)")
                    }
                }.padding(10).background(.surface2, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("미입력 ≠ 0% · 분개 자동 생성 없음").foregroundStyle(.fg2)
        }.font(.ppomi(1)).textSelection(.enabled)
    }

    private func ratio(_ basisPoints: Int?) -> String {
        basisPoints.map { number(Double($0) / 100) + "%" } ?? "미입력"
    }

    @MainActor private func reload() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let path = storePath
        let result = await Task.detached(priority: .utility) { Result { try SharedRecordsSource.spatial(path: path) } }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value): apply(value); error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    @MainActor private func apply(_ value: SpatialArchive) {
        archive = value
        selectVisibleAsset()
    }

    @MainActor private func selectVisibleAsset() {
        if !visibleAssets.contains(where: { $0.id == selectedID }) { selectedID = visibleAssets.first?.id ?? "" }
    }

    @MainActor private func closeExample() {
        preview = nil
        selectVisibleAsset()
    }

    @MainActor private func showExample() {
        do {
            preview = try SpatialStore.decode(SpatialCatalog.templateData()).assets.first
            scopeFilter = RecordScopeFilter()
            error = nil; message = ""; resetToken += 1
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = storePath
        perform {
            let accessible = url.startAccessingSecurityScopedResource()
            defer { if accessible { url.stopAccessingSecurityScopedResource() } }
            let added = try SpatialStore(path: path).importFile(url)
            return "\(added)개 추가"
        }
    }

    @MainActor private func saveFile(name: String, data: @escaping () throws -> Data) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let accessible = url.startAccessingSecurityScopedResource()
            defer { if accessible { url.stopAccessingSecurityScopedResource() } }
            try data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "\(url.lastPathComponent) 저장됨"
        }
    }

    @MainActor private func perform(_ operation: @escaping () throws -> String) {
        guard !busy else { return }; busy = true; error = nil; message = ""
        let path = storePath
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    let status = try operation()
                    if path == SpatialStore.defaultPath { try SharedRecordsSource.publishIfEnabled("spatial") }
                    return (status, Result { try SharedRecordsSource.spatial(path: path) })
                }
            }.value
            busy = false
            switch result {
            case .success(let (status, snapshot)):
                preview = nil; message = status
                switch snapshot {
                case .success(let value): apply(value)
                case .failure(let failure):
                    archive = SpatialArchive(); selectedID = ""
                    error = failure.localizedDescription
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
