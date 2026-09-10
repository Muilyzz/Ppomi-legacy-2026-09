// The app's state: who has the phone, what the mirroring window reports, and the workbench's content and size mode.
import Foundation
import Combine

/// Who has the phone. "평소" is not a phone state: it is what the person does on the Mac in any state.
enum Phase: Equatable {
    case idle                                   // nobody; the phone is locked nearby (connectable) or away
    case agent(job: String)                     // the agent is driving the phone ("KB 읽는 중 3/4")
    case humanTurn(reason: String)              // the agent is waiting for a specific human action ("폰에서 승인해 주세요")
    case humanUse(onScreen: Bool)               // the person uses the phone: in hand (IN_USE) or on the big screen (asked for it)
}

/// What the mirroring window's accessibility tree says (see Mirroring.swift).
enum MirrorState: String { case connected = "CONNECTED", disconnected = "DISCONNECTED", paused = "PAUSED", inUse = "IN_USE", none = "NONE" }

@MainActor
final class AppState: ObservableObject {
    let runtimeActivity = RuntimeActivity()
    @Published var phase: Phase = .idle
    @Published var mirror: MirrorState = .none
    @Published var pendingJob: String? = nil    // an agent job interrupted by the human picking the phone up; resumes on CONNECTED
    @Published var kioskOn = false              // the same workbench expanded to the screen's usable area
    @Published var phoneSize = AppState.storedSize("iphone") ?? Mirroring.defaultSize { didSet { AppState.store(phoneSize, "iphone") } }   // the mirroring window's size: the dock pane in the 뽀미 window is this big
    @Published var workSurface: WorkSurface = .iphone
    @Published var androidSize = AppState.storedSize("android") ?? AndroidWindow.defaultSize { didSet { AppState.store(androidSize, "android") } }
    @Published var androidWindowVisible = false
    @Published var androidLaunching = false
    @Published var androidLaunchError: String?
    @Published var windowsSize = AppState.storedSize("windows") ?? CGSize(width: 900, height: 620) { didSet { AppState.store(windowsSize, "windows") } }
    @Published var windowsWindowVisible = false
    /// The records page is showing (the control window is parked). Only the controller flips it.
    @Published private(set) var recordsFocused = false
    @Published private(set) var recordsFocusRequest = 0
    @Published var recordsFocusMessage: String?

    /// Asks the controller to open the records page (or return to the conversation).
    func toggleRecordsFocus() { recordsFocusRequest += 1 }
    /// Called only after the controller owns the screen lease and has parked every selected window.
    func beginRecordsFocus() {
        guard !recordsFocused else { return }
        recordsFocusMessage = nil
        recordsFocused = true
    }
    func endRecordsFocus() { recordsFocused = false }
    @Published var shown = 0                    // bumps when a menu item wants the 뽀미 window up (the controller owns it)

    func reveal() { shown += 1 }
    @Published private(set) var chatOpen = 0
    /// Conversation navigation must not trigger device window placement.
    func openChat() { chatOpen += 1 }
    @Published private(set) var workbenchShown = 0
    /// The embedded conversation asks for its window without reopening the chat (⌥Space, wake word, arrival).
    func showWorkbench() { workbenchShown += 1 }
    func openInitialScreen(kiosk: Bool) {
        if kiosk { toggleKiosk() } else { openChat() }
    }
    var surfaceSize: CGSize { size(for: workSurface) }

