import Foundation
import CryptoKit
import Darwin

/// The same signed static-file format is verified on Mac, iPad and Android. No user records live here.
enum FamilyUpdateError: Error { case invalid, incompatible, signature, replay, storage, network }

struct FamilyUpdateConfiguration: Decodable {
    let formatVersion: Int
    let endpoint: String
    let publicKey: String
    let channel: String

    static func decode(_ data: Data) throws -> Self {
        try FamilyUpdatePackage.keys(data, exactly: ["formatVersion", "endpoint", "publicKey", "channel"])
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.formatVersion == 1, ["preview", "family"].contains(value.channel),
              let url = URL(string: value.endpoint), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              let key = Data(base64Encoded: value.publicKey), key.count == 65,
              key.base64EncodedString() == value.publicKey,
              (try? P256.Signing.PublicKey(x963Representation: key)) != nil else { throw FamilyUpdateError.invalid }
        return value
    }
    func namespace(platform: String) -> String {
        FamilyUpdatePackage.hash(Data("\(endpoint)\n\(publicKey)\n\(channel)\n\(platform)".utf8))
    }
}

struct FamilyUpdatePackage {
    static let maximumEnvelope = 32 * 1024 * 1024
    static let maximumTotal = 16 * 1024 * 1024
    static let maximumFile = 8 * 1024 * 1024
    static let extensions: Set<String> = ["html", "js", "css", "json", "woff2", "png", "jpg", "jpeg", "svg", "webp"]
    struct File: Decodable { let path: String; let sha256: String; let data: String }
    struct Manifest: Decodable {
        let formatVersion: Int
        let release: String
        let sequence: Int
        let channel: String
        let platform: String
        let bridgeVersion: Int
        let minNativeBuild: Int
        let capabilities: [String]
        let files: [File]
    }
    private struct Envelope: Decodable { let payload: String; let signature: String }
    let manifest: Manifest
    let files: [String: Data]
    let envelope: Data

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func keys(_ data: Data, exactly expected: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == expected else {
            throw FamilyUpdateError.invalid
        }
    }
    static func safePath(_ path: String) -> Bool {
        guard path.utf8.count <= 240, !path.isEmpty,
              extensions.contains((path as NSString).pathExtension.lowercased()),
              path.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$", options: .regularExpression) != nil else { return false }
        return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    static func requiredFiles(platform: String) -> Set<String> {
        if platform == "ipados" { return ["pad.html", "pad.js", "pad.css", "timeline.html", "tokens.css", "theme.css", "journal.html", "journal.js"] }
        let agent: Set<String> = ["Agent/index.html", "Agent/app.js", "Agent/app.css", "playbooks.json"]
        return platform == "macos" ? agent.union(["timeline.html", "evidence.html", "tokens.css", "theme.css", "simple.css", "evidence.js", "playbook.js", "facts.js", "journal.js", "schedule.js", "verify.js"]) : agent
    }
    static func verify(_ data: Data, configuration: FamilyUpdateConfiguration, platform: String,
                       nativeBuild: Int = 1, bridgeVersion: Int = 1, capabilities: Set<String>) throws -> Self {
        guard data.count <= maximumEnvelope else { throw FamilyUpdateError.invalid }
        try keys(data, exactly: ["payload", "signature"])
        let outer = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: outer.payload), payload.base64EncodedString() == outer.payload,
              let signatureBytes = Data(base64Encoded: outer.signature), signatureBytes.base64EncodedString() == outer.signature,
              let keyBytes = Data(base64Encoded: configuration.publicKey) else { throw FamilyUpdateError.invalid }
        let key = try P256.Signing.PublicKey(x963Representation: keyBytes)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBytes),
              key.isValidSignature(signature, for: payload) else { throw FamilyUpdateError.signature }
        try keys(payload, exactly: ["formatVersion", "release", "sequence", "channel", "platform", "bridgeVersion", "minNativeBuild", "capabilities", "files"])
        let manifest = try JSONDecoder().decode(Manifest.self, from: payload)
        guard manifest.formatVersion == 1, manifest.release.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              (1...2_147_483_647).contains(manifest.sequence), (1...512).contains(manifest.files.count),
              manifest.minNativeBuild >= 1, Set(manifest.capabilities).count == manifest.capabilities.count else { throw FamilyUpdateError.invalid }
        guard manifest.platform == platform, manifest.channel == configuration.channel,
              manifest.bridgeVersion == bridgeVersion, manifest.minNativeBuild <= nativeBuild,
              Set(manifest.capabilities).isSubset(of: capabilities) else { throw FamilyUpdateError.incompatible }
        // File objects and all paths are validated before any byte reaches the filesystem.
        let raw = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        guard let rawFiles = raw["files"] as? [[String: Any]], rawFiles.allSatisfy({ Set($0.keys) == ["path", "sha256", "data"] }) else { throw FamilyUpdateError.invalid }
        var files: [String: Data] = [:], lower = Set<String>(), total = 0
        for file in manifest.files {
            guard safePath(file.path), lower.insert(file.path.lowercased()).inserted,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let bytes = Data(base64Encoded: file.data), bytes.base64EncodedString() == file.data,
                  bytes.count <= maximumFile, hash(bytes) == file.sha256 else { throw FamilyUpdateError.invalid }
            total += bytes.count
            guard total <= maximumTotal else { throw FamilyUpdateError.invalid }
            files[file.path] = bytes
        }
        for path in lower {
            var parts = path.split(separator: "/"); parts.removeLast()
            while !parts.isEmpty {
                guard !lower.contains(parts.joined(separator: "/")) else { throw FamilyUpdateError.invalid }
                parts.removeLast()
            }
        }
        guard requiredFiles(platform: platform).isSubset(of: Set(files.keys)) else { throw FamilyUpdateError.invalid }
        return Self(manifest: manifest, files: files, envelope: data)
    }
}

