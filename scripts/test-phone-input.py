#!/usr/bin/env python3
"""Exercise phone.swift's real pointer safety checks with synthetic windows only."""
from pathlib import Path
import subprocess
import tempfile


source = (Path(__file__).resolve().parents[1] / "phone.swift").read_text()


def declaration(start):
    body = source[source.index(start):]
    return body[:body.index("\n}\n") + 3]


win = next(line for line in source.splitlines() if line.startswith("struct Win "))
find_window_harness = "import Foundation\nimport CoreGraphics\n" + win + "\n"
find_window_harness += r'''
var windows: [Win] = []
var accessibilityFrame: CGRect?
func cgWindows() -> [Win] { windows }
func axFrame() -> CGRect? { accessibilityFrame }
'''
find_window_harness += declaration("func findWindow(attempts: Int = 8) -> Win? {") + "\n"
find_window_harness += r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("Failed: \(name)\n".utf8))
        exit(23)
    }
    checks += 1
}
let vm = Win(id: 10, rect: CGRect(x: 100, y: 200, width: 900, height: 620), pid: 50)
windows = [vm]
accessibilityFrame = CGRect(x: 300, y: 100, width: 900, height: 620)
let withAX = findWindow(attempts: 1)
check(withAX?.pid == vm.pid, "AX frame must preserve the owner PID used by Windows focus validation")
check(withAX?.id == vm.id, "AX frame must preserve the captured window ID")
check(withAX?.rect == accessibilityFrame, "AX frame supplies the current input geometry")
accessibilityFrame = nil
let withoutAX = findWindow(attempts: 1)
check(withoutAX?.pid == vm.pid && withoutAX?.id == vm.id && withoutAX?.rect == vm.rect,
      "CG fallback preserves the window and its owner")
let small = Win(id: 20, rect: CGRect(x: 0, y: 0, width: 37, height: 119), pid: 60)
windows = [small, vm]
check(findWindow(attempts: 1)?.id == vm.id, "fallback skips a transient small frame")
windows = []
check(findWindow(attempts: 1) == nil, "missing windows stay missing")
print("\(checks) real findWindow metadata checks passed")
'''

harness = "import Foundation\nimport CoreGraphics\n" + win + "\n"
harness += declaration("enum PointerWindowSafety {") + "\n"
harness += r'''
var windowsTarget = true
let noWindow = "missing window"
var frames: [Win?] = []
var reads: [Int] = []
var activations = 0
func findWindow(attempts: Int = 8) -> Win? {
    reads.append(attempts)
    if reads.count == 2 { precondition(activations == 1, "must re-read after activation") }
    return frames.removeFirst()
}
func activate() { activations += 1 }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(23)
}
'''
harness += declaration("func pointerWindow() -> Win {") + "\n"
harness += r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    checks += 1
}
let original = Win(id: 10, rect: CGRect(x: 100, y: 200, width: 900, height: 620), pid: 50)
let moved = Win(id: 10, rect: CGRect(x: 300, y: 100, width: 900, height: 620), pid: 50)
let resized = Win(id: 10, rect: CGRect(x: 100, y: 200, width: 882, height: 620), pid: 50)
let replaced = Win(id: 11, rect: original.rect, pid: 50)
let mode = CommandLine.arguments.dropFirst().first ?? "checks"
if mode.hasPrefix("reject-") {
    frames = [original, mode == "reject-resize" ? resized : mode == "reject-id" ? replaced : nil]
    _ = pointerWindow()
    fatalError("changed window was allowed")
}
check(PointerWindowSafety.refreshed(original, after: original)?.rect == original.rect, "unchanged frame")
check(PointerWindowSafety.refreshed(original, after: moved)?.rect == moved.rect, "movement uses new frame")
check(PointerWindowSafety.refreshed(original, after: resized) == nil, "resize invalidates target")
check(PointerWindowSafety.refreshed(original, after: replaced) == nil, "replacement invalidates target")
check(PointerWindowSafety.refreshed(original, after: nil) == nil, "missing window invalidates target")

frames = [original, moved]
let fresh = pointerWindow()
check(fresh.rect == moved.rect && reads == [8, 1] && activations == 1, "Windows revalidates once after activation")
windowsTarget = false
frames = [original, resized]
reads = []; activations = 0
check(pointerWindow().rect == original.rect, "iPhone keeps original frame")
check(reads == [8] && activations == 1 && frames.count == 1, "iPhone keeps one read and activation")

func window(_ id: Int, pid: pid_t, name: String, rect: CGRect, layer: Int = 0) -> [String: Any] {
    ["kCGWindowNumber": id, "kCGWindowOwnerPID": pid, "kCGWindowOwnerName": name, "kCGWindowLayer": layer,
     "kCGWindowBounds": ["X": rect.minX, "Y": rect.minY, "Width": rect.width, "Height": rect.height]]
}
let target = window(10, pid: 50, name: "Parallels", rect: original.rect)
let sameOwner = window(20, pid: 50, name: "Parallels settings", rect: original.rect)
let otherOwner = window(30, pid: 60, name: "Other app", rect: original.rect)
let point = CGPoint(x: 550, y: 400)
func covering(_ windows: [[String: Any]], _ point: CGPoint = point, includeOwn: Bool = true) -> String? {
    PointerWindowSafety.coverer(of: 10, at: point, ownPIDs: [50], includeOwnWindows: includeOwn, windows: windows)
}
check(covering([sameOwner, target]) == "Parallels settings", "Windows blocks its own front dialog")
check(covering([sameOwner, target], includeOwn: false) == nil, "iPhone keeps same-owner exemption")
check(covering([otherOwner, target]) == "Other app", "another app blocks the pointer")
check(covering([target, sameOwner, otherOwner]) == nil, "windows behind the target do not block")
check(covering([sameOwner, target], CGPoint(x: 50, y: 50)) == nil, "non-overlapping window does not block")
let titleCover = window(40, pid: 60, name: "Title cover", rect: CGRect(x: 500, y: 200, width: 100, height: 24))
check(covering([titleCover, target], CGPoint(x: 550, y: 212)) == "Title cover", "title bar priming location must be clear")
check(covering([titleCover, target], point) == nil, "clear guest point does not imply clear title bar")
let middleCover = window(41, pid: 50, name: "Middle cover", rect: CGRect(x: 540, y: 390, width: 20, height: 20))
let start = CGPoint(x: 200, y: 400), end = CGPoint(x: 900, y: 400)
check(covering([middleCover, target], start) == nil && covering([middleCover, target], end) == nil,
      "drag endpoints can both be clear")
check(covering([middleCover, target], point) == "Middle cover", "drag must inspect the path between endpoints")
print("\(checks) pointer geometry/occlusion checks passed")
'''

with tempfile.TemporaryDirectory(prefix="ppomi-phone-input-", dir="/tmp") as temporary:
    root = Path(temporary)
    swift = root / "main.swift"
    binary = root / "checks"
    swift.write_text(find_window_harness)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    swift.write_text(harness)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    for mode in ("reject-resize", "reject-id", "reject-missing"):
        result = subprocess.run([str(binary), mode], capture_output=True, text=True)
        assert result.returncode == 23, (mode, result.returncode, result.stderr)
        assert "read windows_screen again" in result.stderr, (mode, result.stderr)
    print("3 changed-window rejection checks passed; no real windows or input were accessed")
