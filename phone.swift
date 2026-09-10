// phone — drive the macOS "iPhone 미러링" window (or, with --windows, the Parallels Windows window): find, capture, OCR, tap, key, type.
// Build: swiftc -O phone.swift -o phone   (am.py does this automatically)
// All coordinates given to `tap` are normalized (0..1) within the mirroring window.
import AppKit
import Carbon
import WebKit
import CoreGraphics
import Foundation
import Vision

let bundleID = "com.apple.ScreenContinuity"

// `phone --windows …` drives the Parallels Windows window instead of the iPhone: same window/capture/OCR/tap, plain
// wheel scroll, clipboard typing (Hangul included, no IME dance), Win+R to open a URL or program. Same verbs, so the
// app only prefixes the flag. In the App Store edition the VM window belongs to the host process (prl_client_app), not to
// prl_vm_app, so "Parallels" means every running com.parallels.* process and the window is told apart by the VM's name.
let windowsTarget = CommandLine.arguments.dropFirst().first == "--windows"
let args = Array(CommandLine.arguments.dropFirst(windowsTarget ? 2 : 1))
let noWindow = windowsTarget ? "no Parallels Windows window (Parallels에서 Windows를 창 모드로 열어 주세요)" : "no mirroring window"
let targetName = windowsTarget ? "Parallels" : "iPhone Mirroring"

struct Win { let id: CGWindowID; let rect: CGRect; var pid: pid_t = 0 }

/// Pure checks shared by Windows pointer actions; tested without posting input or reading real windows.
enum PointerWindowSafety {
    static func refreshed(_ before: Win, after: Win?) -> Win? {
        guard let after, after.id == before.id, after.rect.size == before.rect.size else { return nil }
        return after                                      // movement is safe to rebase; resizing may reflow the target
    }

    static func coverer(of id: CGWindowID, at pt: CGPoint, ownPIDs: Set<pid_t>,
                        includeOwnWindows: Bool, windows: [[String: Any]]) -> String? {
        for w in windows {
            if let n = w["kCGWindowNumber"] as? Int, CGWindowID(n) == id { return nil }
            guard (w["kCGWindowLayer"] as? Int) == 0, let pid = w["kCGWindowOwnerPID"] as? pid_t,
                  includeOwnWindows || !ownPIDs.contains(pid),
                  let b = w["kCGWindowBounds"] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  CGRect(x: x, y: y, width: width, height: height).contains(pt) else { continue }
            return (w["kCGWindowOwnerName"] as? String) ?? "?"
        }
        return nil
    }
}

func targetApps() -> [NSRunningApplication] {
    windowsTarget ? NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("com.parallels.") == true }
                  : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

/// The VM's name from its own process ("prl_vm_app --vm-name Windows 11 --uuid …"): the VM window carries exactly that title.
let vmName: String? = {
    guard windowsTarget else { return nil }
    for app in targetApps() where app.executableURL?.lastPathComponent == "prl_vm_app" {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "args=", "-p", "\(app.processIdentifier)"]
        let o = Pipe(); p.standardOutput = o
        guard (try? p.run()) != nil else { continue }
        p.waitUntilExit()
        let s = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let r = s.range(of: "--vm-name ") {
            return s[r.upperBound...].components(separatedBy: " --")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}()

/// The process that owns the target window: iPhone Mirroring, or the Parallels process drawing the VM window.
func mirrorApp() -> NSRunningApplication? {
    let apps = targetApps()
    guard windowsTarget, let pid = cgWindows().first?.pid else { return apps.first }
    return apps.first { $0.processIdentifier == pid } ?? apps.first
}

// On-screen layer-0 windows of the target app, the wanted one first: for the iPhone the largest (CGWindowList sometimes
// reports a bogus 37x119 frame for the live window mid-animation, so callers that only need the ID must not filter on
// size); for Parallels the window titled with the VM's name, else the largest real window (제어 센터 is a 164pt strip).
func cgWindows() -> [Win] {
    let pids = Set(targetApps().map(\.processIdentifier))
    guard !pids.isEmpty else { return [] }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let wins = list.compactMap { w -> (Win, Bool)? in
        guard let pid = w["kCGWindowOwnerPID"] as? pid_t, pids.contains(pid), (w["kCGWindowLayer"] as? Int) == 0,
              let b = w["kCGWindowBounds"] as? [String: CGFloat], let id = w["kCGWindowNumber"] as? Int else { return nil }
        let win = Win(id: CGWindowID(id), rect: CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!), pid: pid)
        return (win, vmName != nil && (w["kCGWindowName"] as? String) == vmName)
    }
    return wins.filter { !windowsTarget || ($0.0.rect.height > 200 && (vmName == nil || $0.1)) }.sorted { a, b in
        if a.1 != b.1 { return a.1 }
        return a.0.rect.width * a.0.rect.height > b.0.rect.width * b.0.rect.height
    }.map(\.0)
}

// The AX window with its frame, chosen by the same rule as cgWindows(), so capture/tap/place agree on one window.
func axWindow() -> (AXUIElement, CGRect)? {
    var best: (AXUIElement, CGRect, Bool)?
    for app in targetApps() {
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &wins) == .success else { continue }
        for w in (wins as? [AXUIElement]) ?? [] {
            var pos: CFTypeRef?, size: CFTypeRef?, title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size)
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            var p = CGPoint.zero, s = CGSize.zero
            guard let pos, let size, AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s), s.height > 200 else { continue }
            let named = vmName != nil && (title as? String) == vmName
            if windowsTarget, vmName != nil, !named { continue }
            if let b = best, b.2 && !named { continue }
            if let b = best, b.2 == named, s.width * s.height <= b.1.width * b.1.height { continue }
            best = (w, CGRect(origin: p, size: s), named)
        }
    }
    return best.map { ($0.0, $0.1) }
}

func axFrame() -> CGRect? { axWindow()?.1 }

