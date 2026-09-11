import AppKit
import ApplicationServices
import Foundation

/// Mac Accessibility backend for `screen_read` / `ui_tap` / `ui_type`.
/// Same node JSON as the Windows executor. Live AX stays behind this type; tests inject `fake`.
enum MacUI {
    static let chromeID = "com.google.Chrome"
    static let safariID = "com.apple.Safari"
    static let names: Set<String> = ["screen_read", "ui_tap", "ui_type"]
    static let snapshotTTL: TimeInterval = 15
    fileprivate static let nodeLimit = 500
    fileprivate static let depthLimit = 20
    fileprivate static let walkSeconds: TimeInterval = 5
    fileprivate static let textLimit = 1024

    /// In-memory stand-in. No Accessibility grant, no Chrome/Safari, no device approval.
    static var fake: Session?

    struct Bounds: Equatable {
        var left, top, right, bottom: Double
        var json: [String: Double] { ["left": left, "top": top, "right": right, "bottom": bottom] }
        var rect: CGRect { CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top)) }
        func contains(_ x: Double, _ y: Double) -> Bool { x >= left && x <= right && y >= top && y <= bottom }
    }

    struct Node: Equatable {
        var id: String
        var parentId: String?
        var text: String
        var role: String
        var clickable, editable, visible, enabled, password: Bool
        var bounds: Bounds
        var json: [String: Any] {
            ["id": id, "parentId": parentId as Any? ?? NSNull(), "text": text, "role": role,
             "clickable": clickable, "editable": editable, "visible": visible, "enabled": enabled,
             "password": password, "bounds": bounds.json]
        }
    }

    struct Snapshot: Equatable {
        var snapshotId, packageName, appLabel: String
        var nodes: [Node]
        var truncated: Bool
        var json: [String: Any] {
            ["snapshotId": snapshotId, "packageName": packageName, "appLabel": appLabel,
             "nodes": nodes.map(\.json), "truncated": truncated]
        }
    }

    struct ActionResult: Equatable {
        var invoked: Bool?
        var typed: Bool?
        var requiresScreenRead = true
        var json: [String: Any] {
            var out: [String: Any] = ["requiresScreenRead": requiresScreenRead]
            if let invoked { out["invoked"] = invoked }
            if let typed { out["typed"] = typed }
            return out
        }
    }

    /// `"오류: \(error)"` must print these strings, not the enum case names (`staleScreen`).
    enum Failure: LocalizedError, Equatable, CustomStringConvertible {
        case accessibility, appNotFound, staleScreen, protectedAction, invalidRequest(String)
        var description: String {
            switch self {
            case .accessibility:
                return "손쉬운 사용 권한이 필요합니다. 뽀미 설정 창(시작하기)에서 손쉬운 사용을 켜 주세요."
            case .appNotFound:
                return "app_not_found. 전면 또는 app=chrome|safari 인 Chrome/Safari만 읽는다."
            case .staleScreen:
                return "stale_screen. 방금 screen_read로 읽은 nodeId만 사용할 수 있다."
            case .protectedAction:
                return "protected_action. 비밀번호·결제 버튼은 당사자가 직접 처리한다."
            case .invalidRequest(let detail):
                return "invalid_request. \(detail)"
            }
        }
        var errorDescription: String? { description }
    }

    protocol Session: AnyObject {
        func read(app: String?) throws -> Snapshot
        func tap(nodeId: String?, x: Double?, y: Double?) throws -> ActionResult
        func type(nodeId: String?, text: String) throws -> ActionResult
    }

    static func json(_ value: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    static func browserBundle(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chrome", "google chrome", "com.google.chrome": return chromeID
        case "safari", "com.apple.safari": return safariID
        default: return nil
        }
    }

    static func parseRead(app: String?) throws -> String? {
        guard let raw = app?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.count <= 160, !raw.contains("\0") else { throw Failure.invalidRequest("app") }
        guard let bundle = browserBundle(raw) else { throw Failure.appNotFound }
        return bundle
    }

    static func parseTap(_ a: [String: Any]) throws -> (nodeId: String?, x: Double?, y: Double?) {
        let nodeId = try optionalString(a["nodeId"], key: "nodeId", max: 160)
        let x = try optionalPoint(a["x"], key: "x")
        let y = try optionalPoint(a["y"], key: "y")
        if nodeId != nil, x != nil || y != nil { throw Failure.invalidRequest("nodeId와 x,y를 함께 쓰지 않는다") }
        if nodeId == nil, x == nil, y == nil { throw Failure.invalidRequest("nodeId 또는 x,y가 필요하다") }
        if (x == nil) != (y == nil) { throw Failure.invalidRequest("x와 y를 함께 준다") }
        return (nodeId, x, y)
    }

    static func parseType(_ a: [String: Any]) throws -> (nodeId: String?, text: String) {
        guard let text = a["text"] as? String, text.count <= 4096,
              text.unicodeScalars.allSatisfy({ $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.protectedAction
        }
        return (try optionalString(a["nodeId"], key: "nodeId", max: 160), text)
    }

    private static func optionalString(_ value: Any?, key: String, max: Int) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String, text.count <= max, !text.contains("\0") else { throw Failure.invalidRequest(key) }
        return text.isEmpty ? nil : text
    }

    private static func optionalPoint(_ value: Any?, key: String) throws -> Double? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (-20_000...40_000).contains(number.doubleValue) else {
            throw Failure.invalidRequest(key)
        }
        return number.doubleValue
    }

    /// Stage Manager thumbnails are smaller than a real browser window.
    static let liveWindowMin: CGFloat = 200
    static let hidChunkSize = 16

    static func isPassword(role: String, subrole: String) -> Bool {
        role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
    }

    /// Chrome page links/buttons sit under `AXWebArea`. AXPress often no-ops there; click the AX frame center.
    static func clicksWebContent(role: String, rolesTowardRoot: [String]) -> Bool {
        role == "AXLink" || rolesTowardRoot.contains { $0 == "AXWebArea" }
    }

    static func hidUTF16Chunks(_ text: String, size: Int = hidChunkSize) -> [[UInt16]] {
        let units = Array(text.utf16)
        let step = max(1, size)
        guard !units.isEmpty else { return [] }
        var out: [[UInt16]] = []
        var index = 0
        while index < units.count {
            out.append(Array(units[index..<min(index + step, units.count)]))
            index += step
        }
        return out
    }
}

