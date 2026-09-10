// The ear: microphone → SpeechAnalyzer (on-device ko-KR). "뽀미야" opens a conversation: from then on every utterance is a
// turn (no wake word needed) until a stop word (그만·끝·됐어…) or 25 s of silence closes it.
// start() asks for the two permissions, installs the ko-KR asset if the system says so, taps the input node and streams
// converted buffers into the analyzer. The class lives on the main actor: every wait in start() is an await (nothing
// blocks main), the results loop and the timers are main tasks, so the callbacks are main too.
import AVFoundation
import Speech

@available(macOS 26, *)
@MainActor
final class Voice {
    enum Status: Equatable { case off, waiting, listening, denied(String) }   // waiting = 깨우기 말 대기, listening = 대화 중(세션)
    static let stopWords = ["그만", "끝", "됐어", "잘 가", "잘가", "그만해", "끝내", "안녕히", "이제 됐어"]
    static let idleSeconds = 25.0
    var onStatus: (@MainActor (Status) -> Void)?
    var onCommand: (@MainActor (String) -> Void)?   // "뽀미야" 뒤의 문장, 말이 끝나면 한 번
    func start() async throws {
        stop()
        let g = gen
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw deny("마이크 권한 없음") }
        // No SFSpeechRecognizer.requestAuthorization: SpeechAnalyzer is on-device and needs only the microphone, and TCC kills a
        // bundle-less binary that asks for speech recognition (the embedded Info.plist is not enough for that service).

        let transcriber = SpeechTranscriber(locale: Locale(identifier: "ko-KR"), preset: .progressiveTranscription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await req.downloadAndInstall() }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard gen == g else { throw CancellationError() }      // stop() came while we waited (prompt, download): nobody wants this engine
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // The Korean model has no "뽀미": unboosted it hears 품이야 / 이야 / 미야. Contextual strings tilt it toward the name.
        let ctx = AnalysisContext()
        ctx.contextualStrings = [AnalysisContext.ContextualStringsTag("wake"): ["뽀미야", "뽀미", "뽀미야 안녕"]]
        try await analyzer.setContext(ctx)
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if ProcessInfo.processInfo.environment["PPOMI_AEC"] != nil { try? node.setVoiceProcessingEnabled(true) }   // off by default: with it on and no output node this engine heard nothing (2026-09-04); TTS is muted instead              // echo cancellation: the Mac's own speaker (TTS) is subtracted from the mic
        let inFormat = node.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw deny("입력 장치 없음") }
        let outFormat = best ?? inFormat
        let converter = inFormat == outFormat ? nil : AVAudioConverter(from: inFormat, to: outFormat)

        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        node.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            guard let converter else { cont.yield(AnalyzerInput(buffer: buffer)); return }
            let frames = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / inFormat.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) else { return }
            var given = false
            var err: NSError?
            let st = converter.convert(to: out, error: &err) { _, status in
                status.pointee = given ? .noDataNow : .haveData
                defer { given = true }
                return given ? nil : buffer
            }
            if st != .error, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
        self.engine = engine; self.analyzer = analyzer; self.input = cont
        results = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self, self.gen == g, !Task.isCancelled else { break }
                    self.handle(String(r.text.characters), final: r.isFinal)
                }
            }
            catch { /* Recognition text and errors must not become durable conversation logs. */ }
        }
        try await analyzer.start(inputSequence: stream)
        guard gen == g else { throw CancellationError() }      // stop() ran during the analyzer start and already tore this down
        engine.prepare()
        try engine.start()
        print("Voice: listening on \(engine.inputNode.inputFormat(forBus: 0).sampleRate) Hz")
        set(.waiting)
    }

    func stop() {
        gen += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        results?.cancel(); silence?.cancel(); cap?.cancel(); idle?.cancel()
        engine = nil; analyzer = nil; input = nil; results = nil; silence = nil; cap = nil; idle = nil
        finals = ""; volatile = ""; command = ""
        if status != .off { set(.off) }
    }

    struct Denied: LocalizedError { let errorDescription: String? }

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var silence: Task<Void, Never>?     // 1.2 s after the last result, if it was a final and there is a command → command ends
    private var cap: Task<Void, Never>?         // 12 s after an utterance starts → it ends regardless
    private var idle: Task<Void, Never>?        // 25 s with nothing said (after 뽀미's answer too) → the conversation closes
    private var gen = 0                         // bumped by stop(): a start() still waiting on a prompt or a download gives up
    // Transcript state. finals = final texts since the last reset, volatile = the analyzer's current guess (empty right after a final).
    private var status: Status = .off
    private var finals = ""
    private var volatile = ""
    private var command = ""

    private func deny(_ why: String) -> Error { set(.denied(why)); return Denied(errorDescription: why) }
    func set(_ s: Status) { status = s; onStatus?(s) }          // internal: VoiceTests arms .waiting without a microphone

    // MARK: transcript

    /// One analyzer result. Internal so the state machine can be driven without a microphone (VoiceTests).
    var muted = false                                        // while 뽀미 speaks: its own voice must not wake it
    func handle(_ text: String, final: Bool) {
        if muted { finals = ""; volatile = ""; return }
        if final { finals += (finals.isEmpty ? "" : " ") + text; volatile = "" } else { volatile = text }
        let t = finals + (volatile.isEmpty ? "" : " " + volatile)
        switch status {
        case .waiting:
            guard let c = WakeWord.command(in: t) else { if final { finals = "" }; return }   // only the text since the last final
            command = c
            set(.listening)                                  // the conversation opens and stays open across utterances
            armCap(); armIdle()
        case .listening:
            command = WakeWord.command(in: t) ?? t.trimmingCharacters(in: .whitespacesAndNewlines)   // a final may re-spell the wake word
            if cap == nil { armCap() }
            armIdle()
        default: return
        }
        // "뽀미야 … 오늘 지출 얼마야": the command ends 1.2 s after its final; "뽀미야" alone keeps listening (until the cap).
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.volatile.isEmpty, !self.command.isEmpty else { return }
            self.finish()
        }
    }

    /// One utterance ended: a stop word closes the conversation, anything else is a turn; the conversation stays open.
    private func finish() {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        silence?.cancel(); cap?.cancel(); silence = nil; cap = nil
        finals = ""; volatile = ""; command = ""
        let stop = Self.stopWords.contains { c == $0 || (c.hasPrefix($0) && c.count <= $0.count + 2) }
        if stop { close(); return }
        if !c.isEmpty { onCommand?(c) }
        armIdle()
    }
    private func close() { idle?.cancel(); idle = nil; set(.waiting) }
    private func armCap() {
        cap?.cancel()
        cap = Task { [weak self] in try? await Task.sleep(for: .seconds(12)); if !Task.isCancelled { self?.finish() } }
    }
    private func armIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled, let self, self.status == .listening else { return }
            self.close()
        }
    }
    /// 뽀미 finished answering: the silence clock starts now, not while it was talking.
    func replied() { if status == .listening { armIdle() } }
}

