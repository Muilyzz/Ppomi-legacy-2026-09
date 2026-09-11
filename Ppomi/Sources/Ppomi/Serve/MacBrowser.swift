import AppKit

/// Navigation only. Reading pages, entering credentials, and replaying browser steps belong to the host's browser tools.
enum MacBrowser {
    enum Failure: LocalizedError {
        case invalidURL, chromeMissing, safariMissing, invalidBrowser, mainThread, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "사용자명·비밀번호 없는 HTTP(S) 주소가 필요합니다."
            case .chromeMissing: return "Mac에서 Google Chrome을 찾지 못했습니다. Chrome을 설치한 뒤 다시 열어 주세요."
            case .safariMissing: return "Mac에서 Safari를 찾지 못했습니다."
            case .invalidBrowser: return "browser는 chrome 또는 safari여야 합니다."
            case .mainThread: return "브라우저 열기는 백그라운드 작업에서 실행해야 합니다."
            case .timedOut: return "브라우저 열기 확인 시간이 초과됐습니다. 브라우저가 열렸는지 확인한 뒤 다시 시도해 주세요."
            }
        }
    }

    static func bundleID(for browser: String?) throws -> String {
        switch (browser ?? "chrome").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "chrome", "google chrome", "com.google.chrome": return "com.google.Chrome"
        case "safari", "com.apple.safari": return "com.apple.Safari"
        default: throw Failure.invalidBrowser
        }
    }

    static func displayName(for browser: String?) throws -> String {
        try bundleID(for: browser) == "com.apple.Safari" ? "Safari" : "Google Chrome"
    }

    /// Called from the tools' worker queue or the UI's detached task, so AppKit's completion can run freely.
    static func open(_ url: URL, browser: String? = nil) throws {
        guard PlaybookManifest.Launch.webURL(url.absoluteString) != nil else { throw Failure.invalidURL }
        guard !Thread.isMainThread else { throw Failure.mainThread }
        let id = try bundleID(for: browser)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            throw id == "com.apple.Safari" ? Failure.safariMissing : Failure.chromeMissing
        }
        let done = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
            launchError = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else { throw Failure.timedOut }
        if let launchError { throw launchError }
    }
}