// Move the mirroring window (AX) so nothing floating (e.g. an always-on-top chat panel) sits over it and eats taps.
/// The one reference position for the mirroring window, used by collection (am.py) and the kiosk alike: the centre of the
/// screen the window is on. CG coordinates (origin top-left of the main display), which is what AX position takes.
func homePoint() -> CGPoint {
    let rect = cgWindows().first?.rect ?? CGRect(x: 0, y: 0, width: 348, height: 766)
    let main = NSScreen.screens.first?.frame ?? .zero
    let s = NSScreen.screens.first(where: { sc in
        CGRect(x: sc.frame.minX, y: main.maxY - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height).intersects(rect) }) ?? NSScreen.main!
    return CGPoint(x: s.frame.minX + (s.frame.width - rect.width) / 2, y: (main.maxY - s.frame.maxY) + (s.frame.height - rect.height) / 2)
}

func place(_ x: CGFloat, _ y: CGFloat) {
    guard AXIsProcessTrusted() else { fail("Accessibility 권한 필요 (run: phone perms)") }
    guard let (w, _) = axWindow() else { fail("no AX window") }
    var pt = CGPoint(x: x, y: y)
    if let v = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    usleep(300_000)
}

func findWindow(attempts: Int = 8) -> Win? {
    for attempt in 0..<attempts {
        if let window = cgWindows().first {
            if let f = axFrame() { return Win(id: window.id, rect: f, pid: window.pid) }
            if let w = cgWindows().first(where: { $0.rect.height > 200 }) { return w }
        }
        if attempt < attempts - 1 { usleep(500_000) }
    }
    return nil
}

func windowID() -> CGWindowID? { cgWindows().first?.id }

// `fail` exits instead of unwinding Swift defers. Private paste registers its in-memory clipboard cleanup here too.
var privateInputCleanup: (() -> Void)?
func fail(_ msg: String) -> Never {
    let cleanup = privateInputCleanup; privateInputCleanup = nil; cleanup?()
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1)
}

func capture(to path: String) {
    // With Stage Manager the window shrinks to a ~37x119pt strip thumbnail whenever another app is in front,
    // and screencapture then returns that thumbnail. Bring it on stage and retry.
    for attempt in 0..<10 {
        guard let id = windowID() else { fail(noWindow) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(id), path]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { fail("screencapture failed") }
        if let img = NSImage(contentsOfFile: path), let rep = img.representations.first, rep.pixelsWide >= 300 { return }
        if attempt == 0 { activate() }
        usleep(500_000)
    }
    fail("mirroring window stayed tiny (Stage Manager thumbnail / animating?)")
}

func frontmostBundle() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

func activateBundle(_ bundle: String) {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
}

// Prints one JSON object per line: {"x":..,"y":..,"w":..,"h":..,"conf":..,"text":".."} with top-left origin, 0..1.
func ocr(_ path: String) {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("bad image") }
    let req = VNRecognizeTextRequest { r, _ in
        let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
        for o in obs.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let c = o.topCandidates(1).first else { continue }
            let b = o.boundingBox
            let text = c.string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            print(String(format: "{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f,\"conf\":%.2f,\"text\":\"%@\"}",
                         b.minX, 1 - b.maxY, b.width, b.height, c.confidence, text))
        }
    }
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["ko-KR", "en-US"]
    req.usesLanguageCorrection = false // ponytail: correction dropped minus signs on numbers; merchant names still read fine
    try? VNImageRequestHandler(cgImage: cg).perform([req])
}

// Input needs the Accessibility grant and the mirroring window in front; otherwise events vanish silently
// or land in whatever app is frontmost. Fail loudly instead.
func activate() {
    guard AXIsProcessTrusted() else { fail("Accessibility 권한 필요: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 (run: phone perms)") }
    guard let app = mirrorApp() else { fail("\(targetName) not running") }
    // NSRunningApplication.activate()/isActive don't work from a run-loop-less CLI; AX frontmost does.
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    // Parallels has other windows (제어 센터, 구성): the VM window itself must be the key one, or keys go elsewhere.
    if windowsTarget, let (w, _) = axWindow() { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    for _ in 0..<20 {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXFrontmostAttribute as CFString, &v)
        if (v as? Bool) == true { usleep(150_000); return }
        usleep(100_000)
    }
    fail("could not bring \(targetName) to front")
}

/// Activation may move or resize a docked VM. Re-read once before any pointer event, without retrying the action.
func pointerWindow() -> Win {
    guard let before = findWindow() else { fail(noWindow) }
    activate()
    guard windowsTarget else { return before }             // preserve the iPhone's existing activation/frame sequence
    guard let current = PointerWindowSafety.refreshed(before, after: findWindow(attempts: 1)) else {
        fail("Windows window changed or resized during activation — read windows_screen again before acting")
    }
    return current
}

/// Host focus evidence for the specific VM window. Cursor location does not say which app/window is key.
/// AX is used rather than run-loop-dependent NSRunningApplication.isActive in this short-lived CLI.
func windowsInputReady(_ expected: Win) -> Bool {
    guard windowsTarget, let (window, _) = axWindow() else { return false }
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success, pid == expected.pid else { return false }
    let app = AXUIElementCreateApplication(expected.pid)
    var frontmost: CFTypeRef?, focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
          (frontmost as? Bool) == true,
          AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
    return CFEqual(focused, window)
}

func requireWindowsPointerFrame(_ expected: Win) {
    guard let current = findWindow(attempts: 1), current.id == expected.id,
          current.pid == expected.pid, current.rect == expected.rect else {
        fail("Windows window moved, resized or changed before clicking — read windows_screen again before acting")
    }
}

func requireWindowsInputReady(_ expected: Win) {
    for _ in 0..<20 {
        requireWindowsPointerFrame(expected)
        if windowsInputReady(expected) { return }
        usleep(50_000)
    }
    fail("Windows VM did not acquire keyboard focus — no target click was sent")
}

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }

