import AppKit
import ApplicationServices

/// A reversible lease on selected native windows. It never hides an application or chooses a replacement window.
@MainActor
final class RecordsWindowParking {
    struct Target: Equatable {
        let pid: pid_t
        let id: CGWindowID
        /// WindowServer/AX coordinates, with the origin at the top of the primary display.
        let frame: CGRect
    }

    struct Snapshot {
        let frame: CGRect
        let isMinimized: Bool
    }

    /// Closures retain the captured native handle; tests can substitute independent window handles.
    struct Handle {
        /// False means closed/replaced; nil means the original handle cannot currently be verified.
        let isAlive: () -> Bool?
        let read: () -> Snapshot?
        let canMinimize: () -> Bool
        let setMinimized: (Bool) -> Bool
        let setFrame: (CGRect) -> Bool
    }

    enum Failure: LocalizedError {
        case invalidTarget, duplicateTarget, unavailable(CGWindowID), unsupported(CGWindowID)
        case changed(CGWindowID), minimizationFailed(CGWindowID), pendingRestore

        var errorDescription: String? {
            switch self {
            case .invalidTarget: "접을 창의 식별 정보나 위치가 올바르지 않습니다."
            case .duplicateTarget: "같은 창이 중복 선택되어 기록 집중 모드로 전환하지 않았습니다."
            case .unavailable(let id): "선택한 창(\(id))을 정확히 확인할 수 없습니다."
            case .unsupported(let id): "선택한 창(\(id))은 개별 최소화를 지원하지 않습니다."
            case .changed(let id): "선택한 창(\(id))의 상태가 바뀌어 기록 집중 모드로 전환하지 않았습니다."
            case .minimizationFailed(let id): "선택한 창(\(id))을 접지 못했습니다."
            case .pendingRestore: "앞서 접은 창의 복원을 먼저 완료해야 합니다."
            }
        }
    }

    private struct Entry {
        let target: Target
        let handle: Handle
        let original: Snapshot
    }

    private let entries: [Entry]
    private var awaitingRestore = Set<Int>()
    /// A failed geometry write after our own reveal is distinct from a user's reveal or subsequent move.
    private var geometryRetryFrames: [Int: CGRect] = [:]
    private var didPark = false

    convenience init(targets: [Target]) throws {
        try self.init(targets: targets, capture: Self.captureNative)
    }

    /// Capturing and preflighting every target is read-only, even if a later target fails.
    init(targets: [Target], capture: (Target) throws -> Handle) throws {
        var seen = Set<String>()
        var captured: [Entry] = []
        for target in targets {
            guard target.pid > 0, target.id != kCGNullWindowID, Self.usableFrame(target.frame) else { throw Failure.invalidTarget }
            guard seen.insert("\(target.pid):\(target.id)").inserted else { throw Failure.duplicateTarget }
            let handle = try capture(target)
            guard handle.isAlive() == true, let snapshot = handle.read(), Self.usableFrame(snapshot.frame) else {
                throw Failure.unavailable(target.id)
            }
            guard handle.canMinimize() else { throw Failure.unsupported(target.id) }
            guard Self.framesMatch(snapshot.frame, target.frame) else { throw Failure.changed(target.id) }
            captured.append(Entry(target: target, handle: handle, original: snapshot))
        }
        entries = captured
    }

    func park() throws {
        if didPark { return }
        guard awaitingRestore.isEmpty else { throw Failure.pendingRestore }
        // Revalidate the entire set before mutating its first member.
        for entry in entries { try Self.preflight(entry) }
        do {
            for (index, entry) in entries.enumerated() where !entry.original.isMinimized {
                try Self.preflight(entry)
                // Retain even a failed write: an AX failure can follow a partial native state change.
                awaitingRestore.insert(index)
                guard entry.handle.setMinimized(true), entry.handle.read()?.isMinimized == true else {
                    throw Failure.minimizationFailed(entry.target.id)
                }
            }
            didPark = true
        } catch {
            _ = restoreSavedWindows(rollback: true)
            throw error
        }
    }

    /// A user's explicit reveal exits focus through the controller; their new position belongs to them.
    var wasRevealedExternally: Bool {
        awaitingRestore.contains { index in
            let handle = entries[index].handle
            guard handle.isAlive() == true, let current = handle.read(), !current.isMinimized else { return false }
            return geometryRetryFrames[index].map { !Self.framesMatch(current.frame, $0) } ?? true
        }
    }

    /// Closed windows are skipped. Live handles that failed to restore remain available for a retry.
    @discardableResult func restore() -> Bool { restoreSavedWindows(rollback: false) }

    private func restoreSavedWindows(rollback: Bool) -> Bool {
        var succeeded = true
        for index in awaitingRestore.sorted().reversed() {
            let entry = entries[index], handle = entry.handle
            guard let alive = handle.isAlive() else { succeeded = false; continue }
            guard alive else { finishRestoring(index); continue }
            guard let current = handle.read() else { succeeded = false; continue }
            if !current.isMinimized {
                if let expected = geometryRetryFrames[index], Self.framesMatch(current.frame, expected) {
                    if restoreGeometry(index, observed: current) { finishRestoring(index) }
                    else { succeeded = false }
                    continue
                }
                // Cancel a possibly delayed failed minimization during rollback, without moving the visible window.
                if rollback && !handle.setMinimized(false) { succeeded = false; continue }
                finishRestoring(index)
                continue
            }
            guard handle.setMinimized(false), let revealed = handle.read(), !revealed.isMinimized else {
                succeeded = false
                continue
            }
            if restoreGeometry(index, observed: revealed) { finishRestoring(index) }
            else { succeeded = false }
        }
        return succeeded
    }

