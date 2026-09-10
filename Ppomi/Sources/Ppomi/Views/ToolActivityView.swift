import Foundation

/// Pure presentation keeps call boundaries and never infers business progress from a tool event.
struct ToolActivityPresentation {
    struct Call: Identifiable {
        let id: UUID
        let events: [RuntimeEvent]
        let last: RuntimeEvent
        let isStale: Bool
        let order: Int

        var isActive: Bool { !last.kind.isTerminal && last.kind != .handedOff && !isStale }

        var status: String {
            switch last.kind {
            case .returned: return "결과 반환"
            case .handedOff: return last.method == .human ? "사용자에게 넘김 · 이후 미확인" : "에이전트에 반환 · 이후 미확인"
            default: return isStale ? "갱신 없음 · 상태 미확인" : last.title
            }
        }
    }

    let calls: [Call]
    let unavailable: Bool

    init(events: [RuntimeEvent], unavailable: Bool, now: Date) {
        self.unavailable = unavailable
        // The collector supplies insertion order. Equal timestamps and clock changes must not reorder a call.
        let groups = Dictionary(grouping: events.enumerated(), by: { $0.element.callID })
        calls = groups.compactMap { id, entries -> Call? in
            guard let latest = entries.last(where: { $0.element.kind.isTerminal }) ?? entries.last else { return nil }
            let last = latest.element
            let age = now.timeIntervalSince(last.timestamp)
            return Call(id: id, events: entries.map(\.element), last: last,
                        isStale: !last.kind.isTerminal && (age > 30 || age < 0), order: latest.offset)
        }.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.order > $1.order
        }
    }

    var summary: String? {
        if unavailable { return "도구 상태 확인 불가" }
        guard let call = calls.first else { return nil }
        let method = call.last.method == .tool ? nil : call.last.method.title
        return [call.last.toolTitle, method, call.status].compactMap { $0 }.joined(separator: " · ")
    }

    func text(priority: String? = nil, fallback: String) -> String {
        priority ?? summary ?? fallback
    }

    static func title(for event: RuntimeEvent) -> String {
        event.kind == .returned ? "결과 반환" : event.title
    }

    static func replayLabel(for event: RuntimeEvent) -> String? {
        guard event.method == .replay, let step = event.step, step > 0 else { return nil }
        return "재생 동작 \(step)"
    }
}