// Parallels moves the guest pointer by the *relative* deltas of mouse events and re-syncs it to the Mac cursor only where the
// cursor enters the VM window; a synthetic event that just names an absolute point leaves the guest pointer where it was
// (e.g. hovering the taskbar). So before any Windows click or wheel: warp outside the left edge and glide in, carrying deltas.
func glide(from start: CGPoint, to pt: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    var last = start
    let steps = 16
    for i in 0...steps {
        let t = Double(i) / Double(steps), p = CGPoint(x: start.x + (pt.x - start.x) * t, y: start.y + (pt.y - start.y) * t)
        let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - last.x).rounded()))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - last.y).rounded()))
        e?.post(tap: .cghidEventTap); usleep(15_000)
        last = p
    }
    usleep(250_000)
}
func enter(_ pt: CGPoint, window: CGRect) {
    let start = CGPoint(x: window.minX - 40, y: pt.y)
    CGWarpMouseCursorPosition(start); usleep(60_000)
    glide(from: start, to: pt)
}
/// Where the (real) cursor is now, in CG coordinates.
func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// A layer-0 window in front of `id` that contains `pt`: input there would land on it. Windows includes Parallels' own
/// configuration/dialog windows; iPhone preserves its existing same-owner exemption. Everything behind the target is ignored.
func coverer(of id: CGWindowID, at pt: CGPoint) -> String? {
    let own = Set(targetApps().map(\.processIdentifier))
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return PointerWindowSafety.coverer(of: id, at: pt, ownPIDs: own, includeOwnWindows: windowsTarget, windows: list)
}

func tap(_ nx: Double, _ ny: Double) {
    // Keep activation history before pointerWindow() raises the VM. An agent can become frontmost while
    // the mouse stays over the VM, so "cursor inside" cannot suppress the safe activation click.
    let priorWindow = windowsTarget ? findWindow(attempts: 1) : nil
    let previouslyReady = priorWindow.map(windowsInputReady) ?? false
    let w = pointerWindow()
    let pt = CGPoint(x: w.rect.minX + w.rect.width * nx, y: w.rect.minY + w.rect.height * ny)
    let src = CGEventSource(stateID: .hidSystemState)
    // A click lands on whatever is on top there; the agent's own chat window often is. Say so instead of clicking it.
    if let owner = coverer(of: w.id, at: pt) { fail("window covered at (\(nx), \(ny)) by \(owner) — bring the \(targetName) window in front") }
    if windowsTarget {
        let needsPriming = !previouslyReady || priorWindow?.id != w.id || !windowsInputReady(w)
        if needsPriming {
            // Spend activation on host title-bar chrome, never by repeating the requested guest action.
            requireWindowsPointerFrame(w)
            let bar = CGPoint(x: w.rect.midX, y: w.rect.minY + 12)
            if let owner = coverer(of: w.id, at: bar) {
                fail("Windows title bar covered by \(owner) — read windows_screen again before acting")
            }
            for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: src, mouseType: kind, mouseCursorPosition: bar, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: 1)
                post(event); usleep(60_000)
            }
            usleep(400_000)
            requireWindowsInputReady(w)
            enter(pt, window: w.rect)
        } else {
            // Pointer location controls only the entry trajectory; it is not focus evidence.
            let cur = cursor()
            if w.rect.contains(cur) { glide(from: cur, to: pt) } else { enter(pt, window: w.rect) }
        }
    }
    post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left))
    usleep(80_000)
    if windowsTarget {
        // Another app can take focus during the glide. Do not reactivate and retry the guest action here.
        requireWindowsPointerFrame(w)
        guard windowsInputReady(w) else { fail("Windows VM focus changed before clicking — no target click was sent") }
        if let owner = coverer(of: w.id, at: pt) { fail("Windows target became covered by \(owner) — no target click was sent") }
    }
    for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: kind, mouseCursorPosition: pt, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)  // some apps drop clicks with clickState 0
        post(e); usleep(60_000)
    }
}

// macOS 26 ignores plain wheel ticks for the mirrored phone; a trackpad-style continuous gesture
// (phase began → changed… → ended) scrolls it. dy in pixels: negative = content moves up (scroll down).
// Recipe that iPhone Mirroring accepts (as worked out in mirroir-mcp): warp+hide the cursor over the window,
// a MayBegin(128) priming event, then continuous-trackpad frames carrying precise point deltas with the
// gesture phase (1 began, 2 changed…, 4 ended) and an explicit momentum phase of 0.
func scroll(_ dy: Int32, nx: Double = 0.5, ny: Double = 0.5) {
    guard let w = findWindow() else { fail(noWindow) }
    activate()
    // nx/ny: where the (invisible) finger is; web views only scroll when it is over the scrolling content, not a sticky bar
    let pt = CGPoint(x: w.rect.minX + w.rect.width * nx, y: w.rect.minY + w.rect.height * ny)
    let phaseField = CGEventField(rawValue: 99)!, momentumField = CGEventField(rawValue: 123)!
    let continuousField = CGEventField(rawValue: 88)!, pointDeltaY = CGEventField(rawValue: 96)!, pointDeltaX = CGEventField(rawValue: 97)!
    func ev(_ d: Int32, _ phase: Int64, _ momentum: Int64 = 0) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: d, wheel2: 0, wheel3: 0) else { return }
        e.location = pt
        e.setIntegerValueField(continuousField, value: 1)
        e.setIntegerValueField(pointDeltaY, value: Int64(d))
        e.setIntegerValueField(pointDeltaX, value: 0)
        e.setIntegerValueField(phaseField, value: phase)
        e.setIntegerValueField(momentumField, value: momentum)
        e.post(tap: .cghidEventTap)
    }
    CGWarpMouseCursorPosition(pt)
    CGDisplayHideCursor(CGMainDisplayID())
    CGAssociateMouseAndMouseCursorPosition(0)
    usleep(100_000)
    ev(0, 128); usleep(100_000)                       // MayBegin: finger touches the trackpad
    let steps: Int32 = 20
    for i in 0..<steps { ev(dy / steps, i == 0 ? 1 : 2); usleep(15_000) }
    ev(0, 4)                                          // finger lift
    usleep(16_000)
    // Momentum tail (a flick): some lists (KakaoTalk's chat list) only move for a flick, not a slow drag.
    var m = dy / steps
    for _ in 0..<12 { m = m * 3 / 4; if m == 0 { break }; ev(m, 0, 2); usleep(16_000) }
    ev(0, 0, 3)                                       // momentum end
    usleep(400_000)
    CGAssociateMouseAndMouseCursorPosition(1)
    CGDisplayShowCursor(CGMainDisplayID())
}

