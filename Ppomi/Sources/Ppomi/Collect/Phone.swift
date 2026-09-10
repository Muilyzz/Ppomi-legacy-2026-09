// The mirrored iPhone as the collector sees it: the `phone` CLI (phone.swift next to data/) does the window, capture, OCR,
// tap, key and type; this file calls it and keeps the frames. Ported from am.py (phone, screen, find, tap).
import Foundation

enum Phone {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Repo root: data/ledger.db → ../ . The CLI and its source live there.
    static var root: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().deletingLastPathComponent() }
    static var shots: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().appendingPathComponent("shots") }

    /// Run `phone args…`; stdout. The packaged app carries `phone` next to its executable (scripts/make-app.sh); otherwise the
    /// repo's binary, rebuilt when phone.swift is newer, like am.py does.
    @discardableResult
    static func run(_ args: [String], check: Bool = true, windows: Bool = false, stdin: Data? = nil) throws -> String {
        let phonePrivateDigits = args.first == "type-phone-digits-private"
        let phonePrivateKeys = args.first == "type-phone-keys-private"
        let privateDigits = args.first == "type-digits-private" || phonePrivateDigits
        let privateInput = args.first == "type-private" || privateDigits || phonePrivateKeys
        if privateInput {
            guard ((phonePrivateDigits || phonePrivateKeys) ? !windows : windows), args.count == 1, let stdin, !stdin.isEmpty, stdin.count <= 2_000,
                  let text = String(data: stdin, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) }) else {
                throw Failure(description: "phone: invalid private input")
            }
            if privateDigits {
                guard stdin.count <= 10, stdin.allSatisfy({ (48...57).contains($0) }) else {
                    throw Failure(description: "phone: invalid private input")
                }
            }
            if phonePrivateKeys {
                guard stdin.count <= 400, stdin.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                    throw Failure(description: "phone: invalid private input")
                }
            }
        }
        var bin = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent().appendingPathComponent("phone")
        if FileManager.default.fileExists(atPath: bin.path) {
            // Inside the app bundle the helper's keyboard events are silently dropped (TCC attributes it to the app and refuses
            // PostEvent while clicks still pass); the identical signed binary posts keys from outside the bundle, so it runs from
            // Application Support, refreshed whenever the bundled copy is newer.
            if let copy = try? helperOutsideBundle(bin) { bin = copy }
        } else {
            bin = root.appendingPathComponent("phone"); let src = root.appendingPathComponent("phone.swift")
            let m = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
            if !FileManager.default.fileExists(atPath: bin.path) || m(bin) < m(src) {
                _ = try process("/usr/bin/swiftc", ["-O", src.path, "-o", bin.path])
            }
        }
        do {
            var (out, err, code) = try process(bin.path, (windows ? ["--windows"] : []) + args, stdin: stdin)
            // A Windows window parked in a Stage Manager strip or another Space is invisible to the helper until its app is
            // activated; do that once and retry, instead of telling the model the window is gone.
            if windows, code != 0, !privateInput, args.first != "activate", err.contains("no Parallels Windows window") {
                _ = try? process(bin.path, ["--windows", "activate", "com.parallels.desktop.appstore"])
                Thread.sleep(forTimeInterval: 1.5)
                (out, err, code) = try process(bin.path, ["--windows"] + args, stdin: stdin)
            }
            if (check || privateInput), code != 0 {
                throw Failure(description: privateInput ? "phone: private input failed" : "phone \(args.first ?? ""): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return privateInput ? "" : out
        } catch {
            if privateInput { throw Failure(description: "phone: private input failed") }
            throw error
        }
    }

    private static func helperOutsideBundle(_ bundled: URL) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Ppomi", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("phone")
        let m = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        if !fm.fileExists(atPath: copy.path) || m(copy) < m(bundled) {
            if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
            try fm.copyItem(at: bundled, to: copy)
        }
        return copy
    }

    private static func process(_ path: String, _ args: [String], stdin: Data? = nil) throws -> (String, String, Int32) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        let input = stdin.map { _ in Pipe() }
        if let input { p.standardInput = input }
        defer { try? input?.fileHandleForWriting.close() }
        try p.run()
        if let stdin, let input {
            do { try input.fileHandleForWriting.write(contentsOf: stdin) }
            catch {
                try? input.fileHandleForWriting.close()
                p.waitUntilExit()
                throw Failure(description: "phone: stdin delivery failed")
            }
            try input.fileHandleForWriting.close()             // EOF: private input must never fall back to inherited stdin
        }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (out, err, p.terminationStatus)
    }

    /// Capture the mirroring window and OCR it. The PNG is kept a week for debugging, the OCR (.jsonl) for good: a better
    /// parser can rerun old runs (see am.py reparse / Stitch.loadFrames).
    static func screen(windows: Bool = false) throws -> (png: URL, words: [OCR.Word]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: shots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "png" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < Date(timeIntervalSinceNow: -7 * 86400) {
                try? fm.removeItem(at: f)
            }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let png = shots.appendingPathComponent(f.string(from: Date()) + (windows ? "-win.png" : ".png"))
        try run(["capture", png.path], windows: windows)
        let ocr = try run(["ocr", png.path], windows: windows)
        try ocr.write(to: png.deletingPathExtension().appendingPathExtension("jsonl"), atomically: true, encoding: .utf8)
        let dec = JSONDecoder()
        return (png, ocr.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(OCR.Word.self, from: Data($0.utf8)) })
    }

    /// Read a sensitive form in a disposable directory. No shots, JSONL, or image URL leaves this method.
    static func privateScreen(windows: Bool = false,
                              enrich: (([OCR.Word], URL) throws -> [OCR.Word])? = nil) throws -> [OCR.Word] {
        do {
            return try withPrivateCapture(windows: windows) { png in
                let words = try privateWords(png: png, windows: windows)
                // Form-specific pixel evidence is read while the restricted temporary capture is alive.
                return try enrich?(words, png) ?? words
            }
        } catch { throw Failure(description: "phone: private screen unavailable") }
    }

    static func privateInputFocus(x: Double, y: Double, windows: Bool = false,
                                  enrich: (([OCR.Word], URL) throws -> [OCR.Word])? = nil,
                                  focusMinimums: (width: Double, height: Double) = (0.05, 0.025),
                                  validate: ([OCR.Word]) throws -> Void = { _ in }) throws -> Bool {
        do {
            return try withPrivateCapture(windows: windows) { png in
                let words = try privateWords(png: png, windows: windows)
                try validate(enrich?(words, png) ?? words)
                return try InputFocusEvidence.focused(png: png, x: x, y: y, minimums: focusMinimums)
            }
        } catch { throw Failure(description: "phone: private input focus unavailable") }
    }

    private static func privateWords(png: URL, windows: Bool) throws -> [OCR.Word] {
        let ocr = try run(["ocr", png.path], windows: windows)
        let decoder = JSONDecoder()
        return try ocr.split(whereSeparator: \.isNewline).map { try decoder.decode(OCR.Word.self, from: Data($0.utf8)) }
    }

    private static func withPrivateCapture<T>(windows: Bool, _ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("ppomi-private-screen-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }              // also runs after capture, OCR, or decoding failure
        let png = directory.appendingPathComponent("screen.png")
        try run(["capture-private", png.path], windows: windows)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: png.path)
        let value = try body(png)
        try fm.removeItem(at: directory)                        // do not report success if cleanup failed
        return value
    }

    /// Recover the native mirroring overlay once, then verify the stream. No phone screenshots
    /// or OCR archives are needed, and a phone-app button is never a recovery target.
    /// Current iPhone Mirroring often has no AX Home/Switcher buttons while the phone UI is live;
    /// the CLI overlay-text state still reports CONNECTED then. Unlock and in-use overlays stay blocked.
    @discardableResult
    static func wake(tries: Int = 6) throws -> [OCR.Word] {
        let snapshot = Mirroring.recoverOnce(polls: tries)
        let cli = (try? run(["state"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if acceptsStream(snapshot, cliState: cli) { return [] }
        try requireConnected(snapshot)
        return []
    }

    static func acceptsStream(_ snapshot: Mirroring.ConnectionSnapshot, cliState: String) -> Bool {
        if snapshot.connected { return true }
        if snapshot.needsUnlock || snapshot.inUse { return false }
        return cliState.trimmingCharacters(in: .whitespacesAndNewlines) == "CONNECTED"
    }

    static func requireConnected(_ snapshot: Mirroring.ConnectionSnapshot) throws {
        guard !snapshot.connected else { return }
        if snapshot.needsUnlock {
            throw Failure(description: "미러링 앱이 ‘iPhone 잠금 해제’를 요청하고 있습니다. iPhone에서 연결 인증을 완료한 뒤 다시 잠가 주세요.")
        }
        if snapshot.inUse {
            throw Failure(description: "미러링 앱이 ‘iPhone 사용 중’ 상태를 표시하고 연결된 화면은 확인되지 않습니다. 휴대폰 사용을 마친 뒤 잠가야 계속할 수 있습니다.")
        }
        if snapshot.state == .none {
            throw Failure(description: "iPhone 미러링 창을 확인하지 못했습니다. 앱의 현재 창 상태를 확인해야 합니다.")
        }
        throw Failure(description: "미러링 연결 완료를 아직 확인하지 못했습니다. 재연결 버튼을 반복해서 누르지 않고 멈췄습니다. 앱의 최신 연결 상태를 다시 확인해야 합니다.")
    }

    /// Mirroring's authentication overlay is not an interactive phone screen.
    static func needsUnlock(_ words: [OCR.Word]) -> Bool {
        words.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "iPhone 잠금 해제" }
    }

    // ---------------------------------------------------------------- typing
    // The mirror forwards key codes, so Hangul is typed as the 두벌식 keys that compose it ("여기어때" → "durldjEo").
    private static let cho = ["r","R","s","e","E","f","a","q","Q","t","T","d","w","W","c","z","x","v","g"]
    private static let jung = ["k","o","i","O","j","p","u","P","h","hk","ho","hl","y","n","nj","np","nl","b","m","ml","l"]
    private static let jong = ["","r","R","rt","s","sw","sg","e","f","fr","fa","fq","ft","fx","fv","fg","a","q","qt","t","T","d","w","c","z","x","v","g"]

    /// 두벌식 key letters for one Hangul syllable; nil for anything else.
    static func keys(forSyllable c: Character) -> String? {
        guard let u = c.unicodeScalars.first?.value, u >= 0xAC00, u <= 0xD7A3 else { return nil }
        let i = Int(u - 0xAC00)
        return cho[i / 588] + jung[(i % 588) / 28] + jong[i % 28]
    }
    static func keys(for text: String) -> String { text.map { keys(forSyllable: $0) ?? String($0) }.joined() }

    /// Type any text: Hangul runs through the Korean input source as 두벌식 keys, the rest as ASCII.
    static func type(_ text: String) throws {
        var run = "", korean = false
        func flush() throws { if !run.isEmpty { try Phone.run([korean ? "typeko" : "type", run]); run = "" } }
        for ch in text {
            let isKo = keys(forSyllable: ch) != nil
            if isKo != korean { try flush(); korean = isKo }
            run += isKo ? keys(forSyllable: ch)! : String(ch)
        }
        try flush()
    }

    static func find(_ words: [OCR.Word], _ pattern: String) -> OCR.Word? {
        let re = Re(pattern)
        return words.first { re.search($0.text) != nil }
    }
    static func tap(_ w: OCR.Word) throws { try tap(w.x + w.w / 2, w.y + w.h / 2) }
    static func tap(_ x: Double, _ y: Double) throws { try run(["tap", "\(x)", "\(y)"]) }
    static func key(_ name: String, check: Bool = true) throws { try run(["key", name], check: check) }
    static func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }
}

