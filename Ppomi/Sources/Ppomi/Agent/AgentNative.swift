import AppKit
import CryptoKit
import Darwin
import Foundation

enum AgentNativeError: Error, LocalizedError, Equatable {
    case invalidRequest, invalidEndpoint, inactive, unavailable, fileBoundary, fileSize, fileIO
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "허용되지 않은 에이전트 요청입니다."
        case .invalidEndpoint: return "인증 정보·쿼리·프래그먼트 없는 HTTPS 서버 주소가 필요합니다."
        case .inactive: return "음성 세션이 종료되어 실행하지 않았습니다."
        case .unavailable: return "음성 에이전트 파일을 찾지 못했습니다. 앱을 다시 빌드해 주세요."
        case .fileBoundary: return "뽀미 작업 폴더의 일반 파일만 사용할 수 있습니다."
        case .fileSize: return "UTF-8 파일은 128 KiB 이하여야 합니다."
        case .fileIO: return "작업 파일을 읽거나 저장하지 못했습니다."
        }
    }
}

enum AgentNativePolicy {
    static let requestPaths: Set<String> = ["/v1/session", "/v1/responses", "/v1/memories/list", "/v1/memories/save", "/v1/memories/delete"]
    static let toolNames = ["device_status", "file_list", "file_read", "file_write"]
    static let endpointPreference = "voiceAgentEndpoint.v1"
    /// Posted after the endpoint preference changes; live conversations must drop their session.
    static let endpointChanged = Notification.Name("ppomi.agentEndpointChanged")

    static func endpoint(_ value: String) throws -> URL {
        guard value.count <= 2048, let c = URLComponents(string: value), c.scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, let url = c.url,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !c.percentEncodedPath.contains("%"), !c.path.split(separator: "/").contains("..") else {
            throw AgentNativeError.invalidEndpoint
        }
        return url
    }

    /// Validates, stores the normalized URL and notifies open conversations.
    @discardableResult
    static func save(endpoint value: String, defaults: UserDefaults = .standard) throws -> URL {
        let url = try endpoint(value)
        defaults.set(url.absoluteString, forKey: endpointPreference)
        NotificationCenter.default.post(name: endpointChanged, object: nil)
        return url
    }

    static func requestURL(endpoint value: String, path: String) throws -> URL {
        guard requestPaths.contains(path) else { throw AgentNativeError.invalidRequest }
        return try endpoint(value).appendingPathComponent(String(path.dropFirst()))
    }

    static func trusted(_ url: URL?, entry: URL) -> Bool {
        guard let url, url.isFileURL, url.query == nil, url.fragment == nil else { return false }
        return url.standardizedFileURL == entry.standardizedFileURL
    }
}

/// Native lifetime is authoritative even if a model callback was queued before the Stop button.
final class AgentNativeSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var generation = UUID()

    var isActive: Bool { lock.withLock { active } }
    var revision: UUID { lock.withLock { generation } }
    func setActive(_ value: Bool) {
        lock.withLock { active = value; generation = UUID() }
    }
    func perform<T>(revision: UUID? = nil, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard active, revision == nil || revision == generation else { throw AgentNativeError.inactive }
            return try body()
        }
    }
}

/// Descriptor-relative access prevents a symlink or renamed directory escaping the app-owned workspace.
final class AgentWorkspace: @unchecked Sendable {
    static let limit = 128 * 1024
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ppomi/AgentWorkspace", isDirectory: true)) { self.root = root }

    private func rootFD() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AgentNativeError.fileBoundary }
        return fd
    }

    private func components(_ path: String, empty: Bool = false) throws -> [String] {
        if path.isEmpty, empty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains("\0"),
              parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".ppomi-write-") && $0.utf8.count <= 255 }) else {
            throw AgentNativeError.fileBoundary
        }
        return parts
    }

    private func directory(_ parts: [String]) throws -> Int32 {
        var fd = try rootFD()
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw AgentNativeError.fileBoundary }
            fd = next
        }
        return fd
    }

    private func regular(_ parent: Int32, _ name: String, mayBeMissing: Bool = false) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if mayBeMissing, errno == ENOENT { return }
            throw AgentNativeError.fileIO
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AgentNativeError.fileBoundary }
    }

    private func readData(parent: Int32, name: String) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AgentNativeError.fileBoundary }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AgentNativeError.fileBoundary }
        guard info.st_size <= Self.limit else { throw AgentNativeError.fileSize }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw AgentNativeError.fileIO }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.limit else { throw AgentNativeError.fileSize }
        }
        guard String(data: data, encoding: .utf8) != nil else { throw AgentNativeError.fileSize }
        return data
    }

    func list(path: String = "") throws -> [String: Any] {
        let parts = try components(path, empty: true), fd = try directory(parts)
        guard let dir = fdopendir(fd) else { Darwin.close(fd); throw AgentNativeError.fileIO }
        defer { closedir(dir) }
        var files: [[String: Any]] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", !name.hasPrefix(".ppomi-write-") else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) else { continue }
            files.append(["path": (parts + [name]).joined(separator: "/"), "name": name,
                          "type": kind == S_IFDIR ? "directory" : "file", "size": info.st_size])
            guard files.count <= 1000 else { throw AgentNativeError.fileSize }
        }
        return ["path": path, "files": files.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
    }

    func read(path: String) throws -> [String: Any] {
        let parts = try components(path), fd = try directory(Array(parts.dropLast()))
        defer { Darwin.close(fd) }
        return result(path: path, data: try readData(parent: fd, name: parts.last!), content: true)
    }

    func write(path: String, content: String) throws -> [String: Any] {
        let data = Data(content.utf8)
        guard data.count <= Self.limit else { throw AgentNativeError.fileSize }
        let parts = try components(path), fd = try directory(Array(parts.dropLast())), name = parts.last!
        defer { Darwin.close(fd) }
        try regular(fd, name, mayBeMissing: true)
        let temporary = ".ppomi-write-" + UUID().uuidString
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AgentNativeError.fileIO }
        defer { Darwin.close(output); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw AgentNativeError.fileIO }
                guard count > 0 else { throw AgentNativeError.fileIO }
                offset += count
            }
        }
        guard fsync(output) == 0 else { throw AgentNativeError.fileIO }
        try regular(fd, name, mayBeMissing: true)
        guard renameat(fd, temporary, fd, name) == 0 else { throw AgentNativeError.fileIO }
        let verified = try readData(parent: fd, name: name)
        guard verified == data else { throw AgentNativeError.fileIO }
        return result(path: path, data: verified, content: false)
    }

    private func result(path: String, data: Data, content: Bool) -> [String: Any] {
        var value: [String: Any] = ["path": path, "bytes": data.count,
                                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        if content { value["content"] = String(decoding: data, as: UTF8.self) }
        else { value["verified"] = true }
        return value
    }
}