// Touch drag: press, many quick intermediate moves, release. Fast enough to read as a swipe, not a long-press.
func drag(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, ms: Int = 220) {
    let w = pointerWindow()
    let src = CGEventSource(stateID: .hidSystemState)
    func p(_ nx: Double, _ ny: Double) -> CGPoint { CGPoint(x: w.rect.minX + w.rect.width * nx, y: w.rect.minY + w.rect.height * ny) }
    let steps = 16
    if windowsTarget {
        // Check the actual drag path before mouse-down, including any window between otherwise clear endpoints.
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            if let owner = coverer(of: w.id, at: p(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)) {
                fail("Windows drag path covered by \(owner) — read windows_screen again before acting")
            }
        }
        enter(p(x1, y1), window: w.rect)
    }
    post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p(x1, y1), mouseButton: .left)); usleep(60_000)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p(x1, y1), mouseButton: .left)
    down?.setIntegerValueField(.mouseEventClickState, value: 1); down?.post(tap: .cghidEventTap)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t), mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1); e?.post(tap: .cghidEventTap)
        usleep(UInt32(ms * 1000 / steps))
    }
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p(x2, y2), mouseButton: .left)
    up?.setIntegerValueField(.mouseEventClickState, value: 1); up?.post(tap: .cghidEventTap)
    usleep(500_000)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    activate()
    // With the Korean IME active, ⌘V reaches the phone as the jamo 'ㅍ' (v key). Use the ABC layout for shortcuts.
    // Parallels forwards key codes to the guest, whose own IME decides Hangul: always ABC on the Mac side there.
    let prev = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let switched = (flags.contains(.maskCommand) || windowsTarget) && selectABC()
    defer { if switched, let prev { TISSelectInputSource(prev) } }
    // Parallels tracks modifiers as keys: a bare flag on the key event leaves Win/Ctrl held down in the guest until the
    // next real keypress. Press and release each modifier as its own key around the stroke (iPhone Mirroring needs no such thing).
    let mods: [(CGEventFlags, CGKeyCode)] = windowsTarget ? [(.maskCommand, 55), (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56)].filter { flags.contains($0.0) } : []
    var held: CGEventFlags = []
    for (f, k) in mods { held.insert(f); let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true); e?.flags = held; post(e) }
    let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true); d?.flags = flags
    let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false); u?.flags = flags
    post(d); post(u)
    for (f, k) in mods.reversed() { held.remove(f); let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false); e?.flags = held; post(e) }
}

// ---------------------------------------------------------------- Windows (Parallels) hands
// Plain wheel notches over the window: Parallels turns line-unit wheel events into guest notches (3 lines each, ~100px in
// a browser); pixel-unit and trackpad-gesture events scroll the wrong way or not at all there. dy in pixels like the phone's
// scroll: negative = content moves up (scroll down). Mind nested scroll boxes: the notches land on what is under nx, ny.
func wheel(_ dy: Int32, nx: Double = 0.5, ny: Double = 0.5) {
    let w = pointerWindow()
    let pt = CGPoint(x: w.rect.minX + w.rect.width * nx, y: w.rect.minY + w.rect.height * ny)
    if let owner = coverer(of: w.id, at: pt) {
        fail("Windows scroll position covered by \(owner) — read windows_screen again before acting")
    }
    enter(pt, window: w.rect)
    let notches = max(1, abs(dy) / 100), lines: Int32 = dy < 0 ? -3 : 3
    for _ in 0..<notches {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        e?.location = pt; e?.post(tap: .cghidEventTap); usleep(60_000)
    }
    usleep(500_000)
}

// "enter", "ctrl+l", "alt+f4", "win+r", "shift+tab", "f5", a single character: Mac key codes; Parallels maps ⌘ to Win.
let WINKEYS: [String: CGKeyCode] = ["enter": 36, "return": 36, "escape": 53, "esc": 53, "tab": 48, "backspace": 51, "delete": 117,
    "space": 49, "up": 126, "down": 125, "left": 123, "right": 124, "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "win": 55]
func winKey(_ spec: String) {
    let parts = spec.split(separator: "+").map(String.init)
    let usage = "key: \(spec) — names: \(WINKEYS.keys.sorted().joined(separator: " ")), modifiers ctrl alt shift win (e.g. ctrl+l, alt+f4, win+r)"
    guard let last = parts.last, let hit = WINKEYS[last.lowercased()].map({ ($0, false) }) ?? (last.count == 1 ? KEYCODES[Character(last)] : nil) else { fail(usage) }
    let code = hit.0
    var flags: CGEventFlags = hit.1 ? [.maskShift] : []
    for part in parts.dropLast() {
        switch part.lowercased() {
        case "ctrl", "control": flags.insert(.maskControl)
        case "alt", "option": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "win", "cmd", "command", "meta": flags.insert(.maskCommand)
        default: fail(usage)
        }
    }
    key(code, flags)
}

// Typing goes through the shared clipboard (Ctrl+V): Hangul arrives intact whatever the guest IME is doing. The text
// stays on both clipboards afterwards (Parallels syncs both ways, so restoring the Mac side does not stick). Fields that
// refuse paste (security keypads, password boxes) are the person's turn anyway.
func paste(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents(); pb.setString(text, forType: .string)
    usleep(500_000)                                        // Parallels Tools syncs the Mac clipboard into the guest
    key(9, .maskControl)                                   // Ctrl+V
    usleep(600_000)
}

enum PrivateTextInput {
    static let maximumBytes = 2_000

    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) }) else { return nil }
        return text
    }

    /// Read only the bounded payload, never a command-line argument. Empty/interactive stdin is not an input value.
    static func read() -> String {
        read(maximumBytes: maximumBytes)
    }

    static func read(maximumBytes limit: Int) -> String {
        guard (1...maximumBytes).contains(limit) else { fail("invalid private input limit") }
        guard isatty(STDIN_FILENO) == 0 else { fail("private input requires stdin") }
        var data = Data()
        do {
            while data.count <= limit {
                guard let part = try FileHandle.standardInput.read(upToCount: limit + 1 - data.count), !part.isEmpty else { break }
                data.append(part)
            }
        } catch { fail("private input could not be read") }
        guard data.count <= limit, let text = decode(data) else { fail("invalid private input") }
        return text
    }
}

