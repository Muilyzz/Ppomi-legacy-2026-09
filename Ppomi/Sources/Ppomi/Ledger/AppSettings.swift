// Settings that are not secrets (UserDefaults). Moved out of Ledger/Model.swift so the model compiles into the iPad too.
import AppKit
import Foundation

/// Settings that are not secrets (UserDefaults). The API key lives in the Keychain (Keychain.swift).
enum AppSettings {
    private static let d = UserDefaults.standard
    static var dbPath: String {
        get { ProcessInfo.processInfo.environment["PPOMI_DB"] ?? d.string(forKey: "dbPath") ?? defaultDBPath }
        set { d.set(newValue, forKey: "dbPath") }
    }
    /// The repo's data/ledger.db (where am.py writes): walking up from the executable (.build/debug/Ppomi, dist/Ppomi.app), else the
    /// checkout this was built from (tests run from xctest). Neither — the app moved out of the repo — ~/Library/Application Support/
    /// Ppomi/data/ledger.db; shots/, playbooks/ and .env follow, relative to it.
    static var defaultDBPath: String {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {                                // .build/debug/Ppomi → repo root
            let cand = dir.appendingPathComponent("data/ledger.db").path
            if fm.fileExists(atPath: cand) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        let src = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { u, _ in u.deletingLastPathComponent() }.appendingPathComponent("data/ledger.db").path
        if fm.fileExists(atPath: src) { return src }
        let app = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ppomi/data")
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        return app.appendingPathComponent("ledger.db").path
    }
    /// Own name: deposits carrying it are transfers between own accounts. Until set in Settings, fall back to STYLE_ME from the
    /// environment or the repo's .env next to data/, which is what am.py uses — so the app reads the ledger the same way.
    static var me: String {
        get { d.string(forKey: "me").flatMap { $0.isEmpty ? nil : $0 } ?? env("STYLE_ME") ?? "" }
        set { d.set(newValue, forKey: "me") }
    }
    /// A key from the process environment, else the repo's .env next to data/ (what am.py reads): `export K=v # note` lines.
    static func env(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        let env = URL(fileURLWithPath: dbPath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
        for line in (try? String(contentsOf: env, encoding: .utf8))?.split(separator: "\n") ?? [] {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !l.hasPrefix("#"), l.hasPrefix(key + "=") else { continue }
            let v = l.dropFirst(key.count + 1).components(separatedBy: " #")[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return v.isEmpty ? nil : v
        }
        return nil
    }
    /// "뽀미야" 깨우기 말 듣기(설정에 저장). 예전엔 메뉴의 세션 스위치였다.
    static var wakeWord: Bool { get { d.bool(forKey: "wakeWord") } set { d.set(newValue, forKey: "wakeWord") } }
    /// Whole-UI size (glyphs, spacing, controls) = the OS text size(시스템 설정 › 손쉬운 사용 › 디스플레이 › 텍스트 크기), like the iPad's Dynamic Type.
    /// Body 13pt is 1; clamped 0.75–3. No app-level picker.
    static var uiScale: Double { uiScaleOverride ?? min(3, max(0.75, NSFont.preferredFont(forTextStyle: .body).pointSize / 13)) }
    /// 테스트 전용: OS 값 대신 고정 배율.
    nonisolated(unsafe) static var uiScaleOverride: Double?
}
