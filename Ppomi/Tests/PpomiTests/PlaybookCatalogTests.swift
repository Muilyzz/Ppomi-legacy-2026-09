import XCTest
@testable import Ppomi

final class PlaybookCatalogTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func manifest(id: String = "sample", name: String = "새 앱") -> PlaybookManifest {
        PlaybookManifest(id: id, name: name, version: "0.1.0", aliases: [id.uppercased()],
                         launch: .init(search: id), capabilities: [
                            .init(id: "browse", title: "새 작업 조회", description: "설정 파일만으로 등록한 작업입니다.", inputs: [
                                .init(name: "query", label: "검색어", required: true)
                            ], steps: [.init(id: "open", title: "앱 열기", kind: "open"), .init(id: "read", title: "화면 읽기", kind: "read")])
                         ], humanSteps: ["로그인은 직접 진행합니다."], guide: "guide.md")
    }
    private func package(_ manifest: PlaybookManifest, folder: String = UUID().uuidString) throws -> URL {
        let directory = temporary.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        // Write a fixed package guide: invalid manifest paths must never be followed by fixture setup.
        try "# 패키지 안내\n코드 수정 없이 표시됩니다.\n".write(to: directory.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        return directory
    }

    func testBundledCatalogHasRealIconAssetsAndStructuredSteps() throws {
        let result = PlaybookCatalog.inspect(in: temporary)
        XCTAssertTrue(result.issues.isEmpty, result.issues.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(Set(result.records.map(\.id)).isSuperset(of: Set(["kb", "kbank", "kakao", "toss", "yeogi", "iros", "eais", "accountinfo", "joint-certificate", "kb-enterprise", "hometax", "gov24", "efine", "nps", "nhis"])))
        for record in result.records {
            if record.manifest.icon == nil { XCTAssertNil(record.iconURL, "no invented icon for a site without official artwork"); continue }
            let icon = try XCTUnwrap(record.iconURL)
            XCTAssertGreaterThan(try Data(contentsOf: icon).count, 100)
            XCTAssertFalse(record.guideText.contains("콤보:"), "Bundled steps belong in the manifest only")
            XCTAssertFalse(record.manifest.capabilities[0].steps.isEmpty)
        }
        XCTAssertEqual(PlaybookCatalog.resolve("KB", in: temporary)?.id, "kb")
        XCTAssertEqual(PlaybookCatalog.resolve("여기어때", in: temporary)?.id, "yeogi")
        XCTAssertFalse(PlaybookCatalog.common(in: temporary).isEmpty)
    }

    func testAccountInfoKeepsItsIdentityAndUsesTheBrowserRouteWithoutPhoneCollection() throws {
        let record = try XCTUnwrap(PlaybookCatalog.resolve("AccountInfo", in: temporary))
        XCTAssertEqual(record.id, "accountinfo")
        XCTAssertEqual(PlaybookCatalog.resolve("어카운트인포", in: temporary)?.id, record.id)
        XCTAssertTrue(record.manifest.launch.isBrowser)
        let url = try XCTUnwrap(record.manifest.launch.browserURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNotNil(url.host)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(record.manifest.collection)
        XCTAssertNotEqual(record.manifest.version, "0.1.0", "The Android procedure's evidence must not count as validation of the new web route")
    }

    func testWindowsTargetPackageValidatesResolvesAndRefusesThePhoneRoute() throws {
        var value = manifest(id: "hometax-like", name: "Windows 사이트")
        value.launch = .init(search: "https://example.com/exe", target: "windows")
        XCTAssertNoThrow(try PlaybookCatalog.validate(value))
        XCTAssertTrue(value.launch.isWindows)
        XCTAssertFalse(value.launch.isBrowser)
        XCTAssertNil(value.launch.browserURL)
        XCTAssertEqual(value.launch.windowsURL?.absoluteString, "https://example.com/exe")
        var bad = value; bad.launch.search = "https://user:secret@example.com/"
        XCTAssertThrowsError(try PlaybookCatalog.validate(bad))
        bad = value; bad.collection = .init(key: "HOMETAX_LIKE", account: "계좌")
        XCTAssertThrowsError(try PlaybookCatalog.validate(bad))

        let runtime = temporary.appendingPathComponent("runtime")
        _ = try PlaybookCatalog.install(from: package(value), in: runtime)
        XCTAssertEqual(PlaybookCatalog.resolve("HOMETAX-LIKE", in: runtime)?.id, "hometax-like")

        let tools = try Tools(db: DB(path: temporary.appendingPathComponent("ledger.db").path, writable: true))
        tools.footprintDir = runtime
        tools.openBrowser = { _ in XCTFail("a Windows package must not open Mac Chrome") }
        defer { Tools.fake = nil }
        var hands: [[String]] = []
        Tools.fake = (screen: { [] }, hand: { hands.append($0) })
        XCTAssertTrue(tools.execute("phone_open", ["app": "hometax-like"]).contains("windows_open"))
        XCTAssertTrue(tools.execute("phone_installed", ["names": "hometax-like"]).contains("windows_open"))
        XCTAssertTrue(tools.execute("run_combo", ["app": "hometax-like"]).contains("windows_open"))
        XCTAssertEqual(tools.execute("browser_open", ["app": "hometax-like"]), "오류: Windows 패키지 · windows_open")
        XCTAssertTrue(hands.isEmpty)
        tools.currentText = "해줘"
        XCTAssertTrue(tools.execute("windows_open", ["app": "hometax-like"]).hasPrefix("열었다"))
        XCTAssertEqual(hands, [["open", "https://example.com/exe"]])
    }

    func testNewAppInstallsAndCollectorUsesManifestWithoutCodeChanges() throws {
        var value = manifest()
        value.collection = .init(key: "SAMPLE", account: "계좌", tx: "거래", scrollY: 0.65)
        let source = try package(value)
        let runtime = temporary.appendingPathComponent("runtime")
        let installed = try PlaybookCatalog.install(from: source, in: runtime)
        XCTAssertEqual(installed.manifest, value)
        XCTAssertEqual(installed.summary, "새 작업 조회")
        XCTAssertEqual(installed.directory, runtime.appendingPathComponent("catalog/sample", isDirectory: true))
        XCTAssertEqual(PlaybookCatalog.load(in: runtime, includeBundled: false).map(\.id), ["sample"])
        XCTAssertEqual(PlaybookCatalog.resolve("SAMPLE", in: runtime)?.manifest.capabilities[0].inputs[0].name, "query")
        let config = try XCTUnwrap(Apps.configurations(from: PlaybookCatalog.load(in: runtime, includeBundled: false)).first)
        XCTAssertEqual(config.key, "SAMPLE")
        XCTAssertEqual(config.search, "sample")
        XCTAssertEqual(config.tx, "거래")
        XCTAssertEqual(config.scrollY, 0.65)
    }

    func testPackageUpgradePreservesLegacyNotesAndEvidence() throws {
        let runtime = temporary.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let notes = runtime.appendingPathComponent("새 앱.md")
        let evidence = runtime.appendingPathComponent("새 앱.jsonl")
        try "내가 배운 절차\n".write(to: notes, atomically: true, encoding: .utf8)
        let evidenceBytes = Data("{\"local-evidence\":true}\n".utf8)
        try evidenceBytes.write(to: evidence)
        var value = manifest()
        _ = try PlaybookCatalog.install(from: package(value), in: runtime)
        value.version = "0.2.0"
        let updated = try PlaybookCatalog.install(from: package(value), in: runtime)
        XCTAssertEqual(updated.manifest.version, "0.2.0")
        XCTAssertEqual(updated.guideText, "내가 배운 절차\n")
        XCTAssertEqual(try Data(contentsOf: evidence), evidenceBytes)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "내가 배운 절차\n")
    }

    func testLegacyAliasGuideAndCommonOverrideBundledText() throws {
        try "별칭으로 저장된 메모".write(to: temporary.appendingPathComponent("KB.md"), atomically: true, encoding: .utf8)
        try "사용자가 보완한 공통 규칙".write(to: temporary.appendingPathComponent("공통.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PlaybookCatalog.resolve("kb", in: temporary)?.guideText, "별칭으로 저장된 메모")
        XCTAssertEqual(PlaybookCatalog.common(in: temporary), "사용자가 보완한 공통 규칙")
    }

    func testRejectsSchemaAndUnsafePathsBeforeInstalling() throws {
        let runtime = temporary.appendingPathComponent("runtime")
        var values: [PlaybookManifest] = []
        var unsupported = manifest(); unsupported.schemaVersion = 2; values.append(unsupported)
        var unsafeID = manifest(); unsafeID.id = "../escape"; values.append(unsafeID)
        for path in ["../guide.md", "/guide.md", "nested/../guide.md", "nested//guide.md", "nested\\guide.md"] {
            var invalid = manifest(); invalid.guide = path; values.append(invalid)
        }
        var badIcon = manifest(); badIcon.icon = "../icon.png"; values.append(badIcon)
        var badStep = manifest(); badStep.capabilities[0].steps[0].kind = "execute-shell"; values.append(badStep)
        for value in values { XCTAssertThrowsError(try PlaybookCatalog.install(from: package(value), in: runtime)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    }

    func testRejectsSymlinkedAssetsAndSubdirectories() throws {
        let runtime = temporary.appendingPathComponent("runtime")
        let secret = temporary.appendingPathComponent("outside.md")
        try "밖의 파일".write(to: secret, atomically: true, encoding: .utf8)
        let direct = try package(manifest())
        try FileManager.default.removeItem(at: direct.appendingPathComponent("guide.md"))
        try FileManager.default.createSymbolicLink(at: direct.appendingPathComponent("guide.md"), withDestinationURL: secret)
        XCTAssertThrowsError(try PlaybookCatalog.install(from: direct, in: runtime))
        var nestedManifest = manifest(); nestedManifest.guide = "linked/outside.md"
        let nested = try package(nestedManifest)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("linked"), withDestinationURL: temporary)
        XCTAssertThrowsError(try PlaybookCatalog.install(from: nested, in: runtime))
        let linkedPackage = temporary.appendingPathComponent("linked-package")
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: nested)
        XCTAssertThrowsError(try PlaybookCatalog.install(from: linkedPackage, in: runtime))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    }

    func testMalformedLocalOverrideIsReportedWithoutReplacingBundledPackage() throws {
        var invalid = manifest(id: "kb", name: "KB스타뱅킹")
        invalid.schemaVersion = 9
        _ = try package(invalid, folder: "catalog/kb")
        let result = PlaybookCatalog.inspect(in: temporary)
        XCTAssertEqual(result.records.first { $0.id == "kb" }?.manifest.schemaVersion, 1)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("스키마"))
    }

    func testRejectsNewPackageHijackingAnExistingAlias() throws {
        var value = manifest(); value.aliases.append("KB")
        XCTAssertThrowsError(try PlaybookCatalog.install(from: package(value), in: temporary.appendingPathComponent("runtime")))
    }

    func testExistingCollectorSettingsArePreserved() throws {
        let configs = Apps.configurations(from: PlaybookCatalog.load(in: temporary))
        XCTAssertEqual(configs.map(\.key), ["KB", "KBANK", "KAKAO", "TOSS", "KAKAOPAY", "KBBIZ", "SAMSUNG", "SHINHAN"], "옛 순서 그대로, 새 패키지는 뒤에 이름순")
        XCTAssertEqual(configs.last?.debt, "대출", "신한: 대출 이름의 잔액은 음수(부채)로 — 커스텀 디코더가 debt 를 읽어야 한다")
        XCTAssertEqual(configs.last?.list, "^계좌$"); XCTAssertNil(configs.first?.debt)
        XCTAssertEqual(configs.map(\.search), ["kb", "kbank", "kakaobank", "toss", "카카오페이", "KB스타기업뱅킹", "삼성증권", "신한"])
        XCTAssertEqual(configs[0].account, #"\(\d{4}\)|\d{6}-\d{2}-\d{6}"#)
        XCTAssertEqual(configs[0].expand, "^더보기")
        XCTAssertEqual(configs[0].list, "내 계좌 전체보기")
        XCTAssertEqual(configs[0].tx, "^KB국민ONE통장")
        XCTAssertEqual(configs[0].txpage, "거래내역조회")
        XCTAssertEqual(configs[0].home, "내 계좌 전체보기|나의 총 자산|이번 주 카드결제")
        XCTAssertEqual(configs[0].scrollY, 0.7)
        XCTAssertEqual(configs[1].homeLabel, "케이뱅크")
        XCTAssertNil(configs[1].tx)
        XCTAssertEqual(configs[2].tx, "통장")
        XCTAssertEqual(configs[2].home, "다른금융계좌|홈 혜택")
        XCTAssertNil(configs[3].tx)
        XCTAssertEqual(configs[3].scrollY, 0.5)
    }

    func testCollectorAcceptsIDsNamesAndAliasesWhileKeepingLedgerKeys() throws {
        let bundled = PlaybookCatalog.load(in: temporary)
        for query in ["kb", "KB", "KB스타뱅킹", "  kb\n"] {
            XCTAssertEqual(Apps.config(query, from: bundled)?.key, "KB")
        }
        for query in ["kakao", "KAKAO", "카카오뱅크", "kakaobank"] {
            XCTAssertEqual(Apps.config(query, from: bundled)?.key, "KAKAO")
        }
        XCTAssertNil(Apps.config("yeogi", from: bundled))
        XCTAssertNil(Apps.config("unknown", from: bundled))
        XCTAssertNil(Apps.config("TOSSINVEST", from: bundled)) // remains in the API collector's own path

        var value = manifest()
        value.aliases.append("예전 이름")
        value.collection = .init(key: "SAMPLE", account: "계좌")
        let runtime = temporary.appendingPathComponent("runtime")
        _ = try PlaybookCatalog.install(from: package(value), in: runtime)
        let records = PlaybookCatalog.load(in: runtime, includeBundled: false)
        for query in ["sample", "SAMPLE", "새 앱", "예전 이름"] {
            let config = try XCTUnwrap(Apps.config(query, from: records))
            XCTAssertEqual(config.key, "SAMPLE")
            XCTAssertEqual(config.search, "sample")
        }
    }
}