/// A narrow path for verified numeric fields that reject paste and Ctrl+A. No clipboard or modifier keys.
enum PrivateDigitsInput {
    static let maximumDigits = 10

    static func keyPlan(_ text: String) -> [CGKeyCode]? {
        let digits = Array(text.utf8)
        guard (1...maximumDigits).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        // These are macOS CGKeyCodes, translated by Parallels: Home -> Windows VK36, forward Delete -> VK46.
        let numberKeys: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        return [115] + Array(repeating: 117, count: maximumDigits) + digits.map { numberKeys[Int($0 - 48)] }
    }

    static func read() -> String {
        let text = PrivateTextInput.read(maximumBytes: maximumDigits)
        guard keyPlan(text) != nil else { fail("invalid private numeric input") }
        return text
    }
}

func typeDigitsPrivate(_ text: String) {
    guard windowsTarget, let keys = PrivateDigitsInput.keyPlan(text) else { fail("invalid private numeric input") }
    activate()
    let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    guard selectABC() else { fail("private numeric keyboard unavailable") }
    defer { if let previous { TISSelectInputSource(previous) } }
    for code in keys {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = []; up?.flags = []
        post(down); post(up)
    }
}

/// iPhone inputs must already be empty and focused. Never erase content or use the clipboard.
enum PhonePrivateDigitsInput {
    static func keyPlan(_ text: String) -> [CGKeyCode]? {
        let digits = Array(text.utf8)
        guard (1...10).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let numberKeys: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        return digits.map { numberKeys[Int($0 - 48)] }
    }
}

/// 두벌식 key letters (already converted by the app) typed through the Korean input source into a verified, focused,
/// empty iPhone name field. Letters only: no digits, modifiers, paste or clipboard.
func typePhoneKeysPrivate(_ text: String) {
    guard !windowsTarget, (1...400).contains(text.utf8.count),
          text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { fail("invalid private phone key input") }
    type(text, korean: true)
}

func typePhoneDigitsPrivate(_ text: String) {
    guard !windowsTarget, let keys = PhonePrivateDigitsInput.keyPlan(text) else { fail("invalid private phone numeric input") }
    activate()
    let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    guard selectABC() else { fail("private numeric keyboard unavailable") }
    defer { if let previous { TISSelectInputSource(previous) } }
    for code in keys {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = []; up?.flags = []
        post(down); post(up)
    }
}

/// Snapshot every offered item/type as data in memory. Never restore over a newer clipboard generation.
/// Parallels/Windows clipboard history is outside this local, best-effort restoration.
final class PrivateClipboard {
    enum Failure: Error { case unavailable, changed }
    private let pasteboard: NSPasteboard
    private let originalCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]
    private var ownedCount: Int?
    private var ownedText: String?

    init(_ pasteboard: NSPasteboard) throws {
        self.pasteboard = pasteboard
        originalCount = pasteboard.changeCount
        items = try (pasteboard.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw Failure.unavailable }
                return (type, data)
            }
        }
        guard pasteboard.changeCount == originalCount else { throw Failure.changed }
    }

    func install(_ text: String) throws {
        guard pasteboard.changeCount == originalCount else { throw Failure.changed }
        ownedCount = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw Failure.unavailable }
        guard pasteboard.changeCount == ownedCount else { throw Failure.changed }
        ownedText = text
    }

    var isCurrent: Bool {
        ownedCount != nil && pasteboard.changeCount == ownedCount && pasteboard.string(forType: .string) == ownedText
    }

    func restoreIfUnchanged() {
        guard let count = ownedCount, pasteboard.changeCount == count,
              pasteboard.string(forType: .string) == ownedText else { return }
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == count else { return }
        ownedCount = nil
        pasteboard.clearContents()
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

func pastePrivate(_ text: String) {
    do {
        let clipboard = try PrivateClipboard(.general)
        privateInputCleanup = { clipboard.restoreIfUnchanged() }
        defer { clipboard.restoreIfUnchanged(); privateInputCleanup = nil }
        try clipboard.install(text)
        usleep(500_000)
        guard clipboard.isCurrent else { throw PrivateClipboard.Failure.changed }
        key(9, .maskControl)
        usleep(600_000)
    } catch { fail("private input clipboard unavailable or changed") }
}

// Win+R → the target → Enter: a URL opens in the default browser, a program name runs it.
func winOpen(_ target: String) {
    key(15, .maskCommand)                                  // ⌘R → Win+R in Parallels
    usleep(900_000)
    paste(target)
    key(36)
    usleep(2_500_000)                                      // the browser comes up and starts loading
}

// Korean IME turns synthetic keystrokes into tofu boxes in iOS text fields; force ABC first.
func currentInputSourceID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func selectABC() -> Bool {
    for id in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let src = list.first {
            TISSelectInputSource(src); usleep(200_000)
            if currentInputSourceID() == id { return true }
        }
    }
    return false
}

// iPhone Mirroring forwards *key codes*, not unicode strings — keyboardSetUnicodeString arrives as tofu boxes.
// So: ASCII only, ANSI virtual key codes, with the ABC layout selected for the duration.
let KEYCODES: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let rows: [(String, [CGKeyCode])] = [
        ("abcdefghijklmnopqrstuvwxyz", [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]),
        ("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]),
        (" -=[]\\;',./`", [49, 27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50]),
    ]
    for (chars, codes) in rows { for (c, k) in zip(chars, codes) { m[c] = (k, false) } }
    for (c, k) in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", rows[0].1) { m[c] = (k, true) }
    for (c, k) in zip("!@#$%^&*()", rows[1].1) { m[c] = (k, true) }
    for (c, k) in zip("_+{}|:\"<>?~", [27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50] as [CGKeyCode]) { m[c] = (k, true) }
    return m
}()

