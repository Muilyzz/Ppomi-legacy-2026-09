// The voice client, alive for the app's life (PpomiApp holds it). The local listener (Voice) waits for 뽀미야; the wake
// word hands the microphone to an OpenAI Realtime session (RealtimeVoice) whose tools run here, in this Mac, through
// Tools.execute. Money still leaves only through the ring: confirm_payment / ask_choice go to Tools.askViaDB, so the
// buttons appear under the phone (AppState.ask) and a spoken "승인" never answers them. Transcripts land on the caption
// (state.heard / state.said) and in chat_log. No text input: the brain that types lives outside (MCP).
// Three more ways in: the phone reconnecting (뽀미 greets first when Arrival.shouldGreet says the person is there), ⌥Space
// (toggle, no greeting), and `Ppomi --voice` (a Siri shortcut; AppState.pollAsk finds its mark in the state table).
import AppKit
import Combine
import Foundation

@MainActor
final class VoiceSession {
    let state: AppState
    let db: DB
    let tools: Tools
    private var subs: [AnyCancellable] = []
    private var keyMonitors: [Any] = []                      // ⌥Space, global (other apps front) and local (ours; eats the chord)
    private var voice: Voice? = nil                          // the "뽀미야" listener while the menu's 음성 is on
    private var live: RealtimeVoice? = nil                   // the speech-to-speech session after the wake word (owns the mic until it closes)
    private var liveIdle: Timer? = nil                       // 25 s with no event → the session closes (paused while a tool runs)
    private var liveBusy = false                             // a tool is running on the session's queue (main-only, like liveIdle)
    private let lock = NSLock()
    private var liveText = ""                                // the last thing the user said: the tools' gate reads it (lock)

