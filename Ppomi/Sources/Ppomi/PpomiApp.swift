// 뽀미: menu bar app. Owns the one AppState, the mirroring watcher that feeds it, the workbench that follows state.kioskOn, and the
// voice session (the wake word and the realtime client). The brain is outside (`--mcp`); this process is the console.
import SwiftUI
import AppKit

/// A SwiftPM executable has no app bundle, so LaunchServices starts it background-only (.prohibited): claim .regular at
/// launch for a Dock icon and a place in ⌘Tab. The 뽀미 window is the controller's panel (see Kiosk.swift); its green
/// button expands that same window beneath iPhone Mirroring without entering a separate fullscreen Space.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingState: AppState?
    var state: AppState?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Settings can be visible while the workbench is closed. Reopen the same panel in its current size mode.
        WindowDiagnostics.log("app.reopen", ["hasVisibleWindows": flag])
        (state ?? Self.pendingState)?.reveal()
        return false                                    // the controller owns reopening; AppKit must not open another window
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        state = Self.pendingState
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct PpomiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state: AppState
    private let watcher: MirrorWatcher
    private let kiosk: KioskController                    // app-long owner of the workbench and its two size modes
    private let voice: VoiceSession?                      // app-long too: a tab must not take the microphone down with it

    init() {
        // `--mcp`: MCP server on stdin/stdout for an outside agent (Claude app / Claude Code), no UI. First thing, before any
        // GUI object: fd 1 is the protocol, so stray print()s (Mirroring, Collector) are sent to stderr and only MCPServer writes there.
        if CommandLine.arguments.contains("--mcp") {
            let proto = dup(1); dup2(2, 1)
            do { try MCPServer(dbPath: AppSettings.dbPath, fd: proto).run() } catch { fputs("mcp: \(error)\n", stderr) }
            exit(0)
        }
        // `--voice`: no GUI — leave "voice:open" in the state table and exit; the running app (AppState.pollAsk, every second)
        // finds it and opens a realtime session without a greeting. For Siri: 단축어 앱 → 새 단축어 → 동작 "셸 스크립트 실행" 에
        // `/…/.build/debug/Ppomi --voice` → 이름 "뽀미 불러" → "시리야, 뽀미 불러". Before replaceRunningInstance: this must not quit the app.
        if CommandLine.arguments.contains("--voice") {
            do { try DB(path: AppSettings.dbPath, writable: true).setState("voice:open", TS.string(Date())) } catch { fputs("voice: \(error)\n", stderr) }
            exit(0)
        }
        Self.replaceRunningInstance()
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        s.reloadLedger()
        kiosk = KioskController(state: s)
        s.watchAsks()                                   // questions from the MCP server / the voice tools → workbench buttons
        do { voice = try VoiceSession(state: s) } catch { voice = nil; print("voice: \(error)") }
        watcher = MirrorWatcher { s.mirroring($0) }
        watcher.start()
        AppDelegate.pendingState = s
        // `--kiosk`: expand the workbench on launch. Defer until AppKit has wired the panel for events.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { CommandLine.arguments.contains("--kiosk") ? s.toggleKiosk() : s.reveal() }
        // `--snapshot [APP …]`: collect and exit, no UI (launchd / cron / a terminal). Default: every app.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let keys = Array(CommandLine.arguments[(i + 1)...])
            do { try Collector().snapshot(keys.isEmpty ? Apps.all.map(\.key) + Apps.api : keys) } catch { print("snapshot: \(error)") }
            exit(0)
        }
    }

    /// `swift run Ppomi` while the app is up: quit the old GUI instance first, so there is one window, not two.
    /// Only GUI instances (.regular) are touched — a `--snapshot` job in flight is left alone.
    private static func replaceRunningInstance() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let old = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && $0.executableURL?.lastPathComponent == "Ppomi" && $0.activationPolicy == .regular
        }
        guard !old.isEmpty else { return }
        old.forEach { $0.terminate() }
        for _ in 0..<20 where old.contains(where: { !$0.isTerminated }) { usleep(100_000) }   // up to 2 s, then force
        old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    var body: some Scene {
        MenuBarExtra { MenuContent().environmentObject(state) } label: {
            Label("뽀미", systemImage: state.menuIcon).labelStyle(.iconOnly)
            StartupCheck().environmentObject(state)       // opens 설정 › 시작하기 when an agent's first phone tool is refused for missing 손·눈 (Permissions.swift)
        }
        Settings { SettingsView().environmentObject(state) }
    }
}

/// The menu bar item's menu: tabs, workbench size, collection.
private struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        Divider()
        ForEach(WorkSurface.allCases) { surface in
            Button("\(surface.displayName) 작업 화면") { state.selectSurface(surface) }
        }
        Divider()
        Button("타임라인") { show(.timeline) }
        Button("증빙·전표") { show(.evidence) }
        Button("절차") { show(.playbooks) }
        Button("몸과 생활") { show(.health) }
        Button(state.voiceOn ? "음성 끄기" : "음성 켜기 (뽀미야)") { state.voiceOn.toggle() }
        Button(state.listening ? "그만 말하기" : "지금 말하기") { state.talk() }.keyboardShortcut(.space, modifiers: .option)   // VoiceSession's ⌥Space monitors do the real work
        Toggle("도착 인사", isOn: Binding(get: { state.greetOnArrival }, set: { _ in state.toggleGreet() }))
        Button(state.kioskOn ? "키오스크 끄기" : "키오스크 켜기") { state.toggleKiosk() }.keyboardShortcut("f", modifiers: [.control, .command])
        Button("지금 수집") {
            DispatchQueue.global(qos: .userInitiated).async {
                do { try Collector().snapshot(Apps.all.map(\.key) + Apps.api) } catch { print("snapshot: \(error)") }
                DispatchQueue.main.async { state.reloadLedger() }
            }
        }
        Button("장부 다시 읽기") { state.reloadLedger() }
        SettingsLink { Text("시작하기 확인…") }             // the 시작하기 section sits at the top of the settings window
        SettingsLink { Text("설정…") }
        Divider()
        Button("종료") { NSApplication.shared.terminate(nil) }
    }

    /// Pick a tab and reveal the same workbench in either size mode.
    private func show(_ t: AppState.Tab) { state.show(t); state.reveal() }
}
