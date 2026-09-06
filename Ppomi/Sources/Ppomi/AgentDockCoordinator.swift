import AppKit

/// AX writes happen only during a bounded, explicitly requested layout. Idle polling never raises or snaps a window.
@MainActor
final class AgentDockCoordinator {
    private let state: AppState
    private var app: AgentApp
    private var original: (id: CGWindowID, frame: CGRect, isMinimized: Bool)?
    private var lastRequest = -1
    private var pending = false
    private var revealRequested = false
    private var launched = false
    private var revealed = false
    private var resized = false
    private var placed = false
    private var deadline: TimeInterval = 0
    private var settleUntil: TimeInterval = 0
    private var slot: CGRect?
    private var attachedID: CGWindowID?

    init(state: AppState) { self.state = state; app = state.agentApp }

    func syncSelection() {
        guard lastRequest != state.agentLayoutRequest || app != state.agentApp else { return }
        if app != state.agentApp { restore(); app = state.agentApp }
        lastRequest = state.agentLayoutRequest
        if state.agentVisible { requestLayout() }
        else {
            pending = false; attachedID = nil
            minimizeManagedWindow()
        }
    }

    func requestLayout(reveal: Bool = true) {
        guard state.agentVisible else { return }
        pending = true; revealRequested = reveal
        launched = false; revealed = false; resized = false; placed = false
        attachedID = nil; settleUntil = 0
        deadline = ProcessInfo.processInfo.systemUptime + 4
    }

    func restore() {
        if let original, app.windowState()?.id == original.id {
            _ = app.resize(original.frame.size)
            app.place(original.frame.origin)
            _ = app.setMinimized(original.isMinimized)
        }
        original = nil; attachedID = nil; pending = false; slot = nil
    }

    /// `available` is in WindowServer coordinates and excludes the Ppomi toolbar and approval controls.
    func update(available: CGRect, allowing: Set<pid_t>) -> (id: CGWindowID, rect: CGRect)? {
        guard state.agentVisible else { return nil }
        guard Permissions.accessibility else {
            message("대화창을 붙이려면 설정 › 시작하기에서 손쉬운 사용을 허용해 주세요")
            return nil
        }
        guard app.isInstalled else { message("\(app.displayName) 앱을 찾지 못했습니다"); return nil }
        // A real layout change (display, target size or approval height) permits one new size request.
        if let slot, !DockChange.near(slot, available) { requestLayout(reveal: false) }
        slot = available
        let now = ProcessInfo.processInfo.systemUptime
        if pending {
            guard AgentDockLayout.accepts(actualSize: app.minimumSize, in: available) else {
                failFit(); return nil
            }
            if !app.isRunning, !launched {
                app.launch(); launched = true
            }
            if original == nil { original = app.windowState() }
            if revealRequested, !revealed, app.isRunning {
                _ = app.revealWindow(allowing: allowing); revealed = true
            }
            guard let window = app.windowState() else {
                if now >= deadline { pending = false }
                message("\(app.displayName)에서 대화창을 연 뒤 ‘대화창 다시 배치’를 눌러 주세요")
                return nil
            }
            if let original, original.id != window.id {
                guard revealRequested else {
                    pending = false; attachedID = nil
                    message("대화창이 바뀌었습니다. ‘대화창 다시 배치’로 새 창을 선택해 주세요.")
                    return nil
                }
                self.original = window
            } else if original == nil { original = window }
            if !resized {
                _ = app.setMinimized(false)
                _ = app.resize(available.size)
                resized = true; settleUntil = now + 0.3
                return nil
            }
            guard now >= settleUntil else { return nil }
            guard AgentDockLayout.accepts(actualSize: window.frame.size, in: available) else {
                failFit(); return nil
            }
            if !placed {
                // WindowServer uses top-left coordinates, unlike the pure AppKit layout helper.
                let origin = CGPoint(x: available.midX - window.frame.width / 2, y: available.minY)
                app.place(origin); placed = true; settleUntil = now + 0.3
                return nil
            }
            guard let live = app.liveWindow(), available.insetBy(dx: -2, dy: -2).contains(live.rect) else {
                if now >= deadline { failFit() }
                return nil
            }
            pending = false; attachedID = live.id
            message("")
        }
        guard let id = attachedID, let live = app.liveWindow(), live.id == id,
              available.insetBy(dx: -2, dy: -2).contains(live.rect) else {
            if attachedID != nil { message("대화창 위치가 바뀌었습니다. ‘대화창 다시 배치’로 돌아올 수 있습니다.") }
            return nil
        }
        return live
    }

    private func failFit() {
        pending = false; attachedID = nil
        // Do not let a native minimum size overlap human approval controls.
        minimizeManagedWindow()
        message("대화창과 작업 화면을 나란히 놓을 공간이 부족합니다. 작업 화면 크기를 줄인 뒤 ‘대화창 다시 배치’를 눌러 주세요. 기록은 위 버튼으로 볼 수 있습니다.")
    }
    private func message(_ text: String) {
        if state.agentDockMessage != text { state.agentDockMessage = text }
    }
    private func minimizeManagedWindow() {
        guard let original, let current = app.windowState(), current.id == original.id, !current.isMinimized else { return }
        _ = app.setMinimized(true)
    }
}