func selectSource(_ ids: [String]) -> Bool {
    for id in ids {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let src = list.first {
            TISSelectInputSource(src); usleep(200_000)
            if currentInputSourceID() == id { return true }
        }
    }
    return false
}

// The iPhone follows the Mac's input source: with a Korean source active, letter keys compose Hangul on the phone
// (두벌식: "rladudgml" -> 김영희); with ABC they stay Latin.
func type(_ text: String, korean: Bool = false) {
    for ch in text where KEYCODES[ch] == nil { fail("type: ASCII only, cannot type \(ch)") }  // validate before touching the IME
    activate()
    let prev = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let restore = { if let prev { TISSelectInputSource(prev) } }  // give the user their input source back
    let ok = korean ? selectSource(["com.apple.inputmethod.Korean.2SetKorean", "com.apple.inputmethod.Korean"]) : selectABC()
    if !ok { restore(); fail("could not switch input source (now: \(currentInputSourceID()))") }
    defer { restore() }
    for ch in text {
        let (code, shift) = KEYCODES[ch]!
        let flags: CGEventFlags = shift ? .maskShift : []
        let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true); d?.flags = flags
        let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false); u?.flags = flags
        post(d); post(u)
    }
}

// ---------------------------------------------------------------- kiosk
// Four black windows above everything (menu bar and Dock included) leave a hole at the reference spot (homePoint()), and the
// mirroring window is pinned into it: we control where the window goes, so the hole is fixed and anything that moves the window
// gets undone. Only a size change (View > 크게/작게) rebuilds the hole. The mirroring window stays a normal window inside the hole
// and gets clicks and keys as usual; the mirroring app is kept frontmost so no other window can wander in. Bands do not join
// all Spaces: a 3-finger swipe must not take the donut to the next desktop with an empty hole. The left band shows
// data/timeline.html (report.py timeline: the net-worth line, the day's balance sheets, the equation check) and reloads it when
// the file changes. Leave: a mouse click on the ring reveals × (top-right); only that mark quits. Esc reveals ×, a second Esc quits.
let KIOSK_BORDER: CGFloat = 2                          // rim drawn on each band's inner edge (0 = none)
var onPress: () -> Void = {}

final class RingView: NSView {
    var edge: NSRectEdge = .minY                       // the side of this band that faces the hole
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard KIOSK_BORDER > 0 else { return }
        NSColor(red: 0.78, green: 0.64, blue: 0, alpha: 1).setFill()
        let b = bounds, t = KIOSK_BORDER
        switch edge {
        case .minY: NSRect(x: 0, y: 0, width: b.width, height: t).fill()
        case .maxY: NSRect(x: 0, y: b.height - t, width: b.width, height: t).fill()
        case .minX: NSRect(x: 0, y: 0, width: t, height: b.height).fill()
        default:    NSRect(x: b.width - t, y: 0, width: t, height: b.height).fill()
        }
    }
}

final class BandPanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

final class ExitMark: NSView {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func draw(_ dirty: NSRect) {
        let inset = bounds.insetBy(dx: 5, dy: 5)
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let oval = NSBezierPath(ovalIn: inset); oval.lineWidth = 2; oval.stroke()
        let x = NSBezierPath(), m: CGFloat = 11
        x.move(to: CGPoint(x: inset.midX - m / 2, y: inset.midY - m / 2)); x.line(to: CGPoint(x: inset.midX + m / 2, y: inset.midY + m / 2))
        x.move(to: CGPoint(x: inset.midX + m / 2, y: inset.midY - m / 2)); x.line(to: CGPoint(x: inset.midX - m / 2, y: inset.midY + m / 2))
        x.lineWidth = 2; x.lineCapStyle = .round; x.stroke()
    }
}