/// Process-local AX session. One snapshot; IDs die after tap/type or 15 seconds.
final class LiveMacUI: MacUI.Session {
    fileprivate struct Stored {
        let snapshot: MacUI.Snapshot
        let at: Date
        let pid: pid_t
        let windowElement: AXUIElement
        let elements: [String: AXUIElement]
    }

    private let lock = NSLock()
    fileprivate var stored: Stored?

    func read(app: String?) throws -> MacUI.Snapshot {
        let wanted = try MacUI.parseRead(app: app)
        guard AXIsProcessTrusted() else { throw MacUI.Failure.accessibility }
        let target = try Self.resolve(wanted)
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let window = Self.primaryWindow(in: application) else {
            throw MacUI.Failure.appNotFound
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let snapshotId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        var nodes: [MacUI.Node] = [], elements: [String: AXUIElement] = [:], truncated = false
        let deadline = Date().addingTimeInterval(MacUI.walkSeconds)
        var seen = 0
        func walk(_ element: AXUIElement, parent: String?, depth: Int) {
            if nodes.count >= MacUI.nodeLimit || seen > 1_000 || Date() > deadline { truncated = true; return }
            seen += 1
            if Self.attr(element, "AXHidden") as? Bool == true { return }
            let roleRaw = Self.attr(element, kAXRoleAttribute) as? String ?? ""
            let subrole = Self.attr(element, kAXSubroleAttribute) as? String ?? ""
            let password = MacUI.isPassword(role: roleRaw, subrole: subrole)
            let title = Self.limit(Self.attr(element, kAXTitleAttribute) as? String)
            let description = Self.limit(Self.attr(element, kAXDescriptionAttribute) as? String)
            var value = ""
            if !password { value = Self.limit(Self.stringValue(element)) }
            let enabled = Self.attr(element, kAXEnabledAttribute) as? Bool ?? true
            let rect = Self.frame(element) ?? .zero
            let actions = Self.actions(element)
            let press = actions.contains(kAXPressAction as String) || Self.clickableRole(roleRaw)
            var settable = DarwinBoolean(false)
            let canSet = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            let editable = !password && (canSet || Self.editableRole(roleRaw))
            let nodeId = "\(snapshotId):\(nodes.count)"
            let text: String
            if password { text = title.isEmpty ? "[protected]" : title + " [protected]" }
            else {
                let parts = [title, value, description].filter { !$0.isEmpty }
                text = Self.limit(parts.first == parts.dropFirst().first ? (parts.first ?? "") : parts.joined(separator: " "))
            }
            nodes.append(MacUI.Node(id: nodeId, parentId: parent, text: text, role: Self.shortRole(roleRaw),
                                    clickable: press && enabled && !password, editable: editable && enabled,
                                    visible: rect.width > 0 && rect.height > 0, enabled: enabled, password: password,
                                    bounds: MacUI.Bounds(left: rect.minX, top: rect.minY, right: rect.maxX, bottom: rect.maxY)))
            elements[nodeId] = element
            guard depth < MacUI.depthLimit, !password else { return }
            for child in (Self.attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                walk(child, parent: nodeId, depth: depth + 1)
                if truncated { return }
            }
        }
        walk(window, parent: nil, depth: 0)
        let snapshot = MacUI.Snapshot(snapshotId: String(snapshotId), packageName: target.bundle, appLabel: target.label,
                                      nodes: nodes, truncated: truncated)
        lock.lock()
        stored = Stored(snapshot: snapshot, at: Date(), pid: target.pid, windowElement: window, elements: elements)
        lock.unlock()
        return snapshot
    }

    func tap(nodeId: String?, x: Double?, y: Double?) throws -> MacUI.ActionResult {
        guard AXIsProcessTrusted() else { throw MacUI.Failure.accessibility }
        let current = try requireSnapshot()
        if let nodeId {
            guard let node = current.snapshot.nodes.first(where: { $0.id == nodeId }),
                  let element = current.elements[nodeId] else { throw MacUI.Failure.staleScreen }
            if node.password || Tools.isPayWord(node.text) || !node.enabled { throw MacUI.Failure.protectedAction }
            if !node.clickable { throw MacUI.Failure.protectedAction }
            let liveWindow = try raiseLive(current)
            guard let live = Self.frame(element), live.width >= 2, live.height >= 2 else { throw MacUI.Failure.staleScreen }
            let center = CGPoint(x: live.midX, y: live.midY)
            guard liveWindow.insetBy(dx: -8, dy: -8).contains(center) else { throw MacUI.Failure.staleScreen }
            invalidate()
            let role = Self.attr(element, kAXRoleAttribute as String) as? String ?? ""
            if MacUI.clicksWebContent(role: role, rolesTowardRoot: Self.ancestorRoles(element)) {
                Self.click(center)
            } else if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
                Self.click(center)
            }
            return MacUI.ActionResult(invoked: true)
        }
        guard let x, let y else { throw MacUI.Failure.invalidRequest("x,y") }
        let hit = current.snapshot.nodes.last { $0.bounds.contains(x, y) }
        if let hit, hit.password || Tools.isPayWord(hit.text) { throw MacUI.Failure.protectedAction }
        let point = CGPoint(x: x, y: y)
        let liveWindow = try raiseLive(current)
        guard liveWindow.insetBy(dx: -8, dy: -8).contains(point) else { throw MacUI.Failure.staleScreen }
        invalidate()
        Self.click(point)
        return MacUI.ActionResult(invoked: true)
    }

