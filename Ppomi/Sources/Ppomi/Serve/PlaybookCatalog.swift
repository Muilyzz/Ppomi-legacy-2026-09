import Foundation

/// The package is the shared specification for the app, MCP, collector, and hub.
/// Local observations and replay evidence live outside the package and survive upgrades.
struct PlaybookManifest: Codable, Equatable {
    struct Launch: Codable, Equatable {
        var search: String
        /// Absent preserves the existing phone/explicit Windows routes. Browser packages open on this Mac.
        var target: String? = nil
        var isBrowser: Bool { target == "browser" }
        /// exe 설치·공동인증서 friendly sites: the URL opens in Parallels Windows (windows_open), never on the phone.
        var isWindows: Bool { target == "windows" }
        var browserURL: URL? { isBrowser ? Self.webURL(search) : nil }
        var windowsURL: URL? { isWindows ? Self.webURL(search) : nil }
        /// The tool that opens a URL package; nil for phone packages.
        var openTool: String? { isBrowser ? "browser_open" : isWindows ? "windows_open" : nil }
        var routeName: String { isWindows ? "Windows" : "Mac 웹" }

        static func webURL(_ value: String) -> URL? {
            guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
                  !value.contains("\\"), let url = URL(string: value),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return url
        }
    }
    struct Input: Codable, Equatable { var name: String; var label: String; var required: Bool }
    struct Step: Codable, Equatable { var id: String; var title: String; var kind: String }
    struct Capability: Codable, Equatable {
        var id: String
        var title: String
        var description: String
        var inputs: [Input]
        var steps: [Step]
    }
    struct Collection: Codable, Equatable {
        var key: String
        var account: String
        var homeLabel: String? = nil
        var expand: String? = nil
        var list: String? = nil
        var tx: String? = nil
        var txpage: String? = nil
        var home: String? = nil
        var scrollY: Double = 0.5
    }

    var schemaVersion: Int = 1
    var id: String
    var name: String
    var version: String
    var aliases: [String]
    var icon: String? = nil
    var iconSource: String? = nil
    var launch: Launch
    var capabilities: [Capability]
    var humanSteps: [String]
    var guide: String
    var collection: Collection? = nil
}

struct PlaybookRecord: Identifiable, Equatable {
    let manifest: PlaybookManifest
    let directory: URL
    let guideText: String
    let iconURL: URL?
    var id: String { manifest.id }
    var name: String { manifest.name }
    var summary: String { manifest.capabilities.map(\.title).joined(separator: " · ") }
    var identities: [String] { [id, name] + manifest.aliases }
    func matches(_ value: String) -> Bool { identities.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
}

extension PlaybookManifest.Collection {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        account = try values.decode(String.self, forKey: .account)
        homeLabel = try values.decodeIfPresent(String.self, forKey: .homeLabel)
        expand = try values.decodeIfPresent(String.self, forKey: .expand)
        list = try values.decodeIfPresent(String.self, forKey: .list)
        tx = try values.decodeIfPresent(String.self, forKey: .tx)
        txpage = try values.decodeIfPresent(String.self, forKey: .txpage)
        home = try values.decodeIfPresent(String.self, forKey: .home)
        scrollY = try values.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0.5
    }
}

enum PlaybookCatalog {
    struct Issue: Identifiable {
        let directory: URL
        let message: String
        var id: String { directory.path }
    }
    struct Inspection { var records: [PlaybookRecord]; var issues: [Issue] }
    enum Invalid: LocalizedError {
        case package(String)
        var errorDescription: String? { if case .package(let message) = self { return message }; return nil }
    }

    static let stepKinds: Set<String> = ["open", "human", "tap", "read", "scroll", "close", "payment", "choice", "input", "coupon", "payment-method"]
    static var bundledDirectory: URL? { Web.bundle.resourceURL?.appendingPathComponent("Catalog", isDirectory: true) }

    static func load(in playbooksDir: URL = Playbooks.dir, includeBundled: Bool = true) -> [PlaybookRecord] {
        inspect(in: playbooksDir, includeBundled: includeBundled).records
    }