final class Ring {
    let windows: [NSPanel] = (0..<4).map { i in
        let w = BandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isFloatingPanel = true; w.hidesOnDeactivate = false; w.becomesKeyOnlyIfNeeded = true
        w.level = .screenSaver; w.backgroundColor = .black; w.isOpaque = true; w.hasShadow = false
        w.ignoresMouseEvents = false; w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        let v = RingView(); v.edge = [.minY, .maxY, .maxX, .minX][i]; w.contentView = v   // top, bottom, left, right bands
        if i == 1 {
            let t = NSTextField(labelWithString: "나가기: 검은 부분 클릭 후 ×")
            t.textColor = NSColor(white: 1, alpha: 0.35); t.font = .systemFont(ofSize: 13); t.sizeToFit()
            t.frame.origin = CGPoint(x: 16, y: 12); t.autoresizingMask = [.maxXMargin, .maxYMargin]; v.addSubview(t)
        }
        return w                                       // nonactivating panel: Stage Manager keeps us on stage; focus stays with mirroring
    }
    let exitMark: ExitMark = { let m = ExitMark(); m.isHidden = true; return m }()
    var pinned = CGRect.zero, tapPort: CFMachPort?
    let web = WKWebView(frame: .zero)
    let timelineURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("data/timeline.html")
    var timelineStamp = Date.distantPast
    func showTimeline() {                             // (re)load when report.py has written a newer file
        guard let m = (try? FileManager.default.attributesOfItem(atPath: timelineURL.path))?[.modificationDate] as? Date, m > timelineStamp else { return }
        timelineStamp = m
        web.loadFileURL(timelineURL, allowingReadAccessTo: timelineURL.deletingLastPathComponent())
    }
    /// Put the mirroring window at the reference spot and build the hole around it (once, and again after a size change).
    func build() {
        let p = homePoint(); place(p.x, p.y)
        pinned = cgWindows().first?.rect ?? CGRect(origin: p, size: CGSize(width: 348, height: 766))
        let main = NSScreen.screens.first?.frame ?? .zero
        let screen = NSScreen.screens.first(where: { sc in
            CGRect(x: sc.frame.minX, y: main.maxY - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height).intersects(pinned) }) ?? NSScreen.main!
        let s = screen.frame
        let hole = CGRect(x: pinned.minX, y: main.maxY - pinned.maxY, width: pinned.width, height: pinned.height)   // CG -> AppKit
        let rects = [CGRect(x: s.minX, y: hole.maxY, width: s.width, height: max(0, s.maxY - hole.maxY)),
                     CGRect(x: s.minX, y: s.minY, width: s.width, height: max(0, hole.minY - s.minY)),
                     CGRect(x: s.minX, y: hole.minY, width: max(0, hole.minX - s.minX), height: hole.height),
                     CGRect(x: hole.maxX, y: hole.minY, width: max(0, s.maxX - hole.maxX), height: hole.height)]
        for (w, r) in zip(windows, rects) { w.setFrame(r, display: true); w.orderFrontRegardless() }
        if exitMark.superview == nil { windows[0].contentView!.addSubview(exitMark); exitMark.onClick = { NSApplication.shared.terminate(nil) } }
        if !exitMark.isHidden { showExitMark() }
        let band = windows[2].contentView!           // the left band carries the timeline, inset from the rim and the edges
        if web.superview == nil { web.setValue(false, forKey: "drawsBackground"); band.addSubview(web) }
        web.frame = band.bounds.insetBy(dx: 12, dy: 12).offsetBy(dx: -4, dy: 0)
        web.autoresizingMask = [.width, .height]
        showTimeline()
    }
    /// Each tick: the window is ours, so it stays where we put it; only a resize (View menu) changes the hole.
    func pin() {
        windows.forEach { $0.orderFrontRegardless() }
        showTimeline()
        if let a = mirrorApp(), !a.isActive { activateBundle(bundleID) }
        guard let cur = cgWindows().first?.rect else { return }
        if cur.size != pinned.size { build() } else if cur.origin != pinned.origin { place(pinned.minX, pinned.minY) }
    }
    func onRing(_ p: CGPoint) -> Bool { windows.contains { $0.frame.contains(p) } }
    func closeMarkContains(_ p: CGPoint) -> Bool {
        guard !exitMark.isHidden, let win = exitMark.window else { return false }
        return win.convertToScreen(exitMark.convert(exitMark.bounds, to: nil)).contains(p)
    }
    func showExitMark() {
        guard let top = windows.first?.contentView else { return }
        let s: CGFloat = 44
        exitMark.frame = NSRect(x: top.bounds.width - s - 14, y: top.bounds.height - s - 10, width: s, height: s)
        exitMark.autoresizingMask = [.minXMargin, .minYMargin]
        exitMark.isHidden = false; exitMark.needsDisplay = true
    }
    func ringClicked(_ p: CGPoint) { if closeMarkContains(p) { NSApplication.shared.terminate(nil) } else { showExitMark() } }
    func press() { if exitMark.isHidden { showExitMark() } else { NSApplication.shared.terminate(nil) } }   // Esc: reveal ×, then leave
}

func kiosk() -> Never {
    guard AXIsProcessTrusted() else { fail("Accessibility 권한 필요 (run: phone perms)") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching]
    let ring = Ring()
    ring.build()
    onPress = { ring.showExitMark() }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in ring.pin() }
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { ring.press() } }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { ring.press() }; return e }
    // Swallow: (1) ring clicks that missed our panels (2) 3-finger space swipes so the donut cannot follow to an empty hole.
    // Gesture raw values: rotate 18, begin/end 19/20, gesture 29, magnify 30, swipe 31, smartMagnify 32 — inlined so the C callback captures nothing.
    let gestures: [CGEventType] = [18, 19, 20, 29, 30, 31, 32].compactMap { CGEventType(rawValue: $0) }
    var kinds: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, .tabletPointer, .keyDown, .keyUp]
    kinds.append(contentsOf: gestures)
    let mask = kinds.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let boxed = Unmanaged.passRetained(ring)
    for loc: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
        ring.tapPort = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let ring = Unmanaged<Ring>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let p = ring.tapPort { CGEvent.tapEnable(tap: p, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let v = type.rawValue
            if v == 18 || v == 19 || v == 20 || v == 29 || v == 30 || v == 31 || v == 32 { return nil }
            if type == .keyDown || type == .keyUp {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if event.flags.contains(.maskControl) && (123...126).contains(code) { return nil }
            }
            let p = CGPoint(x: event.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
            guard ring.onRing(p) else { return Unmanaged.passUnretained(event) }
            let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
            if ring.windows.contains(where: { $0.windowNumber == n }) { return Unmanaged.passUnretained(event) }
            if type == .leftMouseDown { let pt = p; DispatchQueue.main.async { ring.ringClicked(pt) } }
            return nil
        }, userInfo: boxed.toOpaque())
        if ring.tapPort != nil { break }
    }
    if let tap = ring.tapPort {
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    } else { FileHandle.standardError.write("kiosk: event tap failed — clicks may pass through\n".data(using: .utf8)!) }
    signal(SIGINT) { _ in exit(0) }
    app.run()
    exit(0)
}

// ---------------------------------------------------------------- state, read from the mirroring window's accessibility tree
// The overlay texts ("연결이 중단됨", "연결이 일시 정지됨", "iPhone 사용 중") and buttons are AX elements, so no capture is needed
// and an AXObserver turns them into events. States: CONNECTED | DISCONNECTED | PAUSED | IN_USE | NONE (no window).
var lastState = ""
func axTexts(_ e: AXUIElement, _ depth: Int = 0, into out: inout [String]) {
    var v: CFTypeRef?, kids: CFTypeRef?
    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if let t = v as? String, !t.isEmpty { out.append(t) }
    }
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
    if depth < 6 { for k in (kids as? [AXUIElement]) ?? [] { axTexts(k, depth + 1, into: &out) } }
}
func mirrorState() -> String {
    guard let (w, _) = axWindow() else { return "NONE" }
    if windowsTarget { return vmName == nil ? "NONE" : "READY" }   // no pause/lock overlay to read; no VM process, no desktop
    var texts: [String] = []
    axTexts(w, into: &texts)
    let all = texts.joined(separator: " ")
    if all.contains("iPhone 잠금 해제") { return "DISCONNECTED" }
    if all.contains("사용 중") || all.contains("잠그십시오") { return "IN_USE" }
    if all.contains("중단됨") || all.contains("다시 시도") { return "DISCONNECTED" }
    if all.contains("일시 정지") || texts.contains("재개") { return "PAUSED" }
    return "CONNECTED"
}

