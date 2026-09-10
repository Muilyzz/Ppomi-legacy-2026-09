// 뽀미 opens its own chat. The workbench remains available for records and explicit device control.
import SwiftUI
import AppKit

/// A SwiftPM executable has no app bundle, so LaunchServices starts it background-only (.prohibited): claim .regular at
/// launch for a Dock icon and a place in ⌘Tab. Dock activation returns to the app-owned conversation.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingState: AppState?
    var state: AppState?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reuse the conversation even when Settings or a device workbench is already visible.
        WindowDiagnostics.log("app.reopen", ["hasVisibleWindows": flag])
        (state ?? Self.pendingState)?.openChat()
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
        if let index = CommandLine.arguments.firstIndex(of: "--configure-agent-endpoint") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let url = try? AgentNativePolicy.endpoint(CommandLine.arguments[index + 1]) else {
                fputs("음성 에이전트의 HTTPS 서버 주소가 필요합니다.\n", stderr); exit(2)
            }
            UserDefaults.standard.set(url.absoluteString, forKey: AgentNativePolicy.endpointPreference)
            print("음성 에이전트 서버 주소를 저장했습니다."); exit(0)
        }
        if CommandLine.arguments.contains("--verify-records") {
            do { try SharedRecordsSource.verifyRemote(); exit(0) }
            catch { fputs("서버 기록 대조 실패: \((error as? SharedRecordError)?.errorDescription ?? "서버 연결·키체인·원본 저장소를 확인하세요.")\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--migrate-records") {
            do { try SharedRecordsSource.migrate(); print("상단 기록을 서버 확인 모드로 전환했습니다."); exit(0) }
            catch { fputs("기록 이전을 완료하지 못했습니다. \((error as? SharedRecordError)?.errorDescription ?? "서버 연결·키체인·원본 저장소를 확인하세요.")\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--configure-shared") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                fputs("공유 서버 설정 파일 경로가 필요합니다.\n", stderr)
                exit(2)
            }
            do {
                try SharedServerConfiguration.install(from: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("공유 서버 설정을 키체인에 저장했습니다.")
                exit(0)
            } catch {
                fputs("공유 서버 설정을 저장하지 못했습니다. 설정 파일과 키체인 접근을 확인하세요.\n", stderr)
                exit(1)
            }
        }
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
        _ = Fonts.registered                            // before any window: every label and web page uses Pretendard
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        s.reloadLedger()
        let conversation = AgentVoicePanel()
        kiosk = KioskController(state: s, conversation: conversation)
        s.watchAsks()                                   // questions from the MCP server / the voice tools → workbench buttons
        s.watchLedger()                                 // committed values appear in the records panel while control continues
        do { voice = try VoiceSession(state: s, panel: conversation) } catch { voice = nil; print("voice: \(error)") }
        watcher = MirrorWatcher { s.mirroring($0) }
        watcher.start()
        AppDelegate.pendingState = s
        // Ordinary launch opens chat. Explicit kiosk launch keeps its existing workbench route.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.openInitialScreen(kiosk: CommandLine.arguments.contains("--kiosk")) }
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
        Button("대화") { state.openChat() }
        ForEach(WorkSurface.allCases) { surface in
            Button("\(surface.displayName) 제어") { state.selectSurface(surface) }
        }
        Divider()
        Button("타임라인") { show(.timeline) }
        Button("증빙·전표") { show(.evidence) }
        Button("절차") { show(.playbooks) }
        Button("몸과 생활") { show(.health) }
        Button(state.voiceOn ? "음성 끄기" : "음성 켜기 (뽀미야)") { state.voiceOn.toggle() }
        Button("대화창") { state.talk() }.keyboardShortcut(.space, modifiers: .option)
        Toggle("연결 시 대화 열기", isOn: Binding(get: { state.greetOnArrival }, set: { _ in state.toggleGreet() }))
        Button(state.kioskOn ? "키오스크 끄기" : "키오스크 켜기") { state.toggleKiosk() }.keyboardShortcut("f", modifiers: [.control, .command])
        Button("지금 수집") {
            DispatchQueue.global(qos: .userInitiated).async {
                do { try Collector().snapshot(Apps.all.map(\.key) + Apps.api) } catch { print("snapshot: \(error)") }
                DispatchQueue.main.async { state.reloadLedger() }
            }
        }
        Button("장부 새로 읽기") { state.reloadLedger() }
        SettingsLink { Text("설정…") }
        Divider()
        Button("종료") { NSApplication.shared.terminate(nil) }
    }

    /// Pick a tab and reveal the same workbench in either size mode.
    private func show(_ t: AppState.Tab) { state.show(t); state.reveal() }
}
