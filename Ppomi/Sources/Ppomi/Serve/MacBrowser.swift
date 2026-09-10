import AppKit

/// Navigation only. Reading pages, entering credentials, and replaying browser steps belong to the host's browser tools.
enum MacBrowser {
    enum Failure: LocalizedError {
        case invalidURL, chromeMissing, mainThread, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "사용자명·비밀번호 없는 HTTP(S) 주소가 필요합니다."
            case .chromeMissing: return "Mac에서 Google Chrome을 찾지 못했습니다. Chrome을 설치한 뒤 다시 열어 주세요."
            case .mainThread: return "브라우저 열기는 백그라운드 작업에서 실행해야 합니다."
            case .timedOut: return "Chrome 열기 확인 시간이 초과됐습니다. 브라우저가 열렸는지 확인한 뒤 다시 시도해 주세요."
            }
        }
    }

    /// Called from the tools' worker queue or the UI's detached task, so AppKit's completion can run freely.
    static func open(_ url: URL) throws {
        guard PlaybookManifest.Launch.webURL(url.absoluteString) != nil else { throw Failure.invalidURL }
        guard !Thread.isMainThread else { throw Failure.mainThread }
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw Failure.chromeMissing
        }
        let done = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: .init()) { _, error in
            launchError = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else { throw Failure.timedOut }
        if let launchError { throw launchError }
    }
}