switch args.first ?? "" {
case "window":
    guard let w = findWindow() else { fail(noWindow) }
    print("\(w.id) \(Int(w.rect.minX)) \(Int(w.rect.minY)) \(Int(w.rect.width)) \(Int(w.rect.height))")
case "perms":
    // Input posting + AX need the Accessibility grant for the *calling* app (Terminal/Claude/launchd runner).
    // These calls make macOS show the grant prompt; nothing is changed without the user clicking through.
    let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    let post = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    print("accessibility=\(ax) postEvents=\(post) screenCapture=\(screen)")
    if !(ax && post) { exit(2) }
case "place":                                       // place x y (CG coords) | place center (the shared reference spot)
    if args.count > 1, args[1] == "center" { let p = homePoint(); place(p.x, p.y) }
    else { place(CGFloat(Double(args[1])!), CGFloat(Double(args[2])!)) }
case "kiosk": kiosk()
case "state": print(mirrorState())
case "watch":                                       // print the state whenever the mirroring window changes (AX events, no capture)
    guard let app = mirrorApp() else { fail("\(targetName) not running") }
    var obs: AXObserver?
    guard AXObserverCreate(app.processIdentifier, { _, _, _, _ in
        let st = mirrorState()
        if st != lastState { lastState = st; print(st); fflush(stdout) }
    }, &obs) == .success, let o = obs else { fail("AXObserverCreate failed (손쉬운 사용 권한?)") }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    for n in [kAXLayoutChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXWindowCreatedNotification] {
        AXObserverAddNotification(o, ax, n as CFString, nil)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(o), .defaultMode)
    lastState = mirrorState(); print(lastState); fflush(stdout)
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in     // belt and braces: some transitions raise no AX event
        let st = mirrorState(); if st != lastState { lastState = st; print(st); fflush(stdout) }
    }
    CFRunLoopRun()
case "axdump":                                      // debug: what the mirroring window exposes to accessibility (roles, titles, values)
    guard let app = mirrorApp() else { fail("\(targetName) not running") }
    func walk(_ e: AXUIElement, _ depth: Int) {
        var role: CFTypeRef?, title: CFTypeRef?, value: CFTypeRef?, desc: CFTypeRef?, kids: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &value)
        AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
        let bits = [role as? String, title as? String, value as? String, desc as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !bits.isEmpty { print(String(repeating: "  ", count: depth) + bits.joined(separator: " | ")) }
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
        if depth < 8 { for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth + 1) } }
    }
    walk(AXUIElementCreateApplication(app.processIdentifier), 0)
case "front": print(frontmostBundle())
case "activate": activateBundle(args[1])
case "capture": capture(to: args[1])
case "capture-private":
    guard args.count == 2 else { fail("private capture requires a destination") }
    umask(0o077)                                          // inherited by screencapture; the PNG is private from creation
    capture(to: args[1])
    guard chmod(args[1], 0o600) == 0 else { fail("private capture permissions failed") }
case "ocr": ocr(args[1])
case "tap": tap(Double(args[1])!, Double(args[2])!)
case "scroll":
    let nx = args.count > 2 ? Double(args[2])! : 0.5, ny = args.count > 3 ? Double(args[3])! : 0.5
    windowsTarget ? wheel(Int32(args[1])!, nx: nx, ny: ny) : scroll(Int32(args[1])!, nx: nx, ny: ny)
case "drag": drag(Double(args[1])!, Double(args[2])!, Double(args[3])!, Double(args[4])!, ms: args.count > 5 ? Int(args[5])! : 220)
case "key" where windowsTarget: winKey(args[1])
case "open" where windowsTarget: winOpen(args[1])
case "key":
    let map: [String: (CGKeyCode, CGEventFlags)] = ["home": (18, .maskCommand), "spotlight": (20, .maskCommand),
        "switcher": (19, .maskCommand), "return": (36, []), "escape": (53, []), "paste": (9, .maskCommand),  // paste = Mac clipboard -> iPhone
        "selectall": (0, .maskCommand), "delete": (51, []), "down": (125, []), "pagedown": (121, []), "space": (49, [])]
    guard let k = map[args[1]] else { fail("keys: \(map.keys.sorted())") }
    key(k.0, k.1)
case "type": windowsTarget ? paste(args[1]) : type(args[1])
case "type-private":
    guard windowsTarget, args.count == 1 else { fail("private input requires Windows and stdin only") }
    pastePrivate(PrivateTextInput.read())
case "type-digits-private":
    guard windowsTarget, args.count == 1 else { fail("private numeric input requires Windows and stdin only") }
    typeDigitsPrivate(PrivateDigitsInput.read())
case "type-phone-digits-private":
    guard !windowsTarget, args.count == 1 else { fail("private phone numeric input requires iPhone and stdin only") }
    typePhoneDigitsPrivate(PrivateTextInput.read(maximumBytes: 10))
case "type-phone-keys-private":
    guard !windowsTarget, args.count == 1 else { fail("private phone key input requires iPhone and stdin only") }
    typePhoneKeysPrivate(PrivateTextInput.read(maximumBytes: 400))
case "typeko": type(args[1], korean: true)
default: print("usage: phone [--windows] perms | window | state | watch | place x y|center | kiosk | front | activate bundle.id | capture out.png | ocr in.png | tap nx ny | scroll dy [nx ny] | key home|spotlight|switcher|return|escape | type text\n  --windows (Parallels): key enter|ctrl+l|alt+f4|win+r|… | type text (clipboard paste) | open url|program")
}
