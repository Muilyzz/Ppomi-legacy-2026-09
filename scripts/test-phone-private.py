#!/usr/bin/env python3
"""Exercise private helpers in a disposable home with synthetic files and a named test clipboard."""
from pathlib import Path
import os
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
helper = (root / "phone.swift").read_text()
collector = (root / "Ppomi/Sources/Ppomi/Collect/Phone.swift").read_text()


def declaration(source, start):
    body = source[source.index(start):]
    return body[:body.index("\n}\n") + 3]


clipboard_harness = "import AppKit\nimport Foundation\n"
clipboard_harness += "var privateInputCleanup: (() -> Void)?\n"
clipboard_harness += declaration(helper, "func fail(_ msg: String)")
clipboard_harness += declaration(helper, "enum PrivateTextInput {")
clipboard_harness += declaration(helper, "final class PrivateClipboard {")
clipboard_harness += r'''
if CommandLine.arguments.contains("read") {
    let value = PrivateTextInput.read()
    print(value.utf8.count)
    exit(0)
}
if CommandLine.arguments.contains("fail-cleanup") {
    privateInputCleanup = { print("cleanup ran") }
    fail("fixed failure")
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
let pb = NSPasteboard(name: .init("org.muilyzz.ppomi.private-input-tests." + UUID().uuidString))
defer { pb.releaseGlobally() }
let custom = NSPasteboard.PasteboardType("org.muilyzz.ppomi.synthetic-test-data")
let first = NSPasteboardItem(), second = NSPasteboardItem()
first.setString("original one", forType: .string)
first.setData(Data([0, 255, 17]), forType: custom)
second.setString("original two", forType: .string)
pb.clearContents(); check(pb.writeObjects([first, second]), "seed isolated clipboard")
let saved = try PrivateClipboard(pb)
try saved.install("synthetic private value")
check(pb.string(forType: .string) == "synthetic private value" && saved.isCurrent, "private text installed and owned")
saved.restoreIfUnchanged()
check(pb.pasteboardItems?.count == 2, "all item boundaries restored")
check(pb.pasteboardItems?[0].data(forType: custom) == Data([0, 255, 17]), "non-text data restored")
check(pb.pasteboardItems?[0].string(forType: .string) == "original one", "first text restored")
check(pb.pasteboardItems?[1].string(forType: .string) == "original two", "second text restored")

let changed = try PrivateClipboard(pb)
try changed.install("synthetic private value")
pb.clearContents(); pb.setString("new user copy", forType: .string)
check(!changed.isCurrent, "new user copy prevents private paste")
changed.restoreIfUnchanged()
check(pb.string(forType: .string) == "new user copy", "new user clipboard preserved")

let sameText = try PrivateClipboard(pb)
try sameText.install("synthetic private value")
pb.clearContents(); pb.setString("synthetic private value", forType: .string)
sameText.restoreIfUnchanged()
check(pb.string(forType: .string) == "synthetic private value", "new copy of same text preserved by generation")

pb.clearContents()
let empty = try PrivateClipboard(pb)
try empty.install("synthetic private value")
empty.restoreIfUnchanged()
check((pb.pasteboardItems ?? []).isEmpty, "empty clipboard restored")

let stale = try PrivateClipboard(pb)
pb.clearContents(); pb.setString("later user copy", forType: .string)
do { try stale.install("must not be installed"); fatalError("stale snapshot accepted") }
catch PrivateClipboard.Failure.changed { checks += 1 }
check(pb.string(forType: .string) == "later user copy", "snapshot race does not overwrite user copy")
print("\(checks) isolated clipboard checks passed")
'''