    private func finishRestoring(_ index: Int) {
        awaitingRestore.remove(index)
        geometryRetryFrames.removeValue(forKey: index)
    }

    private func restoreGeometry(_ index: Int, observed: Snapshot) -> Bool {
        let entry = entries[index], handle = entry.handle
        if Self.framesMatch(observed.frame, entry.original.frame) { return true }
        let written = handle.setFrame(entry.original.frame)
        let after = handle.read()
        if written, after.map({ !$0.isMinimized && Self.framesMatch($0.frame, entry.original.frame) }) == true { return true }
        geometryRetryFrames[index] = after?.frame ?? observed.frame
        return false
    }

    private static func preflight(_ entry: Entry) throws {
        guard entry.handle.isAlive() == true, let current = entry.handle.read() else { throw Failure.unavailable(entry.target.id) }
        guard entry.handle.canMinimize() else { throw Failure.unsupported(entry.target.id) }
        guard current.isMinimized == entry.original.isMinimized, framesMatch(current.frame, entry.original.frame) else {
            throw Failure.changed(entry.target.id)
        }
    }

    private static func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    private static func framesMatch(_ left: CGRect, _ right: CGRect) -> Bool {
        usableFrame(left) && usableFrame(right) &&
            abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
            abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: point, size: dimensions)
        return usableFrame(frame) ? frame : nil
    }

    private static func windows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    }

    private static func frame(of window: [String: Any]) -> CGRect? {
        guard let value = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = value["X"], let y = value["Y"], let width = value["Width"], let height = value["Height"] else { return nil }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return usableFrame(frame) ? frame : nil
    }

    private static func canSet(_ name: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func captureNative(_ target: Target) throws -> Handle {
        guard AXIsProcessTrusted(), let cg = windows() else { throw Failure.unavailable(target.id) }
        let matchingID = cg.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid &&
                ($0[kCGWindowNumber as String] as? CGWindowID) == target.id
        }
        guard matchingID.count == 1, let matched = matchingID.first,
              (matched[kCGWindowLayer as String] as? Int) == 0,
              let cgFrame = frame(of: matched), framesMatch(cgFrame, target.frame) else { throw Failure.unavailable(target.id) }
        let application = AXUIElementCreateApplication(target.pid)
        guard let axWindows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { throw Failure.unavailable(target.id) }
        let matchingAX = axWindows.filter {
            attribute($0, kAXRoleAttribute) as? String == kAXWindowRole &&
                frame(of: $0).map { framesMatch($0, cgFrame) } == true
        }
        // Public AX does not expose a CGWindowID. Require an unambiguous match in both lists, then retain that element.
        let matchingFrames = cg.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid &&
                ($0[kCGWindowLayer as String] as? Int) == 0 && frame(of: $0).map { framesMatch($0, cgFrame) } == true
        }
        guard matchingAX.count == 1, matchingFrames.count == 1, let element = matchingAX.first else { throw Failure.unavailable(target.id) }

        let isAlive: () -> Bool? = {
            guard let currentCG = windows() else { return nil }
            var pid: pid_t = 0
            let pidResult = AXUIElementGetPid(element, &pid)
            if pidResult == .invalidUIElement { return false }
            guard pidResult == .success else { return nil }
            guard pid == target.pid else { return false }
            guard let currentAX = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
            guard currentAX.contains(where: { CFEqual($0, element) }) else { return false }
            // Minimized windows normally remain in optionAll. A temporarily absent CG row does not
            // invalidate the exact retained AX handle; treating it as closed could strand that window.
            let matchingID = currentCG.filter { ($0[kCGWindowNumber as String] as? CGWindowID) == target.id }
            guard matchingID.allSatisfy({ ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid }) else { return nil }
            return true
        }
        return Handle(isAlive: isAlive, read: {
            guard isAlive() == true, let currentFrame = frame(of: element),
                  let minimized = attribute(element, kAXMinimizedAttribute) as? Bool else { return nil }
            return Snapshot(frame: currentFrame, isMinimized: minimized)
        }, canMinimize: { isAlive() == true && canSet(kAXMinimizedAttribute, on: element) }, setMinimized: { minimized in
            guard isAlive() == true, canSet(kAXMinimizedAttribute, on: element) else { return false }
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
        }, setFrame: { desired in
            guard isAlive() == true, usableFrame(desired), let current = frame(of: element) else { return false }
            if current.size != desired.size {
                guard canSet(kAXSizeAttribute, on: element) else { return false }
                var size = desired.size
                guard let value = AXValueCreate(.cgSize, &size),
                      AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success else { return false }
            }
            if frame(of: element)?.origin != desired.origin {
                guard isAlive() == true, canSet(kAXPositionAttribute, on: element) else { return false }
                var position = desired.origin
                guard let value = AXValueCreate(.cgPoint, &position),
                      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success else { return false }
            }
            return true
        })
    }
}
