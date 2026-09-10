import Darwin
import Foundation

/// Local JSON only. Serializes read/merge/write across processes; commits a private file atomically.
final class SpatialStore {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ppomi/Private/spatial-assets.json").path
    }
    let path: String
    private let accountingSnapshot: () throws -> AccountingArchive
    init(path: String = SpatialStore.defaultPath,
         accountingSnapshot: @escaping () throws -> AccountingArchive = { try AccountingStore().snapshot() }) {
        self.path = path; self.accountingSnapshot = accountingSnapshot
    }

    func snapshot() throws -> SpatialArchive {
        try withLock {
            let archive = try readArchive()
            try validateLinks(archive)
            return archive
        }
    }

    @discardableResult func importArchive(_ incoming: SpatialArchive) throws -> Int {
        try SpatialGeometry.validate(incoming)
        return try withLock {
            var archive = try readArchive()
            var indexed = Dictionary(uniqueKeysWithValues: archive.assets.map { ($0.id, $0) })
            var added = 0
            for asset in incoming.assets {
                if let old = indexed[asset.id] {
                    guard asset == old else { throw SpatialError.conflict("같은 공간 자산 ID의 내용을 덮어쓸 수 없습니다: \(asset.id). 수정본은 새 ID로 가져오세요.") }
                } else {
                    indexed[asset.id] = asset; archive.assets.append(asset); added += 1
                }
            }
            try SpatialGeometry.validate(archive)
            try validateLinks(archive)
            if added > 0 { try write(archive) }
            return added
        }
    }

    @discardableResult func importFile(_ url: URL) throws -> Int {
        try importArchive(Self.decode(Self.readFile(url)))
    }

    static func decode(_ data: Data) throws -> SpatialArchive {
        guard data.count <= SpatialGeometry.maximumBytes else { throw SpatialError.invalid("공간 JSON은 8MB 이하여야 합니다.") }
        let archive = try JSONDecoder().decode(SpatialArchive.self, from: data)
        try SpatialGeometry.validate(archive)
        return archive
    }

    static func encode(_ archive: SpatialArchive) throws -> Data {
        try SpatialGeometry.validate(archive)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= SpatialGeometry.maximumBytes else { throw SpatialError.invalid("공간 JSON은 8MB 이하여야 합니다.") }
        return data
    }

    static func readFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw SpatialError.invalid("로컬 JSON 파일만 가져올 수 있습니다.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= SpatialGeometry.maximumBytes else {
            throw SpatialError.invalid("8MB 이하의 일반 JSON 파일을 선택하세요.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: SpatialGeometry.maximumBytes + 1) ?? Data()
        guard data.count <= SpatialGeometry.maximumBytes else { throw SpatialError.invalid("공간 JSON은 8MB 이하여야 합니다.") }
        return data
    }

    private func readArchive() throws -> SpatialArchive {
        guard FileManager.default.fileExists(atPath: path) else { return SpatialArchive() }
        return try Self.decode(Self.readFile(URL(fileURLWithPath: path)))
    }

    private func validateLinks(_ archive: SpatialArchive) throws {
        guard SpatialAccountingLinks.hasLinks(archive) else { return }
        try SpatialAccountingLinks.validate(spatial: archive, accounting: accountingSnapshot())
    }

    private func write(_ archive: SpatialArchive) throws {
        let data = try Self.encode(archive)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