enum WakeWord {
    static let words = ["뽀미야", "뽀미", "보미야", "보미", "포미야", "포미", "품이야", "뽐이야", "뽀미아"]   // what the ko model makes of the name
    /// 전사 문자열에서 깨우기 말을 찾아 그 뒤의 명령을 돌려준다. 깨우기 말이 없으면 nil, 있는데 뒤가 아직 비었으면 "".
    /// 공백·쉼표는 매칭에서 무시하고("뽀미 야", "뽀미야,"), 명령 앞의 쉼표·마침표·물음표는 떼어낸다.
    static func command(in transcript: String) -> String? {
        let skip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))
        var norm: [Character] = [], idx: [String.Index] = []           // normalized characters and where each came from
        for i in transcript.indices where !transcript[i].unicodeScalars.allSatisfy(skip.contains) { norm.append(transcript[i]); idx.append(i) }
        var best: (at: Int, len: Int)?
        for w in words {
            let cs = Array(w)
            guard norm.count >= cs.count else { continue }
            for at in 0...(norm.count - cs.count) where Array(norm[at..<at + cs.count]) == cs {
                if best == nil || at < best!.at { best = (at, cs.count) }
                break
            }
        }
        guard let b = best else { return loose(transcript) }
        let end = b.at + b.len
        let tail = end < idx.count ? String(transcript[idx[end]...]) : ""
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，.。!?！？"))
        return tail.trimmingCharacters(in: lead)
    }

    /// What the ko model actually makes of a spoken "뽀미야" at the start of an utterance: 이야 / 폼이야 / 미야 / 품이야 …
    /// Accepted only at the very start and only when a word boundary follows (so "이야기 좀 하자" is not a wake).
    private static let start = Re(#"^[\s,，.]*(?:[뽀보포품폼뽐]\s?)?[미이]\s?[야아](?:[\s,，.!?！？]+|$)"#)
    private static func loose(_ transcript: String) -> String? {
        guard let m = start.search(transcript), let hit = m[0] else { return nil }
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，.。!?！？"))
        return String(transcript.dropFirst(hit.count)).trimmingCharacters(in: lead)
    }
}
