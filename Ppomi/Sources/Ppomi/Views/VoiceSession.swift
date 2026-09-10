// App-long native wake/shortcut host for the shared, ephemeral voice agent. No conversation is stored here.
import AppKit
import Combine
import Foundation

@MainActor
protocol AgentConversationWindow: AnyObject {
    var onActive: ((Bool) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isVisible: Bool { get }
    func present()
    func close()
}

/// A workbench area that shows the conversation in place of a floating window (the sidebar's agent area).
@MainActor
protocol ConversationHost: AnyObject {
    func mount(conversation: NSView)
    func unmount(conversation: NSView)
    /// Bring the window that holds the conversation on screen.
    func revealConversation()
}

@MainActor
final class VoiceSession {
    let state: AppState
    private var subs: [AnyCancellable] = []
    private var keyMonitors: [Any] = []
    private var voice: Voice?
    private var wakeGeneration = UUID()
    private var lastArrival: Date?
    private let panel: any AgentConversationWindow

    init(state: AppState, dbPath: String = AppSettings.dbPath,
         panel: (any AgentConversationWindow)? = nil, monitorKeys: Bool = true) throws {
        let panel = panel ?? AgentVoicePanel()
        self.state = state; self.panel = panel
        panel.onActive = { [weak self] active in
            guard let self else { return }
            if active { self.stopWake() }
            self.state.listening = active
            self.clearTransientState()
        }
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.state.listening = false
            self.clearTransientState()
            if self.state.voiceOn { self.setVoice(true) }
        }
        subs = [state.$voiceOn.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in self?.setVoice(on) },
                state.$mirror.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] m in if m == .connected { self?.arrived() } },
                state.$voiceToggle.dropFirst().sink { [weak self] _ in self?.toggleLive() },
                state.$chatOpen.dropFirst().sink { [weak self] _ in self?.toggleLive(open: true) },
                state.$voiceOpen.dropFirst().sink { [weak self] _ in self?.toggleLive(open: true) }]
        if monitorKeys { keyMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isTalkChord(event) { MainActor.assumeIsolated { self?.toggleLive() } }
        }, NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isTalkChord(event) else { return event }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.toggleLive() } }; return nil
        }].compactMap { $0 } }
    }

    nonisolated static func isTalkChord(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option
    }

    /// Every entry reuses the same conversation host. Opening it never starts microphone capture.
    func toggleLive(open: Bool = false) {
        if panel.isVisible, !open { panel.close(); return }
        stopWake(); clearTransientState(); panel.present()
    }

    private func arrived() {
        guard state.greetOnArrival, !panel.isVisible, state.mirror == .connected else { return }
        if case .agent = state.phase { return }
        guard Arrival.shouldGreet(now: Date(), lastGreet: lastArrival, idleSeconds: Arrival.idleSeconds(),
                                  screenLocked: Arrival.screenLocked(), muted: Arrival.muted()) else { return }
        // Arrival can reveal the voice surface, but never silently starts cloud audio capture.
        lastArrival = Date()
        toggleLive(open: true)
    }

    func setVoice(_ on: Bool) {
        stopWake()
        // The wake listener is independent of the open text/voice conversation.
        guard on else { return }
        guard !panel.isVisible else { return }
        let listener = Voice(), generation = wakeGeneration
        listener.onStatus = { [weak self, weak listener] status in
            guard let self, let listener, self.voice === listener, self.wakeGeneration == generation else { return }
            if status == .listening { self.toggleLive(open: true) }
        }
        // Wake transcription stays inside Voice and is discarded; no transcript reaches captions, SQL, or logs.
        voice = listener
        Task { [weak self, weak listener] in
            guard let listener else { return }
            do { try await listener.start() }
            catch is CancellationError {}
            catch {
                guard let self, self.voice === listener, self.wakeGeneration == generation else { return }
                self.state.voiceOn = false
                Notify.post("음성", "마이크 권한과 음성 인식 준비 상태를 확인해 주세요.")
            }
        }
    }

    private func stopWake() {
        wakeGeneration = UUID()
        voice?.onStatus = nil; voice?.onCommand = nil; voice?.stop(); voice = nil
    }

    private func clearTransientState() {
    }
}
