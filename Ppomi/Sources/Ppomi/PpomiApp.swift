// 뽀미 opens its own chat. The workbench remains available for records and explicit device control.
import SwiftUI
import AppKit
import Combine

/// 보통 앱: Dock 아이콘 + 표준 메뉴, 메뉴 막대 아이콘 없음. A SwiftPM executable has no app bundle, so LaunchServices starts it background-only
/// (.prohibited): claim .regular at launch for a Dock icon and a place in ⌘Tab. Dock activation returns to the app-owned conversation.
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
        GoogleAccount.shared.startSharing()
        // 손·눈 권한이 없어 폰 도구가 거부되면(state.setupNeeded) 그때 설정 › 시작하기를 연다 — 시작 때가 아니라 첫 도구 때.
        setupWatch = state?.$setupNeeded.dropFirst().receive(on: RunLoop.main).sink { _ in
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate()
        }
    }
    private var setupWatch: AnyCancellable?
    /// OS 텍스트 크기가 바뀌었으면(설정 앱에 다녀온 뒤) 모든 글자·여백·웹 페이지가 따라간다.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task.detached { guard GoogleAccount.session != nil else { return }; try? GoogleAccount.exchangeKeys() }   // 기다리는 기기에 키를
        let scale = AppSettings.uiScale
        guard Fonts.scale.value != scale else { return }
        Fonts.scale.value = scale
        NotificationCenter.default.post(name: Fonts.scaleChanged, object: nil)
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
        conversation.onSurfaceHint = { [weak s] surface in s?.selectSurface(surface) }   // the workbench docks the window the assistant is driving
        conversation.onPathColdStart = { [weak s] in s?.runKBColdStart() }
        let workbench = KioskController(state: s, conversation: conversation)
        kiosk = workbench
        conversation.onOverlay = { mark in workbench.showMark(mark) }   // taps, filled fields and reading drawn over the docked window
        s.watchAsks()                                   // questions from the MCP server / the voice tools → workbench buttons
        s.watchLedger()                                 // committed values appear in the records panel while control continues
        do { voice = try VoiceSession(state: s, panel: conversation) } catch { voice = nil; print("voice: \(error)") }
        watcher = MirrorWatcher { s.mirroring($0) }
        watcher.start()
        AppDelegate.pendingState = s
        // Ordinary launch opens chat. Explicit kiosk launch keeps its existing workbench route.
        DeviceRegistry.shared.persistURL = URL(fileURLWithPath: AppSettings.dbPath)
            .deletingLastPathComponent().appendingPathComponent("fleet.json")
        DeviceRegistry.shared.loadPersisted()
        s.attachThisMac()
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
        Settings { SettingsView().environmentObject(state) }
            .commands { CommandGroup(replacing: .help) {} }   // 도움말 없음. 명령은 대화(도구)와 창 안에, 설정값은 설정 창에 — 따로 메뉴 없음
    }
}