/// The Parallels Windows window, driven by the same CLI with `--windows`: capture/OCR/click like the phone, wheel notches
/// for scrolling, clipboard paste for typing (Hangul intact whatever the guest IME does), Win+R to open a URL or program.
/// States: READY (a VM window in window mode) | NONE. No pause/lock overlay exists, so there is nothing to wake.
enum Desk {
    static func state() throws -> String { try Phone.run(["state"], windows: true).trimmingCharacters(in: .whitespacesAndNewlines) }
    static func screen() throws -> (png: URL, words: [OCR.Word]) { try Phone.screen(windows: true) }
    static func privateScreen(enrich: (([OCR.Word], URL) throws -> [OCR.Word])? = nil) throws -> [OCR.Word] {
        try Phone.privateScreen(windows: true, enrich: enrich)
    }
    static func privateInputFocus(x: Double, y: Double,
                                 enrich: (([OCR.Word], URL) throws -> [OCR.Word])? = nil,
                                 focusMinimums: (width: Double, height: Double) = (0.05, 0.025),
                                 validate: ([OCR.Word]) throws -> Void = { _ in }) throws -> Bool {
        try Phone.privateInputFocus(x: x, y: y, windows: true, enrich: enrich, focusMinimums: focusMinimums, validate: validate)
    }
    static func click(_ w: OCR.Word) throws { try click(w.x + w.w / 2, w.y + w.h / 2) }
    static func click(_ x: Double, _ y: Double) throws { try Phone.run(["tap", "\(x)", "\(y)"], windows: true) }
    /// "enter", "escape", "tab", "ctrl+l", "alt+f4", "win+r", "f5", a single character.
    static func key(_ name: String) throws { try Phone.run(["key", name], windows: true) }
    static func type(_ text: String) throws { try Phone.run(["type", text], windows: true) }
    /// Basic identity text travels through stdin only; the helper conditionally restores the previous Mac clipboard.
    static func typePrivate(_ text: String) throws { try Phone.run(["type-private"], windows: true, stdin: Data(text.utf8)) }
    /// Replace one verified numeric field, at most 10 ASCII digits, without clipboard or modifier shortcuts.
    static func typeDigitsPrivate(_ digits: String) throws { try Phone.run(["type-digits-private"], windows: true, stdin: Data(digits.utf8)) }
    static func scroll(_ dy: Int, x: Double = 0.5, y: Double = 0.5) throws { try Phone.run(["scroll", "\(dy)", "\(x)", "\(y)"], windows: true) }
    /// A URL opens in the guest's default browser (a new tab), a program name runs it.
    static func open(_ target: String) throws { try Phone.run(["open", target], windows: true) }
}