    init(state: AppState, dbPath: String = AppSettings.dbPath) throws {
        self.state = state
        db = try DB(path: dbPath, writable: true)             // its own handle: the tools queue must not share the console's
        tools = try Tools(db: db)
        let db = db
        tools.askOwner = { html, opts in Tools.askViaDB(db, html, opts) }   // → AppState.pollAsk → buttons on the ring
        tools.onTool = { [weak self] name in
            if name.hasPrefix("phone_") || name == "collect_now" || name == "inbody_capture" { self?.phase(.agent(job: name == "collect_now" || name == "inbody_capture" ? "수집" : "폰 조작")) }
        }
        tools.onHuman = { [weak self] r in self?.phase(.humanTurn(reason: r)) }   // Face ID on the physical phone
        subs = [state.$voiceOn.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in self?.setVoice(on) },   // willSet: closeLive reads voiceOn, so wait for the set
                // $mirror fires on willSet: wait a turn so state (phase, mirror) has settled before the greeting looks at it
                state.$mirror.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] m in if m == .connected { self?.arrived() } },
                state.$voiceToggle.dropFirst().sink { [weak self] _ in self?.toggleLive() },
                state.$voiceOpen.dropFirst().sink { [weak self] _ in self?.toggleLive(open: true) }]
        keyMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in if Self.isTalkChord(e) { MainActor.assumeIsolated { self?.toggleLive() } } },
                       NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                           guard Self.isTalkChord(e) else { return e }
                           DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggleLive() } }; return nil }].compactMap { $0 }
    }

    nonisolated static func isTalkChord(_ e: NSEvent) -> Bool {
        e.keyCode == 49 && e.modifierFlags.intersection([.command, .control, .option, .shift]) == .option
    }

    /// ⌥Space and the menu: close the session if one is open, else open it without a greeting. `open`: only open (`--voice`).
    func toggleLive(open: Bool = false) {
        if live != nil { if !open { closeLive("단축키") }; return }
        guard let key = Chat.apiKey, !key.isEmpty else { state.said = "API 키가 없어 실시간 대화를 열지 못함"; NSSound(named: "Pop")?.play(); return }
        openLive(key)
    }

    /// The phone reconnected. 뽀미 speaks first when the person is evidently here (Arrival.shouldGreet) and nothing else
    /// has the phone or the microphone; otherwise the caption's "폰 연결됨" is all. Never while the phone is in hand (.inUse).
    private func arrived() {
        guard state.greetOnArrival, live == nil, state.mirror == .connected, let key = Chat.apiKey, !key.isEmpty else { return }
        if case .agent = state.phase { return }                   // an outside brain resumed its job on CONNECTED: not the moment
        let last = ((try? db.state("greet:last")) ?? nil).flatMap(TS.parse)
        guard Arrival.shouldGreet(now: Date(), lastGreet: last, idleSeconds: Arrival.idleSeconds(), screenLocked: Arrival.screenLocked(), muted: Arrival.muted()) else { return }
        try? db.setState("greet:last", TS.string(Date()))
        openLive(key, greet: "폰이 방금 연결됐다. 짧게 인사하고 무엇을 할지 한 문장으로 묻는다.")
    }

    /// The menu's 음성 switch. Status lands in state.listening; start() failing (permission denied, asset install,
    /// no input device) turns the switch back off with a notice. The wake word opens a realtime session (openLive) when
    /// there is an API key; without one the command only shows on the caption — there is no text brain to run it.
    func setVoice(_ on: Bool) {
        voice?.stop(); voice = nil
        guard on else { closeLive("음성 끔"); return }
        if ProcessInfo.processInfo.environment["PPOMI_LIVE_NOW"] != nil, let key = Chat.apiKey, !key.isEmpty { openLive(key); return }   // test hook: skip the wake word
        let v = Voice()
        v.onStatus = { [weak self] st in
            guard let self else { return }
            let on = st == .listening
            if on, let key = Chat.apiKey, !key.isEmpty { self.openLive(key); return }
            if on, !self.state.listening { NSSound(named: "Pop")?.play(); self.state.said = "API 키가 없어 실시간 대화를 열지 못함" }
            if !on, self.state.listening { NSSound(named: "Bottle")?.play() }
            self.state.listening = on
        }
        v.onCommand = { [weak self] t in self?.state.heard = t }
        voice = v
        Task { [weak self] in
            do { try await v.start() }
            catch is CancellationError {}                    // setVoice(false) came first
            catch { self?.state.voiceOn = false; Notify.post("음성", error.localizedDescription) }
        }
    }

    // MARK: realtime voice

    static let friendSystem = """
        너는 '뽀미', 이 사람의 개인 비서이자 편한 친구다. 이 사람은 카톡 한 문장 한 문장이 힘들 때가 있고, 대화를 미루는 경향을 스스로 알고 있다.
        어떻게 말하나: 먼저 듣고, 느낌을 한 번 짚어주고, 질문은 한 번에 하나만. 짧게(2~5문장). 설교·목록·정답 강조 금지. 상대가 반말이면 반말, 존댓말이면 존댓말.
        상대의 말을 "~하고 싶구나" 식으로 되풀이하지 말고 바로 본론으로. 사실 관계: 폰 수집(미러링)은 아이폰이 잠겨 있어야 되고 잠금 해제·사용 중이면 끊긴다.
        할 수 있는 것: 지금 어떤 게 힘든지 같이 정리하기, 상대 말의 의도를 여러 가능성으로 읽어주기, 답장 문장을 함께 다듬기(원하면 draft_reply), 미루는 항목을 note_later 로 적어두자고 제안하기, 돈 얘기가 나오면 뽀미가 알고 있는 숫자(today_spending, balances, weekly_review)로 사실을 말해주기, 폰의 앱이나 웹으로 가격을 알아보고 예약·결제까지 가기.
        하지 않는 것: 대신 메시지를 보내기, 진단·병명 언급, 근거 없는 확신, 과한 위로 문구. 로그인과 비밀번호·카드번호 입력은 절대 하지 않는다(사용자가 폰에서 직접). 결제 버튼은 confirm_payment 승인이 있을 때만 누르고, 이체·송금은 하지 않는다. 자해·자살 신호가 보이면 짧게 걱정을 전하고 1393(자살예방상담전화, 24시간)·1577-0199(정신건강 위기상담)를 알려주고 지금 곁에 있을 수 있는 사람이 있는지 묻는다.
        너는 사람이 아니고 그걸 숨기지 않는다. 하지만 매일 같은 자리에 있는 존재라는 점은 진짜다.
        """
    private static let liveRules = """


        지금은 음성 대화다. 짧게, 한두 문장으로 말한다. 돈이 나가는 결제는 화면 버튼 승인이 필요하다고 말하고 confirm_payment 도구를 쓴다. \
        대화를 끝내자는 말(그만, 끝, 됐어)이 오면 짧게 인사하고 end_conversation 도구를 부른다. \
        폰 앱으로 뭔가 하기 전에는 read_playbook 으로 그 앱의 절차(콤보와 버릇)를 먼저 읽고 그대로 따른다. 사용자 말이 불분명하면 짧게 되묻는다. \
        식사·운동·컨디션을 기록해 달라면 발생 시각을 확인해 record_health로 저장한다. reported는 사용자가 말한 내용, aiEstimate는 추정이며 섞지 않는다. 모르는 수치는 생략하고 사용자 확인 상태를 부여하지 않는다. 건강 기록 조회는 health_records, 본인 인바디 결과 화면 저장은 inbody_capture를 사용한다. \
        ‘선크림 발랐어’처럼 실제 사용자 보고만 record_health의 kind=habit, activityID=sunscreen, activityStatus=completed, attribution=reported로 기록하며 occurredAt은 보고 시각, activityDay와activityTimeZone은 실제 바른 날짜·시간대다. 어제 바르고 오늘 보고했다면 분리하고 모호하면 물으며 알림·예정·사진·미래 날짜를 완료로 만들지 않는다. \
        인사 뒤 첫 말이 너에게 한 말이 아니면(옆 사람 대화, TV) 아무 말 없이 end_conversation 을 부른다.

        """
    private static let playbookSpec = ToolSpec(name: "read_playbook", description: "공통 명세와 앱별 절차, 실제 재생 기록을 읽는다. 폰 앱 작업 전에 먼저 부른다. app 을 비우면 공통 규칙과 앱 목록.", params: ["app": ("string", "플레이북 ID 또는 앱 이름, 예: yeogi")])
    private static let endSpec = ToolSpec(name: "end_conversation", description: "사용자가 대화를 끝내자고 하면(그만, 끝, 됐어) 짧게 인사한 뒤 부른다. 음성 세션이 닫힌다.")

    /// The wake word was heard: the local listener gives up the microphone and a realtime session takes it. Its transcripts
    /// land on the caption and in chat_log. Tools run on its background queue through this Tools instance, so
    /// confirm_payment ends in askViaDB → the ring's buttons; a spoken "승인" never answers that.
    private func openLive(_ key: String, greet: String? = nil) {
        guard live == nil else { return }
        voice?.onStatus = nil; voice?.stop(); voice = nil          // one mic tap at a time
        let cfg = RealtimeVoice.Config(instructions: Self.friendSystem + Self.liveRules, tools: Tools.specs + [Self.endSpec, Self.playbookSpec])   // playbooks on demand, not in every session
        let l = RealtimeVoice(config: cfg, apiKey: key)
        l.execute = { [weak self] name, args in
            guard let self else { return "세션이 없다" }
            if name == "read_playbook" {
                let app = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let all = Playbooks.all()
                if app.isEmpty { return PlaybookCatalog.common() + "\n앱: " + PlaybookCatalog.load().map { "\($0.id): \($0.name)" }.joined(separator: ", ") }
                if let record = PlaybookCatalog.resolve(app) {
                    let evidence = Playbooks.evidence(record)
                    return Playbooks.definition(record) + "\n\n" + record.guideText + "\n저장된 걸음 \(evidence.savedSteps) · 자동 재생 성공 \(evidence.replayOK) · 자동 재생 실패 \(evidence.replayFail)"
                }
                return all.first { $0.app == app }?.text ?? "그 앱의 절차는 아직 없다. 공통 규칙대로 화면을 읽어 가며 진행하고, 배운 버릇은 note_playbook 으로 남겨라."
            }
            if name == "end_conversation" {                          // ponytail: 3 s so the goodbye (queued, or spoken after this result) plays out
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.closeLive("사용자가 끝냄") } }
                return "끝"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.liveBusy = true; self.liveIdle?.invalidate() } }   // a phone tool or the 결제 승인 wait takes minutes: not "quiet"
            defer { DispatchQueue.main.async { MainActor.assumeIsolated { self.liveBusy = false; self.armLiveIdle() } } }
            self.tools.currentText = self.lock.withLock { self.liveText }
            return self.tools.execute(name, args)
        }
        l.onEvent = { [weak self] e in
            guard let self else { return }
            self.armLiveIdle()
            switch e {
            case .userSaid(let t): self.lock.withLock { self.liveText = t }; self.log("user", t); self.state.heard = t
            case .assistantSaid(let t): self.log("assistant", t); self.state.said = t; if !self.liveBusy { self.phase(nil) }   // busy: the rim keeps 폰 조작 / 승인
            case .toolCall: break                                      // tools.onTool already colors the rim
            case .closed(let r):                                       // live still set: the session closed itself (session.update 거부, 연결 끊김)
                if self.live != nil { self.state.said = "실시간 대화가 끊김 · \(r)" }
                self.closeLive(r)
            }
        }
        live = l
        state.listening = true; NSSound(named: "Pop")?.play()
        armLiveIdle()
        Task { [weak self] in
            do { try await l.open(); if let greet { l.say(greet) } }   // after session.update, in order: the model speaks first
            catch {
                guard let self, self.live === l else { return }
                print("Live: open failed: \(error)")
                self.state.said = "실시간 연결 실패: \(error.localizedDescription)"
                self.closeLive("연결 실패")                            // back to the wake word
            }
        }
    }

    /// End the realtime session (its own .closed event lands here too and finds live == nil) and go back to the wake word.
    private func closeLive(_ reason: String) {
        liveIdle?.invalidate(); liveIdle = nil
        guard let l = live else { return }
        live = nil
        l.close(reason)
        print("Live: closed · \(reason)")
        state.listening = false; NSSound(named: "Bottle")?.play()
        phase(nil)
        if state.voiceOn { setVoice(true) }
    }

    /// Called on main (the timer needs its run loop): from onEvent, openLive, and the tool's defer via DispatchQueue.main.
    private func armLiveIdle() {
        liveIdle?.invalidate()
        guard !liveBusy else { return }                              // an event during a tool (the user talks over the wait) must not start the clock
        liveIdle = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.closeLive("조용해서 닫음") } }
    }

    private func log(_ role: String, _ text: String) {
        _ = try? db.exec("INSERT INTO chat_log(ts,role,text) VALUES(?,?,?)", [TS.string(Date()), role, text])
    }

    /// Set the phase; nil = the turn is over: .agent/.humanTurn back to .idle (a human holding the phone keeps its state).
    nonisolated private func phase(_ p: Phase?) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            let s = self.state
            if let p { s.phase = p } else if case .agent = s.phase { s.phase = .idle } else if case .humanTurn = s.phase { s.phase = .idle }
        } }
    }
}