/// Atomic state and immutable release folders. A failed trial is never selected again from the network.
final class FamilyUpdateStore {
    struct State: Codable {
        var highestSequence = 0
        var current: String?
        var previous: String?
        var pending: String?
        var trial: String?
    }
    let root: URL
    private let configuration: FamilyUpdateConfiguration
    private let platform: String
    private let capabilities: Set<String>
    private let mutex = NSLock()
    private(set) var selected: URL?
    private(set) var release = "bundled"
    private(set) var isTrial = false
    private var launchStarted = false
    private var readinessFailed = false
    private var usable = true

    init(root: URL, configuration: FamilyUpdateConfiguration, platform: String, capabilities: Set<String>) {
        self.root = root; self.configuration = configuration; self.platform = platform; self.capabilities = capabilities
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else { throw FamilyUpdateError.storage }
        let fd = Darwin.open(root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FamilyUpdateError.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw FamilyUpdateError.storage }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        guard stateURL.resolvingSymlinksInPath().path == stateURL.path else { throw FamilyUpdateError.storage }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        guard state.highestSequence >= 0 else { throw FamilyUpdateError.storage }
        for id in [state.current, state.previous, state.pending, state.trial].compactMap({ $0 }) {
            guard id.range(of: "^[0-9]+-[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw FamilyUpdateError.storage }
        }
        return state
    }
    private func write(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
    private func directory(_ id: String) -> URL { root.appendingPathComponent("releases", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    private func verify(_ data: Data) throws -> FamilyUpdatePackage {
        try FamilyUpdatePackage.verify(data, configuration: configuration, platform: platform, capabilities: capabilities)
    }
    private func installed(_ id: String) throws -> FamilyUpdatePackage {
        let dir = directory(id), envelope = dir.appendingPathComponent("package.json")
        guard dir.resolvingSymlinksInPath().path == dir.path, envelope.resolvingSymlinksInPath().path == envelope.path else { throw FamilyUpdateError.storage }
        let package = try verify(Data(contentsOf: envelope, options: .mappedIfSafe))
        guard id == "\(package.manifest.sequence)-\(package.manifest.release)" else { throw FamilyUpdateError.storage }
        for (path, bytes) in package.files {
            let file = dir.appendingPathComponent("files").appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path == file.path,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue == bytes.count,
                  try Data(contentsOf: file) == bytes else { throw FamilyUpdateError.storage }
        }
        let filesRoot = dir.appendingPathComponent("files", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else { throw FamilyUpdateError.storage }
        let prefix = filesRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var found = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw FamilyUpdateError.storage }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw FamilyUpdateError.storage }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(prefix) else { throw FamilyUpdateError.storage }
            found.insert(String(resolved.dropFirst(prefix.count)))
        }
        guard found == Set(package.files.keys) else { throw FamilyUpdateError.storage }
        return package
    }
    /// Called once per process, before any web surface exists. Never activate while the user is working.
    func beginLaunch() throws {
        try locked {
            guard !launchStarted else { return }; launchStarted = true
            var state = try readState()
            let recovering = state.trial != nil
            if recovering { state.current = state.previous; state.previous = nil; state.trial = nil }
            if !recovering, let pending = state.pending {
                state.previous = state.current; state.current = pending; state.pending = nil; state.trial = pending
            }
            if let current = state.current {
                do {
                    let package = try installed(current)
                    selected = directory(current).appendingPathComponent("files", isDirectory: true)
                    release = package.manifest.release; isTrial = state.trial == current
                } catch {
                    state.current = state.previous; state.previous = nil; state.trial = nil
                    if let previous = state.current, let package = try? installed(previous) {
                        selected = directory(previous).appendingPathComponent("files", isDirectory: true); release = package.manifest.release
                    } else { state.current = nil }
                }
            }
            try write(state)
        }
    }
    /// Downloading is independent of selection: current documents keep their complete release until next launch.
    func stage(_ bytes: Data) throws {
        let package = try verify(bytes)
        try locked {
            guard usable else { throw FamilyUpdateError.storage }
            var state = try readState()
            guard package.manifest.sequence > state.highestSequence else { throw FamilyUpdateError.replay }
            let id = "\(package.manifest.sequence)-\(package.manifest.release)"
            let staging = root.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (path, bytes) in package.files {
                let file = staging.appendingPathComponent("files", isDirectory: true).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
            }
            try bytes.write(to: staging.appendingPathComponent("package.json"), options: .atomic)
            let target = directory(id)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard target.deletingLastPathComponent().resolvingSymlinksInPath().path == target.deletingLastPathComponent().path else { throw FamilyUpdateError.storage }
            if FileManager.default.fileExists(atPath: target.path) {
                // Only an orphan left by an interrupted install may have this not-yet-accepted sequence.
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: staging, to: target)
            state.highestSequence = package.manifest.sequence; state.pending = id
            try write(state)
            prune(keeping: Set([state.current, state.previous, state.pending, selected?.deletingLastPathComponent().lastPathComponent].compactMap { $0 }))
        }
    }
    func markReady() throws {
        try locked {
            guard !readinessFailed else { throw FamilyUpdateError.storage }
            var state = try readState()
            guard isTrial, let current = state.current, selected == directory(current).appendingPathComponent("files", isDirectory: true), state.trial == current else { return }
            state.trial = nil; try write(state); isTrial = false
        }
    }
    func markFailed() throws {
        try locked {
            // Leave the persisted trial in place: the next launch must restore the prior confirmed release
            // before considering another download that may have completed during this failed launch.
            readinessFailed = true
            isTrial = false
        }
    }
    /// Startup-only escape hatch. Callers must tear down the failed view before constructing a bundled one.
    func useBundledFallback() { mutex.lock(); defer { mutex.unlock() }; selected = nil; release = "bundled"; isTrial = false }
    func disable() { mutex.lock(); defer { mutex.unlock() }; usable = false; selected = nil; release = "bundled"; isTrial = false }
    private func prune(keeping ids: Set<String>) {
        let releases = root.appendingPathComponent("releases", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !ids.contains(entry.lastPathComponent) { try? FileManager.default.removeItem(at: entry) }
    }
}