digits_harness = "import Foundation\nimport Darwin\ntypealias CGKeyCode = UInt16\n"
digits_harness += "var privateInputCleanup: (() -> Void)?\n"
digits_harness += declaration(helper, "func fail(_ msg: String)")
digits_harness += declaration(helper, "enum PrivateTextInput {")
digits_harness += declaration(helper, "enum PrivateDigitsInput {")
digits_harness += declaration(helper, "enum PhonePrivateDigitsInput {")
digits_harness += r'''
// Stubs deliberately have no clipboard, AX, keyboard-layout mutation or system-event API.
var windowsTarget = true
var activationCount = 0
func activate() { activationCount += 1 }
func selectABC() -> Bool { true }
func TISCopyCurrentKeyboardInputSource() -> Unmanaged<NSString>? { nil }
func TISSelectInputSource(_ value: NSString) {}
final class CGEvent {
    let code: CGKeyCode, down: Bool
    var flags: Set<String> = ["synthetic inherited modifier"]
    init?(keyboardEventSource: AnyObject?, virtualKey: CGKeyCode, keyDown: Bool) { code = virtualKey; down = keyDown }
}
var events: [CGEvent] = []
func post(_ event: CGEvent?) { events.append(event!) }
'''
digits_harness += declaration(helper, "func typeDigitsPrivate(_ text: String)")
digits_harness += declaration(helper, "func typePhoneDigitsPrivate(_ text: String)")
digits_harness += r'''
if CommandLine.arguments.contains("read") {
    let value = PrivateDigitsInput.read()
    print(value.utf8.count)
    exit(0)
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
let physicalDigits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
let plan = PrivateDigitsInput.keyPlan("0123456789")!
check(plan == [115] + Array(repeating: 117, count: 10) + physicalDigits, "Home and bounded Delete precede physical digit keys")
check(PrivateDigitsInput.keyPlan("0") == [115] + Array(repeating: 117, count: 10) + [29], "single digit and leading zero preserved")
for invalid in ["", "12345678901", "12-34", "123 45", "１２３", "١٢٣", "123\n", "123\0", "synthetic"] {
    check(PrivateDigitsInput.keyPlan(invalid) == nil, "invalid numeric payload rejected before events")
}
typeDigitsPrivate("0123456789")
check(activationCount == 1, "numeric sequence activates once")
check(events.count == plan.count * 2, "one down/up pair per planned key")
check(events.allSatisfy { $0.flags.isEmpty }, "no modifier flags are forwarded")
for (index, code) in plan.enumerated() {
    check(events[index * 2].code == code && events[index * 2].down &&
          events[index * 2 + 1].code == code && !events[index * 2 + 1].down, "planned keys are paired in order")
}
windowsTarget = false
activationCount = 0; events = []
check(PhonePrivateDigitsInput.keyPlan("0123456789") == physicalDigits, "phone sends digits only without erase keys")
for invalid in ["", "12345678901", "12-34", "12 34", "１２３", "١٢٣", "12\n", "12\0"] {
    check(PhonePrivateDigitsInput.keyPlan(invalid) == nil, "phone rejects invalid numeric payload")
}
typePhoneDigitsPrivate("00123")
check(activationCount == 1 && events.count == 10, "phone emits only five digit pairs")
check(events.allSatisfy { $0.flags.isEmpty && physicalDigits.contains($0.code) }, "phone never sends modifiers or deletion")
print("\(checks) private digit plan and synthetic key-event checks passed")
'''

