import AppKit
import Combine

/// The manifest describes intent. Runtime evidence alone describes what actually replayed.
struct PlaybookEntry: Identifiable {
    let record: PlaybookRecord
    let footprints: [Footprint]
    let installed: String?
    var id: String { record.id }
    var evidence: PlaybookEvidence { PlaybookEvidence(footprints, version: record.manifest.version) }
    func replayOK(_ footprint: Footprint) -> Int { footprint.verified.replayVersions?[record.manifest.version]?.ok ?? 0 }
    func replayFail(_ footprint: Footprint) -> Int { footprint.verified.replayVersions?[record.manifest.version]?.fail ?? 0 }
    var replayed: [Footprint] { footprints.filter { replayOK($0) > 0 } }
    var stepCount: Int { record.manifest.capabilities.reduce(0) { $0 + $1.steps.count } }
    var status: String { evidence.replayedSteps == 0 ? "현재 버전 재생 검증 전" : "현재 버전 재생 성공 \(evidence.replayedSteps)개 동작" }
    var installation: String { record.manifest.launch.isBrowser ? "Mac · Google Chrome" : installed == "1" ? "설치 확인됨" : installed == "0" ? "미설치" : "설치 여부 미확인" }
}

/// Catalog, runtime evidence, and icon bytes are read together outside the view hierarchy.
struct PlaybooksSnapshot {
    let entries: [PlaybookEntry]
    let common: String
    let issues: [PlaybookCatalog.Issue]
    let iconData: [String: Data]

    static func read() -> PlaybooksSnapshot {
        let db = try? DB(path: AppSettings.dbPath)
        let common = PlaybookCatalog.common(in: Playbooks.dir)
        let catalog = PlaybookCatalog.inspect(in: Playbooks.dir, includeBundled: true)
        let entries = catalog.records.map { record in
            let keys = [record.id, record.name] + record.manifest.aliases
            let installed = keys.lazy.compactMap { key -> String? in
                guard let db else { return nil }
                return try? db.state("installed:\(key)")
            }.first
            return PlaybookEntry(record: record, footprints: FootprintStore.load(record.id), installed: installed)
        }
        let iconData = Dictionary(uniqueKeysWithValues: catalog.records.compactMap { record -> (String, Data)? in
            guard let url = record.iconURL, let data = try? Data(contentsOf: url) else { return nil }
            return (record.id, data)
        })
        return PlaybooksSnapshot(entries: entries, common: common, issues: catalog.issues, iconData: iconData)
    }
}

/// Presentation data only; this archive never installs an executable playbook package.
struct SharedPlaybooksArchive: Codable {
    struct Entry: Codable {
        var manifest: PlaybookManifest
        var guide: String
        var footprints: [Footprint]
        var installed: String?
    }
    var entries: [Entry]
    var common: String
    var issues: [String]
    var iconData: [String: Data]
    static func capture() -> Self {
        let value = PlaybooksSnapshot.read()
        return Self(entries: value.entries.map { Entry(manifest: $0.record.manifest, guide: $0.record.guideText,
             footprints: $0.footprints, installed: $0.installed) }, common: value.common,
             issues: value.issues.map(\.message), iconData: value.iconData)
    }
    func snapshot() -> PlaybooksSnapshot {
        let directory = SharedRecordVault.defaultDirectory.appendingPathComponent("presentation")
        return PlaybooksSnapshot(entries: entries.map { value in
            let location = directory.appendingPathComponent(SharedRecordCrypto.hash(Data(value.manifest.id.utf8)))
            return PlaybookEntry(record: PlaybookRecord(manifest: value.manifest, directory: location, guideText: value.guide, iconURL: nil),
                footprints: value.footprints, installed: value.installed)
        }, common: common, issues: issues.enumerated().map { PlaybookCatalog.Issue(directory: directory.appendingPathComponent("issue-\($0.offset)"), message: $0.element) }, iconData: iconData)
    }
}

@MainActor
final class PlaybooksModel: ObservableObject {
    @Published private(set) var entries: [PlaybookEntry] = []
    @Published private(set) var common = ""
    @Published private(set) var issues: [PlaybookCatalog.Issue] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var loading = false
    private var iconData: [String: Data] = [:]
    private var generation = 0

    func reload() { Task { await reloadSnapshot() } }

    func reloadSnapshot() async {
        generation += 1
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        let result = await Task.detached { Result { () throws -> PlaybooksSnapshot in
            if SharedRecordVault.enabled { return try SharedRecordsSource.decode(SharedPlaybooksArchive.self, name: "playbooks").snapshot() }
            return PlaybooksSnapshot.read()
        } }.value
        guard !Task.isCancelled, request == generation else { return }
        guard case .success(let snapshot) = result else {
            issues = [PlaybookCatalog.Issue(directory: SharedRecordVault.defaultDirectory, message: "확인된 서버 플레이북을 읽지 못했습니다.")]
            return
        }
        var nextIcons: [String: NSImage] = [:]
        for (id, data) in snapshot.iconData {
            nextIcons[id] = iconData[id] == data ? icons[id] : NSImage(data: data)
        }
        icons = nextIcons
        iconData = snapshot.iconData
        entries = snapshot.entries
        common = snapshot.common
        issues = snapshot.issues
    }
}
