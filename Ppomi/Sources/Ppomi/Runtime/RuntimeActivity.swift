import Combine
import Foundation

/// The workbench's read-only runtime subscription. It does not infer what an external agent is doing.
@MainActor
final class RuntimeActivity: ObservableObject {
    @Published private(set) var events: [RuntimeEvent]
    @Published private(set) var unavailable: Bool
    private var monitor: RuntimeEventMonitor?
    private var ledgerPath: String?

    init(events: [RuntimeEvent] = [], unavailable: Bool = false) {
        self.events = events
        self.unavailable = unavailable
    }

    func start(ledgerPath: String) {
        let path = URL(fileURLWithPath: (ledgerPath as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard self.ledgerPath != path else { return }
        stop()
        self.ledgerPath = path
        let monitor = RuntimeEventMonitor(onUpdate: { [weak self] events in
            guard let self, self.events != events else { return }
            self.events = events
        }, onError: { [weak self] unavailable in
            guard let self, self.unavailable != unavailable else { return }
            self.unavailable = unavailable
        })
        self.monitor = monitor
        monitor.start(ledgerPath: path)
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        ledgerPath = nil
        if !events.isEmpty { events = [] }
        if unavailable { unavailable = false }
    }
}
