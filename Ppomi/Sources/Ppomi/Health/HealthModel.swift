import Foundation
import Combine

/// A store read produces one presentation snapshot away from the UI thread.
private struct HealthSnapshot {
    let records: [LifeRecord]
    let people: [LifeEntity]
    let selfID: String
    let fileDate: Date?

    static var modificationDate: Date? {
        if SharedRecordVault.enabled { return try? SharedRecordVault.shared.read("health", refresh: false).confirmedAt }
        return
        (try? FileManager.default.attributesOfItem(atPath: LifeStore.defaultPath)[.modificationDate]) as? Date
    }

    static func read() throws -> HealthSnapshot {
        let readDate = modificationDate
        if SharedRecordVault.enabled {
            let value = try SharedRecordsSource.decode(SharedHealthArchive.self, name: "health")
            guard value.archive.formatVersion == 1 else { throw SharedRecordError.invalid }
            for record in value.archive.records { try record.validate() }
            return HealthSnapshot(records: value.archive.records.filter { ![.financialSnapshot, .financialTransaction].contains($0.kind) },
                people: value.archive.entities.filter { $0.kind == .person }, selfID: value.selfID, fileDate: readDate)
        }
        let store = try LifeStore()
        let selfID = try store.ensureSelfEntity().id
        return HealthSnapshot(
            records: try store.allRecords().filter { ![.financialSnapshot, .financialTransaction].contains($0.kind) },
            people: try store.entities().filter { $0.kind == .person },
            selfID: selfID,
            fileDate: readDate
        )
    }
}

@MainActor
final class HealthModel: ObservableObject {
    @Published private(set) var allHealthRecords: [LifeRecord] = []
    @Published private(set) var people: [LifeEntity] = []
    @Published var subjectID = ""
    @Published private(set) var selfID = ""
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published var message = ""
    @Published var error: String?
    private var loadedFileDate: Date?
    private var generation = 0

    var records: [LifeRecord] { allHealthRecords.filter { $0.subjectID == subjectID } }

    /// Button and editor callbacks keep a synchronous action while the read stays asynchronous.
    func reload() { Task { await reloadSnapshot() } }

    func refreshIfChanged() async { await reloadSnapshot(onlyIfChanged: true) }

    func reloadSnapshot(onlyIfChanged: Bool = false) async {
        guard !busy else { return }
        generation += 1
        let request = generation
        let previousDate = loadedFileDate
        if !onlyIfChanged { loading = true }
        defer { if request == generation { loading = false } }
        let result = await Task.detached { () -> Result<HealthSnapshot?, Error> in
            Result {
                if onlyIfChanged, HealthSnapshot.modificationDate == previousDate { return nil }
                return try HealthSnapshot.read()
            }
        }.value
        guard !Task.isCancelled, request == generation else { return }
        switch result {
        case .success(let snapshot): if let snapshot { apply(snapshot) }
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    func perform(_ action: @escaping (LifeStore) throws -> String) {
        guard !busy else { return }
        generation += 1 // An earlier read must not overwrite the result of this mutation.
        busy = true
        loading = false
        error = nil
        Task {
            let result = await Task.detached { () -> Result<(String, HealthSnapshot), Error> in
                Result {
                    let message = try action(LifeStore())
                    try SharedRecordsSource.publishIfEnabled("health")
                    return (message, try HealthSnapshot.read())
                }
            }.value
            busy = false
            switch result {
            case .success(let (text, snapshot)): apply(snapshot); message = text
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: HealthSnapshot) {
        selfID = snapshot.selfID
        people = snapshot.people
        if !people.contains(where: { $0.id == subjectID }) { subjectID = selfID }
        allHealthRecords = snapshot.records
        loadedFileDate = snapshot.fileDate
        error = nil
    }
}