phone_harness = r'''
import Foundation
enum AppSettings {
    static let dbPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PPOMI_PRIVATE_TEST_ROOT"]!)
        .appendingPathComponent("unused/data/ledger.db").path
}
enum OCR {
    struct Word: Decodable { let x: Double; let y: Double; let w: Double; let h: Double; let conf: Double; let text: String; let source: String? }
}
struct Re { init(_ value: String) {} ; func search(_ value: String) -> Bool? { nil } }
enum MirrorState { case connected, disconnected, paused, inUse, none }
enum Mirroring {
    struct ConnectionSnapshot {
        let state: MirrorState
        let connected: Bool
        let inUse: Bool
        let needsUnlock: Bool
    }
    static func recoverOnce(polls: Int) -> ConnectionSnapshot {
        fatalError("private helper tests must never inspect or recover an actual mirroring window")
    }
}
enum InputFocusEvidence {
    enum Failure: Error { case synthetic }
    static var expectedPNG: String?
    static var calls = 0
    static func focused(png: URL, x: Double, y: Double) throws -> Bool {
        calls += 1
        if let expectedPNG { precondition(expectedPNG == png.path, "OCR validation and focus must use the same image") }
        let fm = FileManager.default
        let fileMode = try fm.attributesOfItem(atPath: png.path)[.posixPermissions] as? NSNumber
        let directoryMode = try fm.attributesOfItem(atPath: png.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        precondition(fileMode?.intValue == 0o600 && directoryMode?.intValue == 0o700)
        if y == 1 { throw Failure.synthetic }
        return x > 0
    }
}
'''
phone_harness += collector
phone_harness += r'''
// Fail before Phone can copy or execute a helper if Foundation ignores the isolated home.
let testEnvironment = ProcessInfo.processInfo.environment
guard let testRootPath = testEnvironment["PPOMI_PRIVATE_TEST_ROOT"],
      let testHomePath = testEnvironment["CFFIXED_USER_HOME"],
      let modePath = testEnvironment["PPOMI_PRIVATE_TEST_MODE"] else { fatalError("missing test isolation") }
let testRoot = URL(fileURLWithPath: testRootPath).standardizedFileURL.resolvingSymlinksInPath()
func insideTestRoot(_ url: URL) -> Bool {
    url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(testRoot.path + "/")
}
let testSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false)
let expectedSupport = URL(fileURLWithPath: testHomePath).appendingPathComponent("Library/Application Support")
let modeURL = URL(fileURLWithPath: modePath)
precondition(insideTestRoot(testSupport) &&
             testSupport.standardizedFileURL.resolvingSymlinksInPath().path == expectedSupport.standardizedFileURL.resolvingSymlinksInPath().path,
             "Foundation Application Support must use the disposable test home")
precondition(insideTestRoot(modeURL), "helper mode must stay in the disposable test root")
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func rejected(_ body: () throws -> Void) {
    do { try body(); fatalError("invalid input accepted") }
    catch { check(!String(describing: error).contains("synthetic"), "private failure is redacted") }
}
try Desk.typePrivate("synthetic 한글 0123")
checks += 1
let output = try Phone.run(["type-private"], windows: true, stdin: Data("synthetic 한글 0123".utf8))
check(output.isEmpty, "private helper stdout suppressed")
try Desk.typeDigitsPrivate("0123456789")
checks += 1
let numericOutput = try Phone.run(["type-digits-private"], windows: true, stdin: Data("0123456789".utf8))
check(numericOutput.isEmpty, "numeric helper stdout suppressed")
rejected { try Phone.run(["type-digits-private"], windows: true) }
rejected { try Phone.run(["type-digits-private", "0123456789"], windows: true, stdin: Data("0123456789".utf8)) }
rejected { try Phone.run(["type-digits-private"], stdin: Data("0123456789".utf8)) }
let phoneOutput = try Phone.run(["type-phone-digits-private"], stdin: Data("0123456789".utf8))
check(phoneOutput.isEmpty, "phone numeric helper stdout suppressed")
rejected { try Phone.run(["type-phone-digits-private"], windows: true, stdin: Data("0123456789".utf8)) }
rejected { try Phone.run(["type-phone-digits-private", "0123456789"], stdin: Data("0123456789".utf8)) }
rejected { try Phone.run(["type-phone-digits-private"]) }
for invalid in ["", "12345678901", "12-34", "12 34", "１２３", "١٢٣", "12\n", "12\0"] {
    rejected { try Phone.run(["type-phone-digits-private"], stdin: Data(invalid.utf8)) }
}

for text in ["", "12345678901", "12-34", "123 45", "１２３", "١٢٣", "synthetic\n", "123\0"] {
    rejected { try Desk.typeDigitsPrivate(text) }
}
rejected { try Phone.run(["type-private"], windows: true) }
rejected { try Phone.run(["type-private", "synthetic"], windows: true, stdin: Data("synthetic".utf8)) }
rejected { try Phone.run(["type-private"], stdin: Data("synthetic".utf8)) }
for text in ["", "synthetic\n", "synthetic\r", "synthetic\u{2028}", "synthetic\0", String(repeating: "가", count: 667)] {
    rejected { try Desk.typePrivate(text) }
}
let words = try Desk.privateScreen()
check(words.count == 1 && words[0].text == "synthetic label", "OCR returned only in-memory words")
let focused = try Desk.privateInputFocus(x: 0.1, y: 0.1)
let unfocused = try Desk.privateInputFocus(x: 0, y: 0.1)
check(focused && !unfocused, "focus result returns only boolean through private capture")
rejected { _ = try Desk.privateInputFocus(x: 0.1, y: 1) }
let validated = try Desk.privateInputFocus(x: 0.1, y: 0.1) { words in
    check(words.first?.text == "synthetic label", "validation receives private OCR words")
    InputFocusEvidence.expectedPNG = words.first?.source
}
check(validated && InputFocusEvidence.expectedPNG != nil, "validation and focus share capture")
InputFocusEvidence.expectedPNG = nil
let callsBefore = InputFocusEvidence.calls
rejected { _ = try Desk.privateInputFocus(x: 0.1, y: 0.1) { _ in throw InputFocusEvidence.Failure.synthetic } }
check(InputFocusEvidence.calls == callsBefore, "validation failure blocks focus evaluation")
for mode in ["capture-failure", "ocr-failure", "decode-failure", "private-failure"] {
    try mode.write(to: modeURL, atomically: true, encoding: .utf8)
    if mode == "private-failure" {
        rejected { try Desk.typePrivate("synthetic 한글 0123") }
        rejected { try Phone.run(["type-private"], check: false, windows: true, stdin: Data("synthetic 한글 0123".utf8)) }
        rejected { try Desk.typeDigitsPrivate("0123456789") }
        rejected { try Phone.run(["type-digits-private"], check: false, windows: true, stdin: Data("0123456789".utf8)) }
        rejected { try Phone.run(["type-phone-digits-private"], check: false, stdin: Data("0123456789".utf8)) }
    } else {
        rejected { _ = try Desk.privateScreen() }
        if mode == "capture-failure" { rejected { _ = try Desk.privateInputFocus(x: 0.1, y: 0.1) } }
    }
}
// macOS may choose its own temporary directory. Check only this fixture's UUID captures,
// without enumerating or comparing other processes' temporary files.
let capturePaths = try String(contentsOf: testRoot.appendingPathComponent("capture-paths.jsonl"), encoding: .utf8)
    .split(whereSeparator: \.isNewline)
    .map { URL(fileURLWithPath: try JSONDecoder().decode(String.self, from: Data($0.utf8))) }
check(!capturePaths.isEmpty && capturePaths.allSatisfy {
    !FileManager.default.fileExists(atPath: $0.path) &&
        !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path)
}, "this test's private captures and directories were cleaned after every outcome")
print("\(checks) stdin/redaction/private capture checks passed")
'''

