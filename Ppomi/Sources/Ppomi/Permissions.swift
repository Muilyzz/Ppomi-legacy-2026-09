// 시작하기: 뽀미의 손(손쉬운 사용)·눈(화면 기록)·귀(마이크)와 iPhone 미러링의 상태.
// 첫 요청은 시스템 프롬프트와 채팅 CTA. 이미 거절되어 다시 물을 수 없을 때만 설정 › 시작하기.
// 마이크는 통화용 선택 권한이라 여기서 묻지 않는다.
import AppKit
import AVFoundation
import SwiftUI

enum Permissions {
    /// One checklist row. `ok == nil`: nothing the code can read (advice only).
    struct Item: Identifiable {
        let id: String, name: String, ok: Bool?, note: String, button: String, open: () -> Void
    }

    /// First missing 손·눈 grant: system prompt + chat CTA. After a recorded ask, only Settings can recover.
    enum Need: String, Equatable {
        case ready, prompt, settings
    }

    static let promptNotification = Notification.Name("ppomi.permissionNeed")
    static var store: UserDefaults = .standard
    private static let askedAXKey = "ppomi.permissions.askedAX"
    private static let askedScreenKey = "ppomi.permissions.askedScreen"

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var mirroringInstalled: Bool { mirroringURL != nil }
    static var mirroringRunning: Bool { Mirroring.app() != nil }
    /// The two grants without which nothing moves: the hand and the eye.
    static var ready: Bool { accessibility && screenCapture }

