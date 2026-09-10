// 시작하기: 뽀미의 손(손쉬운 사용)·눈(화면 기록)·귀(마이크)와 iPhone 미러링, OpenAI 키의 상태를 읽는 검사와 각각을 여는 동작.
// SettingsView 의 "시작하기" 섹션과 PpomiApp 의 첫 실행 자동 열기가 쓴다. 검사는 묻지 않고 읽기만 한다(preflight); 시스템 대화상자는
// 사람이 버튼을 눌렀을 때만.
import AppKit
import AVFoundation
import SwiftUI

enum Permissions {
    /// One checklist row. `ok == nil`: nothing the code can read (advice only).
    struct Item: Identifiable {
        let id: String, name: String, ok: Bool?, note: String, button: String, open: () -> Void
    }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var mirroringInstalled: Bool { mirroringURL != nil }
    static var mirroringRunning: Bool { Mirroring.app() != nil }
    /// The two grants without which nothing moves: the hand and the eye.
    static var ready: Bool { accessibility && screenCapture }

    private static var mirroringURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Mirroring.bundleID) }

    static func pane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
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

    /// The rows, top to bottom.
    static func items() -> [Item] {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        return [
            Item(id: "ax", name: "손쉬운 사용", ok: accessibility, note: "폰을 두드리고 창을 옮기는 손 · 필수", button: "설정 열기") {
                // A bundle-less binary is not in the list until it asks once; the prompt registers it, then the pane opens.
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                pane("Privacy_Accessibility")
            },
            Item(id: "screen", name: "화면 기록", ok: screenCapture, note: "미러링 창을 읽는 눈 · 필수 · 켠 뒤에는 뽀미를 다시 실행해야 반영돼요", button: "설정 열기") {
                if !CGRequestScreenCaptureAccess() { pane("Privacy_ScreenCapture") }
            },
            Item(id: "mic", name: "마이크", ok: microphone, note: "\"뽀미야\" 음성에만 · 선택", button: mic == .notDetermined ? "허용 요청" : "설정 열기") {
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