# Run the actual private-capture command dispatch with a harmless capture stub, so file creation honors umask.
private_capture_case = helper[helper.index('case "capture-private":'):helper.index('case "ocr": ocr(args[1])')]
capture_harness = "import Foundation\nimport Darwin\n"
capture_harness += declaration(helper, "func fail(_ msg: String)").replace("    let cleanup = privateInputCleanup; privateInputCleanup = nil; cleanup?()\n", "")
capture_harness += r'''
let args = ["capture-private", CommandLine.arguments[1]]
func capture(to path: String) {
    let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o666)
    precondition(fd >= 0)
    close(fd)
    let mode = try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600, "PNG must be private at initial creation, before chmod")
}
switch args[0] {
'''
capture_harness += private_capture_case + 'default: fatalError("unexpected command")\n}\n'

fake_phone = r'''#!/usr/bin/python3
import json, os, pathlib, stat, sys
test_root = pathlib.Path(os.environ["PPOMI_PRIVATE_TEST_ROOT"]).resolve()
helper_path = pathlib.Path(__file__).resolve()
mode_path = pathlib.Path(os.environ["PPOMI_PRIVATE_TEST_MODE"]).resolve()
assert test_root in helper_path.parents and test_root in mode_path.parents, "fixture paths must stay isolated"
(test_root / "executed-helper.txt").write_text(str(helper_path))
mode = mode_path.read_text() if mode_path.exists() else ""
assert sys.argv[1] in ["--windows", "type-phone-digits-private"]
verb = sys.argv[2] if sys.argv[1] == "--windows" else sys.argv[1]
if verb == "type-private":
    assert sys.argv[1:] == ["--windows", "type-private"], "value must not travel in args"
    assert sys.stdin.buffer.read() == "synthetic 한글 0123".encode()
    if mode == "private-failure":
        print("synthetic private output")
        print("synthetic private error", file=sys.stderr)
        sys.exit(1)
    print("synthetic output that must not escape private run")
elif verb == "type-digits-private":
    assert sys.argv[1:] == ["--windows", "type-digits-private"], "numeric value must not travel in args"
    assert sys.stdin.buffer.read() == b"0123456789"
    if mode == "private-failure":
        print("synthetic private numeric output")
        print("synthetic private numeric error", file=sys.stderr)
        sys.exit(1)
    print("synthetic numeric output that must not escape private run")
elif verb == "type-phone-digits-private":
    assert sys.argv[1:] == ["type-phone-digits-private"], "phone value must not travel in args"
    assert sys.stdin.buffer.read() == b"0123456789"
    if mode == "private-failure":
        print("synthetic phone private output")
        print("synthetic phone private error", file=sys.stderr)
        sys.exit(1)
    print("synthetic phone output that must not escape private run")
elif verb == "capture-private":
    path = pathlib.Path(sys.argv[3])
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    with (test_root / "capture-paths.jsonl").open("a") as capture_log:
        capture_log.write(json.dumps(str(path.resolve())) + "\n")
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.write(fd, b"synthetic image"); os.close(fd)
    assert list(path.parent.iterdir()) == [path]
    if mode == "capture-failure":
        print("synthetic capture error", file=sys.stderr); sys.exit(1)
elif verb == "ocr":
    path = pathlib.Path(sys.argv[3])
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert list(path.parent.iterdir()) == [path]
    if mode == "ocr-failure":
        print("synthetic OCR error", file=sys.stderr); sys.exit(1)
    if mode == "decode-failure": print("synthetic invalid OCR")
    else: print(json.dumps(dict(x=.1, y=.2, w=.2, h=.03, conf=.9, text="synthetic label", source=str(path))))
else: raise AssertionError("unexpected helper verb")
'''