    /// Invalid local packages are reported and never replace a valid bundled package.
    static func inspect(in playbooksDir: URL = Playbooks.dir, includeBundled: Bool = true) -> Inspection {
        var records: [String: PlaybookRecord] = [:]
        var issues: [Issue] = []
        let local = playbooksDir.appendingPathComponent("catalog", isDirectory: true)
        let roots = (includeBundled ? bundledDirectory.map { [$0] } ?? [] : []) + [local]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            do {
                try requireDirectory(root)
                let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                    .filter { validID($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for directory in packages {
                    do {
                        let record = try readPackage(directory, overridesIn: playbooksDir)
                        guard record.id == directory.lastPathComponent else { throw Invalid.package("폴더 이름과 플레이북 id가 다릅니다.") }
                        let existing = records.values.filter { $0.id != record.id }
                        guard !existing.contains(where: { other in record.identities.contains(where: other.matches) }) else {
                            throw Invalid.package("이름 또는 별칭이 다른 플레이북과 겹칩니다.")
                        }
                        records[record.id] = record
                    } catch { issues.append(Issue(directory: directory, message: error.localizedDescription)) }
                }
            } catch { issues.append(Issue(directory: root, message: error.localizedDescription)) }
        }
        return Inspection(records: records.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issues: issues)
    }

    static func resolve(_ app: String, in playbooksDir: URL = Playbooks.dir) -> PlaybookRecord? {
        let records = load(in: playbooksDir)
        return records.first { $0.id.caseInsensitiveCompare(app) == .orderedSame }
            ?? records.first { $0.name.caseInsensitiveCompare(app) == .orderedSame }
            ?? records.first { $0.matches(app) }
    }

    static func common(in playbooksDir: URL = Playbooks.dir) -> String {
        let local = playbooksDir.appendingPathComponent("공통.md")
        if let text = try? String(contentsOf: local, encoding: .utf8) { return text }
        guard let file = bundledDirectory?.appendingPathComponent("common.md") else { return "" }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Import only declared assets. Never copies package-supplied evidence or touches legacy .md/.jsonl files.
    @discardableResult
    static func install(from packageDirectory: URL, in playbooksDir: URL = Playbooks.dir) throws -> PlaybookRecord {
        let source = try readPackage(packageDirectory)
        let collisions = load(in: playbooksDir).filter { $0.id != source.id }.flatMap(\.identities)
        guard !source.identities.contains(where: { value in collisions.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }) else {
            throw Invalid.package("이름 또는 별칭이 다른 플레이북과 겹칩니다.")
        }
        let fm = FileManager.default
        let root = playbooksDir.appendingPathComponent("catalog", isDirectory: true)
        if fm.fileExists(atPath: root.path) { try requireDirectory(root) }
        else { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let destination = root.appendingPathComponent(source.id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try requireDirectory(destination) }
        let stage = root.appendingPathComponent(".install-\(source.id)-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent(".backup-\(source.id)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for path in ["manifest.json", source.manifest.guide] + (source.manifest.icon.map { [$0] } ?? []) {
            let asset = try assetURL(path, in: packageDirectory)
            let target = stage.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: asset, to: target)
        }
        let staged = try readPackage(stage)
        guard staged.manifest == source.manifest else { throw Invalid.package("가져오는 동안 플레이북 명세가 변경되었습니다. 다시 가져오세요.") }
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: stage, to: destination) }
        catch {
            if existed { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if existed { try? fm.removeItem(at: backup) }
        return try readPackage(destination, overridesIn: playbooksDir)
    }

    private static func readPackage(_ directory: URL, overridesIn playbooksDir: URL? = nil) throws -> PlaybookRecord {
        try requireDirectory(directory)
        let manifestURL = try assetURL("manifest.json", in: directory)
        let manifest = try JSONDecoder().decode(PlaybookManifest.self, from: Data(contentsOf: manifestURL))
        try validate(manifest)
        let guideURL = try assetURL(manifest.guide, in: directory)
        var guide = try String(contentsOf: guideURL, encoding: .utf8)
        if let playbooksDir {
            // Name first preserves the files created before stable ids were introduced.
            for name in [manifest.name, manifest.id] + manifest.aliases {
                let legacy = playbooksDir.appendingPathComponent(name + ".md")
                if let text = try? String(contentsOf: legacy, encoding: .utf8) { guide = text; break }
            }
        }
        let icon = try manifest.icon.map { try assetURL($0, in: directory) }
        return PlaybookRecord(manifest: manifest, directory: directory, guideText: guide, iconURL: icon)
    }

    static func validate(_ manifest: PlaybookManifest) throws {
        guard manifest.schemaVersion == 1 else { throw Invalid.package("지원하지 않는 플레이북 스키마입니다: \(manifest.schemaVersion)") }
        guard validID(manifest.id), validName(manifest.name), matches(manifest.version, #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#),
              manifest.aliases.allSatisfy(validName), !manifest.launch.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid.package("플레이북 식별자, 이름, 버전 또는 실행 검색어가 올바르지 않습니다.")
        }
        guard manifest.launch.target == nil || manifest.launch.openTool != nil else {
            throw Invalid.package("지원하지 않는 실행 대상입니다. launch.target은 browser, windows 또는 생략이어야 합니다.")
        }
        if manifest.launch.openTool != nil {
            guard PlaybookManifest.Launch.webURL(manifest.launch.search) != nil else {
                throw Invalid.package("\(manifest.launch.routeName) 실행 주소는 사용자명·비밀번호 없는 HTTP(S) 주소여야 합니다.")
            }
            guard manifest.collection == nil else { throw Invalid.package("\(manifest.launch.routeName) 플레이북에는 폰 수집 명세를 사용할 수 없습니다.") }
        }
        guard safePath(manifest.guide), URL(fileURLWithPath: manifest.guide).pathExtension.lowercased() == "md" else {
            throw Invalid.package("사용법 경로는 패키지 내부의 Markdown 파일이어야 합니다.")
        }
        if let icon = manifest.icon {
            guard safePath(icon), ["png", "jpg", "jpeg", "gif", "webp", "icns", "tiff", "tif"].contains(URL(fileURLWithPath: icon).pathExtension.lowercased()) else {
                throw Invalid.package("아이콘 경로는 패키지 내부의 이미지 파일이어야 합니다.")
            }
        }
        if let source = manifest.iconSource {
            guard let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw Invalid.package("아이콘 출처는 웹 주소여야 합니다.")
            }
        }
        guard !manifest.capabilities.isEmpty, Set(manifest.capabilities.map(\.id)).count == manifest.capabilities.count else {
            throw Invalid.package("중복되지 않는 작업 명세가 필요합니다.")
        }
        for capability in manifest.capabilities {
            guard validID(capability.id), !capability.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !capability.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(capability.inputs.map(\.name)).count == capability.inputs.count,
                  capability.inputs.allSatisfy({ matches($0.name, #"^[a-z][a-zA-Z0-9_-]{0,63}$"#) && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  !capability.steps.isEmpty, Set(capability.steps.map(\.id)).count == capability.steps.count,
                  capability.steps.allSatisfy({ validID($0.id) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stepKinds.contains($0.kind) }) else {
                throw Invalid.package("작업의 입력 또는 단계 명세가 올바르지 않습니다: \(capability.id)")
            }
        }
        guard manifest.humanSteps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Invalid.package("사용자 개입 단계가 비어 있습니다.") }
        if let collection = manifest.collection {
            guard matches(collection.key, #"^[A-Z][A-Z0-9_]{0,63}$"#), !collection.account.isEmpty,
                  ([manifest.id, manifest.name] + manifest.aliases).contains(where: { $0.caseInsensitiveCompare(collection.key) == .orderedSame }),
                  collection.scrollY.isFinite, (0...1).contains(collection.scrollY) else {
                throw Invalid.package("수집 명세가 올바르지 않습니다.")
            }
            for regex in [collection.account, collection.expand, collection.tx, collection.txpage, collection.home].compactMap({ $0 }) {
                do { _ = try NSRegularExpression(pattern: regex) }
                catch { throw Invalid.package("수집 명세의 정규식이 올바르지 않습니다.") }
            }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    private static func validID(_ value: String) -> Bool { matches(value, #"^[a-z][a-z0-9-]{0,63}$"#) }
    private static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 120 && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func requireDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Invalid.package("패키지 디렉터리에 심볼릭 링크나 파일을 사용할 수 없습니다.") }
    }
    /// Check every component, so an innocuous asset filename cannot traverse a symlinked subdirectory.
    private static func assetURL(_ path: String, in directory: URL) throws -> URL {
        guard safePath(path) else { throw Invalid.package("패키지 밖의 파일 경로는 사용할 수 없습니다.") }
        var url = directory
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let expected: FileAttributeType = index == parts.count - 1 ? .typeRegular : .typeDirectory
            guard attributes[.type] as? FileAttributeType == expected else { throw Invalid.package("플레이북 파일에 심볼릭 링크를 사용할 수 없습니다: \(path)") }
        }
        return url
    }
}