    func size(for surface: WorkSurface) -> CGSize {
        switch surface { case .iphone: return phoneSize; case .android: return androidSize; case .windows: return windowsSize }
    }
    func setSize(_ size: CGSize, for surface: WorkSurface) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        switch surface { case .iphone: phoneSize = size; case .android: androidSize = size; case .windows: windowsSize = size }
    }
    /// The empty control slot's one line.
    func connectionHint(for surface: WorkSurface) -> String {
        if case .agent = phase { return "뽀미 진행 중" }
        guard surface == .android else { return "\(surface.displayName) · 연결 끊김" }
        if androidLaunchError != nil { return "Android · 시작 실패" }
        return androidLaunching ? "Android · 시작 중" : "Android · 연결 끊김"
    }
    private var androidStatus: String {
        if let androidLaunchError { return "Android 시작 실패 · " + androidLaunchError }
        if androidLaunching { return "Android 에뮬레이터와 미러링을 시작하는 중…" }
        return androidWindowVisible ? "Android 화면 표시 중 · 에뮬레이터 앱 제어" : WorkSurface.android.disconnectedHint
    }

    func selectSurface(_ surface: WorkSurface) {
        guard ask == nil || surface == .iphone else { return }
        guard workSurface != surface else { reveal(); return }
        workSurface = surface
        reveal()
    }
    @Published var ledger: Ledger? = nil        // read from data/ledger.db (am.py writes it); nil until loaded
    @Published var ledgerError: String? = nil
    @Published var ledgerVersion = 0                    // bumps on every (re)load, so pages built from the ledger rebuild
    @Published var ledgerUpdatedAt: Date?
    private var ledgerMonitor: LedgerMonitor?
    private var sharedRecordsMonitor: SharedRecordsMonitor?
    private var sharedRecordVersions: [String: Int64] = [:]
    @Published var recordsServerStatus: String?
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var evidenceFocus: EvidenceFocus? = nil   // the 증빙·전표 window; nil until first open
    enum Tab: String, CaseIterable { case timeline, evidence, accounting, playbooks, health, spatial }
    @Published var tab: Tab = .timeline                  // what the workbench shows in either size mode
    @Published var voiceOn = false                       // the "뽀미야" listener (menu switch; this session only, not saved)
    @Published var listening = false                     // a voice conversation is open (after 뽀미야, until 그만 or 25 s quiet)
    /// A question from another process (the MCP server) or the voice session's tools, waiting for a workbench button.
    @Published var ask: (id: String, text: String, options: [String])? = nil
    private var askDB: DB?, askTimer: Timer?, answered: String?   // answered: the id we already pressed, until askViaDB clears it
    @Published var greetOnArrival = true                 // 뽀미 speaks first when the phone reconnects (menu; state table "greet:on")
    @Published var voiceToggle = 0                       // bumps: open/close the realtime session (⌥Space, the menu) — VoiceSession listens
    @Published var setupNeeded = 0                       // bumps: a phone tool was refused for missing 손·눈 (state table "setup:needed") — StartupCheck opens 설정 › 시작하기
    @Published var voiceOpen = 0                         // bumps: open it (`Ppomi --voice` left "voice:open" in the state table)

    func talk() { voiceToggle += 1 }
    func toggleGreet() { greetOnArrival.toggle(); try? askDB?.setState("greet:on", greetOnArrival ? "1" : "0") }

    /// Poll the state table every second (Tools.askViaDB leaves questions there, `--voice` its trigger); a new question
    /// highlights the approval area and shows the workbench in its current size mode.
    func watchAsks(dbPath: String = AppSettings.dbPath) {
        askTimer?.invalidate()
        do { askDB = try DB(path: dbPath, writable: true) } catch { print("ask: \(error)"); return }
        greetOnArrival = ((try? askDB?.state("greet:on")) ?? nil) != "0"
        startAskTimer()
    }

    private func startAskTimer() {
        askTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.pollAsk()
            }
        }
    }
    func pollAsk() {
        guard let db = askDB else { return }
        if ((try? db.state("voice:open")) ?? nil) != nil { try? db.exec("DELETE FROM state WHERE key = 'voice:open'", []); voiceOpen += 1 }
        if ((try? db.state("setup:needed")) ?? nil) != nil { try? db.exec("DELETE FROM state WHERE key = 'setup:needed'", []); setupNeeded += 1 }
        guard let q = Tools.pendingQuestion(db), q.id != answered else {
            if ask != nil { ask = nil; if case .humanTurn = phase { phase = .idle } }
            return
        }
        guard ask?.id != q.id else { return }
        // Current MCP/voice tools operate on iPhone. Show that target with its human approval.
        workSurface = .iphone
        ask = (q.id, HTML.plain(q.html).replacingOccurrences(of: "\n", with: " · "), q.options)
        if case .humanUse = phase {} else { phase = .humanTurn(reason: "승인 대기 · 작업대 하단 버튼") }
        reveal()
    }
    /// 오늘 결산 한 장(정례 보고용). 장부가 없으면 nil.
    func dailyReport() -> String? {
        guard let db = askDB, let tools = try? Tools(db: db) else { return nil }
        return tools.todayText()
    }
    /// An approval button was pressed: the answer goes back through the state table.
    static let answered = Notification.Name("ppomi.answered")   // userInfo["line"]: 비서 기록 한 줄("승인 · 용건")
    func answer(_ text: String) {
        guard let a = ask, let db = askDB else { return }
        Tools.answer(db, id: a.id, text)
        NotificationCenter.default.post(name: Self.answered, object: nil, userInfo: ["line": "\(text) · \(a.text)"])
        answered = a.id; ask = nil
        if case .humanTurn = phase { phase = .idle }
    }

    /// Switch to a records tab, opening the page (증빙 goes through showEvidence so it lands on a day that has 전표).
    func show(_ t: Tab) {
        if t == .evidence { showEvidence() } else { tab = t; openRecords() }
    }

    private func openRecords() { if !recordsFocused { toggleRecordsFocus() } }

    func showEvidence(day: Date? = nil, uid: String? = nil) {
        openRecords()
        // No day named: the timeline's day, unless it has no 전표 (today, usually) — then the newest day that has some.
        var d = day ?? selectedDay
        if day == nil, let L = ledger, !L.lines.contains(where: { (d..<KST.day(d, 1)).contains($0.ts) }),
           let last = L.lines.map(\.ts).max() { d = Calendar.current.startOfDay(for: last) }
        evidenceFocus = EvidenceFocus(day: d, uid: uid)
        tab = .evidence
    }

    /// Validate the pair in the background, then switch settings, records, and approvals in one actor turn.
    func applyLedgerSettings(dbPath: String, me: String) async throws {
        try requireRestoredWindowsForSettings()
        let prepared = try await Task.detached(priority: .utility) {
            try PreparedLedgerSettings.prepare(dbPath: dbPath, me: me)
        }.value
        try Task.checkCancellation()
        try requireRestoredWindowsForSettings()
        if SharedRecordVault.enabled, try SharedRecordVault.loadKey().sourcePath != prepared.path {
            throw SharedRecordError.sourceChanged
        }
        commitLedgerSettings(prepared)
    }

    private func requireRestoredWindowsForSettings() throws {
        guard !recordsFocused else {
            throw NSError(domain: "Ppomi.RecordsFocus", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "원장 설정은 ← 대화로 창을 복원한 뒤 바꿀 수 있습니다."])
        }
    }

    private func commitLedgerSettings(_ prepared: PreparedLedgerSettings) {
        let previousPath = URL(fileURLWithPath: (AppSettings.dbPath as NSString).expandingTildeInPath).standardizedFileURL.path
        let changedDatabase = previousPath != prepared.path
        ledgerMonitor?.stop()
        askTimer?.invalidate()
        AppSettings.dbPath = prepared.path
        AppSettings.me = prepared.me
        if !SharedRecordVault.enabled { ledger = prepared.ledger }
        ledgerError = nil
        ledgerUpdatedAt = Date()
        ledgerVersion += 1
        askDB = prepared.questions
        if changedDatabase {
            evidenceFocus = nil
            ask = nil
            answered = nil
            if case .humanTurn = phase { phase = .idle }
        }
        greetOnArrival = prepared.greetOnArrival
        startAskTimer()
        watchLedger()
    }

    /// (Re)read the ledger. Cheap (tens of KB), so callers may do it after every collection.
    func reloadLedger() {
        if SharedRecordVault.enabled {
            if sharedRecordsMonitor == nil { watchLedger() }
            else { sharedRecordsMonitor?.request() }
            return
        }
        do {
            ledger = try Ledger.load(dbPath: AppSettings.dbPath, me: AppSettings.me)
            ledgerError = nil
            ledgerUpdatedAt = Date()
        }
        catch { ledgerError = "\(error)" }
        ledgerVersion += 1
        if ledgerMonitor != nil { watchLedger() }
    }

    func watchLedger() {
        runtimeActivity.start(ledgerPath: AppSettings.dbPath)
        if SharedRecordVault.enabled {
            ledgerMonitor?.stop()
            if sharedRecordsMonitor == nil {
                recordsServerStatus = "Supabase · 서버 기록 확인 중"
                sharedRecordsMonitor = SharedRecordsMonitor { [weak self] update in
                    guard let self else { return }
                    self.recordsServerStatus = update.status
                    self.ledgerError = update.error
                    self.ledgerUpdatedAt = update.confirmedAt
                    if self.sharedRecordVersions != update.versions || self.ledger == nil {
                        self.ledger = update.ledger
                        self.sharedRecordVersions = update.versions
                        self.ledgerVersion += 1
                    }
                }
            }
            sharedRecordsMonitor?.start()
            return
        }
        if ledgerMonitor == nil {
            ledgerMonitor = LedgerMonitor(onUpdate: { [weak self] ledger in
                guard let self else { return }
                self.ledger = ledger
                self.ledgerError = nil
                self.ledgerUpdatedAt = Date()
                self.ledgerVersion += 1
            }, onError: { [weak self] error in
                self?.ledgerError = error
            })
        }
        ledgerMonitor?.start(dbPath: AppSettings.dbPath, me: AppSettings.me)
    }

    /// The phone caption (bottom band) and the menu's first line.
    var statusLine: String {
        if listening { return "대화 중 · " + phaseLine }
        if case .idle = phase, !Permissions.ready { return "손과 눈 권한이 아직 없어요 · 설정 › 시작하기" }
        if case .idle = phase, voiceOn { return phaseLine + " · 뽀미야 라고 부르면 들음" }
        return phaseLine
    }

    private var phaseLine: String {
        switch phase {
        case .idle, .humanUse(true):
            if workSurface == .android { return androidStatus }
            if workSurface == .windows {
                return windowsWindowVisible ? "Parallels 창 표시 중 · 인증은 해당 창에서" : "Parallels에서 Windows 창을 열어 주세요"
            }
            switch mirror {
            case .connected: return "폰 연결됨 · 대기"
            case .none: return "미러링 없음"
            case .inUse: return "손에 든 iPhone · 잠그면 돌아옴"
            default: return "연결 끊김 · 20초마다 다시 시도"       // MirrorWatcher presses 다시 시도 every 20 s
            }
        case .agent(let job): return "뽀미가 \(job) 중"
        case .humanTurn(let r): return r
        case .humanUse:
            if workSurface == .android { return androidStatus }
            if workSurface == .windows {
                return windowsWindowVisible ? "Parallels 창 표시 중 · 인증은 해당 창에서" : "Parallels에서 Windows 창을 열어 주세요"
            }
            return "손에 든 iPhone · 잠그면 돌아옴" + (pendingJob.map { " · 이어서 \($0)" } ?? "")
        }
    }
    var menuIcon: String {
        switch phase { case .idle: return "circle"; case .agent: return "circle.fill"; case .humanTurn: return "hand.raised.fill"; case .humanUse: return "iphone" }
    }

    /// Menu, green zoom, and ⌃⌘F switch the workbench size. Phone use does not hide or collapse the workbench.
    func toggleKiosk() {
        kioskOn.toggle()
        if kioskOn { phase = .humanUse(onScreen: true) }
        else {
            if case .humanUse = phase { phase = pendingJob.map { .agent(job: $0) } ?? .idle; pendingJob = nil }
        }
    }

    /// Feed a mirroring event. The transitions of the table in the design notes.
    func mirroring(_ s: MirrorState) {
        mirror = s
        if ask != nil, case .humanTurn = phase { return }
        switch (s, phase) {
        case (.inUse, .agent(let job)): pendingJob = job; phase = .humanUse(onScreen: false)
        case (.inUse, .idle): phase = .humanUse(onScreen: false)
        case (.connected, .humanUse(false)):
            if let job = pendingJob { pendingJob = nil; phase = .agent(job: job) } else { phase = kioskOn ? .humanUse(onScreen: true) : .idle }
        case (.connected, .humanTurn): phase = pendingJob.map { .agent(job: $0) } ?? .idle; pendingJob = nil
        default: break
        }
    }
}

extension AppState {
    /// The last measured control-window size per surface ("w h" under `surfaceSize.<surface>`), so the slot and the
    /// stage pull's drop point fit the window before it is on stage again instead of a default it then corrects.
    static func storedSize(_ surface: String) -> CGSize? {
        let parts = (UserDefaults.standard.string(forKey: "surfaceSize." + surface) ?? "").split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
    static func store(_ size: CGSize, _ surface: String) {
        UserDefaults.standard.set("\(Int(size.width)) \(Int(size.height))", forKey: "surfaceSize." + surface)
    }
}