    private static var mirroringURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Mirroring.bundleID) }

    /// Sequoia+ PrivacySecurity URLs. Legacy `preference.security` often lands on Screen Recording instead of Accessibility.
    static func privacyURL(_ anchor: String, legacy: Bool = false) -> URL {
        URL(string: legacy
            ? "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            : "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }
    static var repeatsPrivacyPane: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }
    static let addAppHint = "목록에 「뽀미」가 없으면 + 로 /Applications/뽀미.app 을 고르세요. 이상한 이름(이전 빌드)은 − 로 지운 뒤 뽀미.app 만 넣으세요. 켠 뒤 종료하고 다시 실행."

    @discardableResult
    static func pane(_ anchor: String) -> Bool {
        func open() -> Bool {
            NSWorkspace.shared.open(privacyURL(anchor)) || NSWorkspace.shared.open(privacyURL(anchor, legacy: true))
        }
        let ok = open()
        if repeatsPrivacyPane { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = open() } }
        return ok
    }
    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }
    /// Start a fresh copy of this executable (the .app when bundled) and quit; TCC re-reads screen-capture access on launch.
    static func relaunch() {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // Contents/MacOS/Ppomi → .app
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let target = app.pathExtension == "app" ? "open -n \"\(app.path)\"" : "\"\(exe.path)\""
        p.arguments = ["-c", "sleep 1; \(target)"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
    static func launchMirroring() {
        if let u = mirroringURL { NSWorkspace.shared.openApplication(at: u, configuration: .init()) }
    }

    static func need(accessibility ax: Bool, screen: Bool, askedAX: Bool, askedScreen: Bool) -> Need {
        if ax && screen { return .ready }
        if (!ax && !askedAX) || (!screen && !askedScreen) { return .prompt }
        return .settings
    }
    static func need() -> Need {
        need(accessibility: accessibility, screen: screenCapture,
             askedAX: store.bool(forKey: askedAXKey), askedScreen: store.bool(forKey: askedScreenKey))
    }

    /// Anchors still missing. Allow-click always opens these if !ready — recent macOS often shows no AX/Screen dialog.
    static func missingPrivacyPanes(accessibility ax: Bool, screen: Bool) -> [String] {
        (ax ? [] : ["Privacy_Accessibility"]) + (screen ? [] : ["Privacy_ScreenCapture"])
    }

    /// AX prompt + Screen Recording request. Does not mark asked: those APIs often no-op with no dialog.
    /// After `tccutil` empties the list, this prompt is once-per-process — quit and open a fresh 뽀미 first.
    static func requestSystemPrompts() {
        if !accessibility {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        if !screenCapture {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Accessibility first, then ScreenCapture after the Sequoia retry — do not rely on a leftover pane.
    static func openPrivacyPanesInOrder(_ anchors: [String]) {
        guard let first = anchors.first else { return }
        _ = pane(first)
        let rest = Array(anchors.dropFirst())
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (repeatsPrivacyPane ? 2 : 1)) { openPrivacyPanesInOrder(rest) }
    }

    /// Open each missing TCC pane. Accessibility before Screen Recording.
    @discardableResult
    static func openMissingPrivacyPanes() -> [String] {
        let anchors = missingPrivacyPanes(accessibility: accessibility, screen: screenCapture)
        guard !anchors.isEmpty else { return [] }
        NSApp.activate()
        openPrivacyPanesInOrder(anchors)
        if !accessibility { store.set(true, forKey: askedAXKey) }
        if !screenCapture { store.set(true, forKey: askedScreenKey) }
        return anchors
    }

    /// Chat CTA: small alert → try OS prompts → if still !ready, System Settings privacy panes. Every Allow click until ready.
    @discardableResult
    static func presentAllowSheet() -> Need {
        if ready { return .ready }
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용과 화면 기록이 필요해요"
        alert.informativeText = "허용하기를 누르면 손쉬운 사용 칸이 먼저 열립니다. " + addAppHint
        alert.addButton(withTitle: "허용하기")
        alert.addButton(withTitle: "나중에")
        guard alert.runModal() == .alertFirstButtonReturn else { return need() }
        requestSystemPrompts()
        if ready { return .ready }
        _ = openMissingPrivacyPanes()
        return need()
    }

    /// The rows, top to bottom.
    static func items() -> [Item] {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        return [
            Item(id: "ax", name: "손쉬운 사용", ok: accessibility,
                 note: "시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용. " + addAppHint + " 폰을 두드리는 손 · 필수",
                 button: "설정 열기") {
                // A bundle-less binary is not in the list until it asks once; the prompt registers it, then the pane opens.
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                pane("Privacy_Accessibility")
            },
            Item(id: "screen", name: "화면 기록", ok: screenCapture,
                 note: "같은 개인정보 보호 › 화면 기록. " + addAppHint + " 미러링을 읽는 눈 · 필수",
                 button: "설정 열기") {
                if !CGRequestScreenCaptureAccess() { pane("Privacy_ScreenCapture") }
            },
            Item(id: "mic", name: "마이크", ok: microphone, note: "통화(음성 대화)에만 · 선택", button: mic == .notDetermined ? "허용 요청" : "설정 열기") {
                if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { pane("Privacy_Microphone") }
            },
            Item(id: "mirror", name: "iPhone 미러링", ok: mirroringInstalled && mirroringRunning,
                 note: !mirroringInstalled ? "설치되지 않음 (macOS 15+, iPhone iOS 18+)" : mirroringRunning ? "실행 중" : "설치됨 · 실행해 두세요",
                 button: mirroringInstalled ? "실행" : "") { launchMirroring() },
            Item(id: "relaunch", name: "다시 실행", ok: screenCapture ? true : nil, note: screenCapture ? "화면 기록 반영됨" : "macOS는 화면 기록 권한을 앱 시작 때 읽어요. 켰다면 여기서 다시 실행",
                 button: screenCapture ? "" : "뽀미 다시 실행") { relaunch() },
            Item(id: "lock", name: "자동 잠금", ok: nil, note: "iPhone은 짧게(잠기면 뽀미가 이어감), Mac 화면 잠금은 길게(잠기면 미러링이 멈춤)",
                 button: "Mac 설정 열기") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!) },
        ]
    }
}
