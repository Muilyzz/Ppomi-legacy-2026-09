import Darwin
import Foundation

/// Coordinates Ppomi's screen tools and records focus across the app and MCP processes.
/// Each call owns an independent file descriptor: closing one call never releases another's lock.
/// This observes only Ppomi tools, not automation from other applications or agents.
final class ScreenControlLease: @unchecked Sendable {
    enum Failure: LocalizedError {
        case io(operation: String, code: Int32)
        case invalidLockFile

        var errorDescription: String? {
            switch self {
            case .io(let operation, let code):
                return "화면 제어 잠금 \(operation) 실패: \(String(cString: strerror(code)))"
            case .invalidLockFile:
                return "화면 제어 잠금 파일을 확인할 수 없습니다."
            }
        }
    }

    static let blockedMessage = "실행 안 함: 기록 집중 모드에서는 뽀미의 화면 제어·캡처가 일시정지됩니다. ‘작업으로 돌아가기’를 누른 뒤 다시 요청해 주세요."

    private static let visibleSurfacePrefixes = ["phone_", "windows_", "android_"]
    private static let visibleSurfaceTools: Set<String> = [
        "run_combo", "path_cold_start", "inbody_capture", "collect_now", "screen_inspect", "profile_fill", "browser_open"
    ]
    // android_status asks the bridge for connection status without capturing or navigating UI.
    private static let surfaceIndependentTools: Set<String> = ["android_status"]

    static func requiresVisibleSurface(tool: String) -> Bool {
        if surfaceIndependentTools.contains(tool) { return false }
        return visibleSurfaceTools.contains(tool) || visibleSurfacePrefixes.contains { tool.hasPrefix($0) }
    }

    /// This sidecar has no persisted focus flag. Keep its inode in place; the kernel drops locks on exit.
    /// The ledger's parent directory must already exist. Never create or chmod a user-selected DB folder.
    static func path(for ledgerPath: String) -> String {
        let file = URL(fileURLWithPath: (ledgerPath as NSString).expandingTildeInPath).standardizedFileURL
        // Foundation may leave every symlink unresolved when the final file does not yet exist.
        // Resolve the existing parent first so a new ledger has the same lock through a folder alias.
        let canonical = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).resolvingSymlinksInPath()
        return canonical.path + ".screen-control.lock"
    }

    /// A shared lease must be held for the complete tool invocation, including screen capture.
    /// nil means records focus currently owns the exclusive lease; I/O errors must fail closed.
    static func beginControl(ledgerPath: String) throws -> ScreenControlLease? {
        try acquire(ledgerPath: ledgerPath, operation: LOCK_SH)
    }

    /// Native mirroring recovery has one writer across app and MCP processes. This separate namespace
    /// complements (and does not replace) the caller's shared screen-control lease against records focus.
    static func beginMirroringRecovery(ledgerPath: String) throws -> ScreenControlLease? {
        try acquire(ledgerPath: ledgerPath, operation: LOCK_EX, suffix: ".mirroring-recovery")
    }

    /// Acquire before hiding any control window and release only after its restoration finishes.
    /// nil means a Ppomi screen invocation or another focused window is already active.
    static func beginFocus(ledgerPath: String) throws -> ScreenControlLease? {
        try acquire(ledgerPath: ledgerPath, operation: LOCK_EX)
    }

    private let mutex = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        let ownedDescriptor = descriptor
        descriptor = -1
        // close releases this open-file-description's lock. Do not retry close after EINTR:
        // another thread may have reused its number, and a retry could close that unrelated file.
        Darwin.close(ownedDescriptor)
    }

    deinit { release() }

    private static func acquire(ledgerPath: String, operation: Int32, suffix: String = "") throws -> ScreenControlLease? {
        let descriptor = Darwin.open(path(for: ledgerPath) + suffix, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.io(operation: "열기", code: errno) }
        var retained = false
        defer { if !retained { Darwin.close(descriptor) } }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw Failure.io(operation: "확인", code: errno) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1 else { throw Failure.invalidLockFile }

        // EINTR is not contention. Retry only the lock operation, never the descriptor's close.
        while flock(descriptor, operation | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw Failure.io(operation: "획득", code: code)
        }
        retained = true
        return ScreenControlLease(descriptor: descriptor)
    }
}