with tempfile.TemporaryDirectory(prefix="ppomi-phone-private-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    test_home = temporary / "home"
    test_support = test_home / "Library/Application Support"
    test_tmp = temporary / "tmp"
    module_cache = temporary / "swift-module-cache"
    for path in [test_support, test_tmp, module_cache]:
        path.mkdir(parents=True)
    # Set the child process's Foundation home, leaving the user's HOME and environment unchanged.
    test_env = os.environ.copy()
    test_env.update({
        "CFFIXED_USER_HOME": str(test_home),
        "TMPDIR": str(test_tmp) + "/",
        "PPOMI_PRIVATE_TEST_ROOT": str(temporary),
        "PPOMI_PRIVATE_TEST_MODE": str(temporary / "mode"),
    })
    for name, source in [("clipboard", clipboard_harness), ("digits", digits_harness), ("collector", phone_harness), ("capture", capture_harness)]:
        path = temporary / f"{name}.swift"
        path.write_text(source)
        subprocess.run(["swiftc", str(path), "-module-cache-path", str(module_cache), "-o", str(temporary / name)],
                       env=test_env, check=True, timeout=60)
    fake = temporary / "phone"
    fake.write_text(fake_phone)
    fake.chmod(0o700)
    subprocess.run([str(temporary / "clipboard")], env=test_env, check=True, timeout=15)
    subprocess.run([str(temporary / "digits")], env=test_env, check=True, timeout=5)
    subprocess.run([str(temporary / "collector")], env=test_env, check=True, timeout=30)
    copied_helper = test_support / "Ppomi/phone"
    assert copied_helper.read_bytes() == fake.read_bytes(), "the copied helper must be the isolated fixture"
    assert Path((temporary / "executed-helper.txt").read_text()) == copied_helper.resolve(), "only the isolated helper copy may execute"
    assert (temporary / "mode").read_text() == "private-failure", "all copied-helper failure modes must run"
    subprocess.run([str(temporary / "capture"), str(temporary / "private.png")], env=test_env, check=True, timeout=5)
    for payload, valid in [(b"", False), (b"x" * 2000, True), (b"x" * 2001, False),
                           ("가".encode() * 667, False), (b"synthetic\0", False), (b"synthetic\n", False),
                           ("synthetic\u2028".encode(), False), (b"\xff", False), ("테스트".encode(), True)]:
        result = subprocess.run([str(temporary / "clipboard"), "read"], env=test_env, input=payload, capture_output=True, timeout=5)
        assert (result.returncode == 0) == valid
        assert b"synthetic" not in result.stdout + result.stderr
    result = subprocess.run([str(temporary / "clipboard"), "fail-cleanup"], env=test_env, capture_output=True, timeout=5)
    assert result.returncode == 1 and result.stdout == b"cleanup ran\n"
    numeric_payloads = [(b"0", True), (b"0123456789", True), (b"", False), (b"12345678901", False),
                        (b"12-34", False), (b"123 45", False), ("１２３".encode(), False),
                        ("١٢٣".encode(), False), (b"123\0", False), (b"123\n", False), (b"\xff", False)]
    for payload, valid in numeric_payloads:
        result = subprocess.run([str(temporary / "digits"), "read"], env=test_env, input=payload, capture_output=True, timeout=5)
        assert (result.returncode == 0) == valid
        assert result.stdout == (str(len(payload)).encode() + b"\n" if valid else b"")
        assert b"synthetic" not in result.stdout + result.stderr
    print("9 bounded text and 11 bounded digit stdin cases, fail() cleanup, private file creation, and isolated helper copy passed; no real windows or input events were accessed")