    func type(nodeId: String?, text: String) throws -> MacUI.ActionResult {
        guard AXIsProcessTrusted() else { throw MacUI.Failure.accessibility }
        let current = try requireSnapshot()
        let application = AXUIElementCreateApplication(current.pid)
        let element: AXUIElement
        if let nodeId {
            guard let node = current.snapshot.nodes.first(where: { $0.id == nodeId }),
                  let found = current.elements[nodeId] else { throw MacUI.Failure.staleScreen }
            if node.password || !node.editable || !node.enabled { throw MacUI.Failure.protectedAction }
            element = found
        } else if let focused = Self.attr(application, kAXFocusedUIElementAttribute as String),
                  CFGetTypeID(focused) == AXUIElementGetTypeID() {
            element = (focused as! AXUIElement)
            let role = Self.attr(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = Self.attr(element, kAXSubroleAttribute as String) as? String ?? ""
            if MacUI.isPassword(role: role, subrole: subrole) { throw MacUI.Failure.protectedAction }
        } else { throw MacUI.Failure.staleScreen }
        _ = try raiseLive(current)
        Self.focus(element, in: application)
        invalidate()
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success {
            return MacUI.ActionResult(typed: true)
        }
        Self.focus(element, in: application)
        Self.typeUnicode(text)
        return MacUI.ActionResult(typed: true)
    }

    private func requireSnapshot() throws -> Stored {
        lock.lock(); defer { lock.unlock() }
        guard let stored, Date().timeIntervalSince(stored.at) <= MacUI.snapshotTTL else {
            self.stored = nil
            throw MacUI.Failure.staleScreen
        }
        return stored
    }

    private func invalidate() { lock.lock(); stored = nil; lock.unlock() }

    fileprivate struct Target { let pid: pid_t, bundle: String, label: String }

    fileprivate static func resolve(_ bundle: String?) throws -> Target {
        let own = ProcessInfo.processInfo.processIdentifier
        if let bundle {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
                  running.processIdentifier != own else { throw MacUI.Failure.appNotFound }
            return Target(pid: running.processIdentifier, bundle: bundle, label: running.localizedName ?? bundle)
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own,
              let id = front.bundleIdentifier, MacUI.browserBundle(id) != nil || MacUI.browserBundle(front.localizedName ?? "") != nil
        else { throw MacUI.Failure.appNotFound }
        return Target(pid: front.processIdentifier, bundle: front.bundleIdentifier ?? "", label: front.localizedName ?? "")
    }

    fileprivate static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    fileprivate static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    fileprivate static func ancestorRoles(_ element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        for _ in 0..<32 {
            guard let el = current else { break }
            roles.append(attr(el, kAXRoleAttribute as String) as? String ?? "")
            guard let parent = attr(el, kAXParentAttribute as String),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let next = parent as! AXUIElement
            if CFEqual(next, el) { break }
            current = next
        }
        return roles
    }

    fileprivate static func frame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let pos = attr(element, kAXPositionAttribute as String), let sz = attr(element, kAXSizeAttribute as String),
              AXValueGetValue(pos as! AXValue, .cgPoint, &origin), AXValueGetValue(sz as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    fileprivate static func isLiveWindow(_ element: AXUIElement) -> Bool {
        guard let rect = frame(element) else { return false }
        return rect.width >= MacUI.liveWindowMin && rect.height >= MacUI.liveWindowMin
    }

    fileprivate static func primaryWindow(in application: AXUIElement) -> AXUIElement? {
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [String] {
            if let value = attr(application, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                if isLiveWindow(window) { return window }
            }
        }
        let windows = (attr(application, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        func area(_ window: AXUIElement) -> CGFloat {
            guard let rect = frame(window) else { return 0 }
            return max(0, rect.width) * max(0, rect.height)
        }
        return windows.filter(isLiveWindow).max { area($0) < area($1) }
    }

    private func raiseLive(_ stored: Stored) throws -> CGRect {
        let application = AXUIElementCreateApplication(stored.pid)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let running = NSRunningApplication(processIdentifier: stored.pid), !running.isActive {
            running.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(stored.windowElement, kAXRaiseAction as CFString)
        guard let live = Self.frame(stored.windowElement),
              live.width >= MacUI.liveWindowMin, live.height >= MacUI.liveWindowMin else {
            throw MacUI.Failure.staleScreen
        }
        return live
    }

    fileprivate static func focus(_ element: AXUIElement, in application: AXUIElement) {
        AXUIElementSetAttributeValue(application, kAXFocusedUIElementAttribute as CFString, element)
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            if let focused = attr(application, kAXFocusedUIElementAttribute as String),
               CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, element) {
                return
            }
            usleep(15_000)
        }
    }

    fileprivate static func stringValue(_ element: AXUIElement) -> String {
        if let text = attr(element, kAXValueAttribute as String) as? String { return text }
        return ""
    }

    fileprivate static func shortRole(_ role: String) -> String {
        let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        switch trimmed {
        case "Button": return "button"
        case "Link": return "link"
        case "TextField", "TextArea", "ComboBox", "SearchField", "SecureTextField": return "edit"
        case "StaticText": return "text"
        case "CheckBox": return "checkbox"
        case "RadioButton": return "radio"
        case "WebArea": return "document"
        default: return trimmed.lowercased()
        }
    }

    fileprivate static func clickableRole(_ role: String) -> Bool {
        ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXTab"].contains(role)
    }

    fileprivate static func editableRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    fileprivate static func limit(_ text: String?) -> String {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= MacUI.textLimit ? value : String(value.prefix(MacUI.textLimit))
    }

    fileprivate static func click(_ point: CGPoint) {
        func post(_ type: CGEventType) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.leftMouseDown); usleep(20_000); post(.leftMouseUp)
    }

    fileprivate static func typeUnicode(_ text: String) {
        let chunks = MacUI.hidUTF16Chunks(text)
        for (index, chunk) in chunks.enumerated() {
            chunk.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for keyDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { continue }
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                    event.post(tap: .cghidEventTap)
                }
            }
            if index + 1 < chunks.count { usleep(8_000) }
        }
    }
}

extension Tools {
    func executeMacUI(_ name: String, _ arguments: [String: Any]) throws -> String {
        if MacUI.fake == nil && !AXIsProcessTrusted() {
            runtimeRecorder.emit(.blocked, method: .control)
            try? db.setState("setup:needed", "1")
            return "실행 안 함: Mac에서 뽀미에게 손쉬운 사용 권한이 아직 없다. 뽀미 설정 창(시작하기)에서 손쉬운 사용을 켜 달라고 한 줄로 부탁하고 멈춰라."
        }
        let session = MacUI.fake ?? liveMacUI
        switch name {
        case "screen_read":
            runtimeRecorder.emit(.reading, method: .control)
            let snapshot = try session.read(app: arguments["app"] as? String)
            runtimeRecorder.emit(.read, method: .control)
            return MacUI.json(snapshot.json)
        case "ui_tap":
            let tap = try MacUI.parseTap(arguments)
            runtimeRecorder.emit(.acting, method: .control)
            let result = try session.tap(nodeId: tap.nodeId, x: tap.x, y: tap.y)
            runtimeRecorder.emit(.acted, method: .control)
            return MacUI.json(result.json)
        case "ui_type":
            let typed = try MacUI.parseType(arguments)
            runtimeRecorder.emit(.acting, method: .control)
            let result = try session.type(nodeId: typed.nodeId, text: typed.text)
            runtimeRecorder.emit(.acted, method: .control)
            return MacUI.json(result.json)
        default:
            return "unknown tool \(name)"
        }
    }
}

private let liveMacUI = LiveMacUI()
