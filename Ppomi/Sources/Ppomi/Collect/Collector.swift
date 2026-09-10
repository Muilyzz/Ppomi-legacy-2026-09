// Collection: open each bank app on the mirrored phone, read balances (and 카카오's transaction list), store them.
// Ported from am.py (ensure_connected, open_app, to_home, dismiss, read_balances, read_transactions, snapshot, with_phone).
// Credentials stay with the human: a login wall is reported and waited out, never typed.
import Foundation

final class Collector {
    struct Skip: Error, CustomStringConvertible { let description: String }   // one app's failure never kills the run

    // mirroring app's own overlays, matched as whole OCR lines so app text like '잠금' or 'iPhone' can't trip it
    static let overlay = Re(#"^(연결이 (중단됨|일시 정지됨)|iPhone(을| ).*(사용 중|잠금 해제).*)$"#)
    static let login = Re(#"패턴|비밀번호|인증서|간편인증|Face ID|로그인(?! 연장| 시간)"#)   // '로그인 연장' is a session popup, not a login wall
    static let extend = Re("^로그인 연장$")                                                    // KB: idle-timeout popup; tapping keeps the session
    // Popups we close, and the only buttons we may press for each. Money-moving suggestions are closed with X/닫기/아니요 only.
    static let popups = [(Re("이체할까요"), Re(#"^[X×x]$|^닫기$|^아니요$"#)), (Re("로그아웃 되었습니다"), Re(#"^확인$|^[X×x]$"#))]

    let db: DB
    let log: (String) -> Void
    /// Tests replace the complete phone session so a failed interlock cannot move a real window.
    var phoneSessionOverride: ((() -> Void) -> Void)?
    private let loginWait: TimeInterval
    private var deadline = Date.distantFuture, asked = false

    init(dbPath: String = AppSettings.dbPath, log: @escaping (String) -> Void = { print($0) }) throws {
        db = try DB(path: dbPath, writable: true)
        self.log = log
        loginWait = TimeInterval(AppSettings.env("LOGIN_WAIT").flatMap(Int.init) ?? 600)
    }

    private var deadlinePassed: Bool { Date() > deadline }
    private func find(_ w: [OCR.Word], _ re: Re) -> OCR.Word? { w.first { re.search($0.text) != nil } }
    private func find(_ w: [OCR.Word], _ p: String) -> OCR.Word? { Phone.find(w, p) }

    /// Imported selectors may choose a screen element, but cannot authorize a money action.
    /// Inspect the selected OCR text as well as the selector: a broad regex such as "." is not permission.
    static func checkedReadTarget(_ word: OCR.Word) throws -> OCR.Word {
        guard !Footprint.isPayTarget(word.text) else {
            throw Skip(description: "read-only collection blocked a money-action control")
        }
        return word
    }

    /// Only an actual back chevron is navigation. An arbitrary leftmost label may be a payment or transfer.
    static func backTarget(in words: [OCR.Word]) -> OCR.Word? {
        words.first {
            0.09 < $0.y && $0.y < 0.17 && $0.x < 0.3
                && Re(#"^[\^<〈←‹]$"#).match($0.text.trimmingCharacters(in: .whitespaces)) != nil
        }
    }

    // ---------------------------------------------------------------- the run
    /// `snapshot KAKAO KB …`; the API app needs no phone. Every app is tried even when one fails.
    func snapshot(_ keys: [String]) {
        if keys.contains("TOSSINVEST") {
            do { try Toss.collect(db: db, log: log) } catch { log("TOSSINVEST: \(error)") }
        }
        let apps = keys.compactMap(Apps.config)
        guard !apps.isEmpty else { return }
        do {
            let databases = try db.rows("PRAGMA database_list")
            guard let path = databases.first(where: { $0[1] as? String == "main" })?[2] as? String,
                  !path.isEmpty else {
                log("실행 안 함: 화면 제어를 조정할 장부 파일이 없습니다.")
                return
            }
            guard let lease = try ScreenControlLease.beginControl(ledgerPath: path) else {
                log(ScreenControlLease.blockedMessage)
                return
            }
            defer { lease.release() }
            // Direct CLI collection must acquire the same lease before withPhone moves any window.
            withPhone {
                for cfg in apps {
                    do { try collect(cfg) }
                    catch { log("\(cfg.key): \(error)"); if deadlinePassed { break } }
                }
            }
        } catch {
            log("실행 안 함: 화면 제어 잠금을 확인하지 못했습니다. \(error.localizedDescription)")
        }
    }

    private func collect(_ cfg: AppConfig) throws {
        _ = try ensureConnected()
        guard try openApp(cfg) else { return }
        let (_, reconnected) = try ensureConnected()
        if reconnected, try !openApp(cfg) { return }               // the phone came back on its home screen, not in our app
        var (png, words, found) = try readBalances(cfg)
        if found.isEmpty, find(words, Self.login) != nil {
            // Easiest for the human: unlock the phone, open the app, Face ID, lock it again. Mirroring reconnects to the
            // home screen, so we re-open the app and read while the session lives.
            notify("🔐 \(cfg.title) 로그인 필요", "폰에서 \(cfg.title)을 열어 Face ID로 로그인한 뒤 다시 잠가 주세요 (\(Int(loginWait) / 60)분 안에). 미러링 창에서 직접 로그인해도 됩니다.")
            log("\(cfg.key): login screen — waiting for you to log in")
            while found.isEmpty, !deadlinePassed {
                Phone.sleep(10)
                let (w, re) = try ensureConnected()
                if re || (find(w, Self.login) == nil && OCR.balances(w, account: cfg.account).isEmpty) {
                    guard try openApp(cfg) else { continue }      // phone came back on its home screen: bring the app up again
                    (png, words, found) = try readBalances(cfg)
                } else {
                    words = w; found = OCR.balances(w, account: cfg.account)
                }
            }
        }
        guard !found.isEmpty else { log("\(cfg.key): no balance found (login not done? popup?) -> see \(png.lastPathComponent)"); return }
        let ts = TS.string(Date())
        for (acct, bal) in found {
            try db.insertSnapshot(ts: ts, app: cfg.key, account: acct, balance: bal, shot: png.lastPathComponent)
            log("\(cfg.key): \(acct) = \(bal.won)")
        }
        if cfg.tx != nil {
            if cfg.list != nil { _ = try openApp(cfg) }          // we may be on the full-list page; go back to the home first
            try readTransactions(cfg)
        }
    }

    /// Stage Manager pulls the mirror on stage; give the user their app back afterwards.
    private func withPhone(_ body: () -> Void) {
        if let phoneSessionOverride { phoneSessionOverride(body); return }
        let prev = (try? Phone.run(["front"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try? Phone.run(["place"] + (AppSettings.env("MIRROR_AT") ?? "center").split(separator: ",").map(String.init))   // the kiosk's spot
        deadline = Date(timeIntervalSinceNow: loginWait); asked = false
        body()
        try? Phone.key("home", check: false)                       // never leave a banking app open in the mirror
        if !prev.isEmpty, prev != "com.apple.ScreenContinuity" { _ = try? Phone.run(["activate", prev], check: false) }
    }

    // ---------------------------------------------------------------- the phone
    /// Mirroring drops often ('연결이 중단됨' → 다시 시도) or pauses when idle ('연결이 일시 정지됨' → 재개); click through.
    /// An empty OCR result is the grey 'connecting' frame, not a success. Returns (words, reconnected).
    func ensureConnected(tries: Int = 4) throws -> ([OCR.Word], Bool) {
        var tries = tries, reconnected = false
        while true {
            let (png, words) = try Phone.screen()
            if let b = find(words, #"^(다시 시도|재개)$"#) { try Phone.tap(b); reconnected = true }
            else if !words.isEmpty, find(words, Self.login) != nil || find(words, Self.overlay) == nil { return (words, reconnected) }
            tries -= 1
            if tries <= 0, !asked {                                // phone in use / away: tell the human once, then keep trying
                asked = true; notify("미러링 끊김", "아이폰을 잠그고 Mac 옆에 두면 이어서 수집합니다")
            }
            if tries <= 0, deadlinePassed { throw Skip(description: "mirroring not ready — is the iPhone locked, nearby, recently unlocked, not in use? see \(png.lastPathComponent)") }
            Phone.sleep(tries > 0 ? 7 : 15)
        }
    }

    /// Bring an app to the front of the mirrored phone. False (no throw) when it can't, so a run continues with the next app.
    func openApp(_ cfg: AppConfig, retry: Bool = true) throws -> Bool {
        let dropped = { (w: [OCR.Word]) in w.isEmpty || self.find(w, #"^(다시 시도|재개)$"#) != nil }
        try Phone.key("home"); Phone.sleep(1)
        if let label = cfg.homeLabel {
            for _ in 0..<2 {                                       // a second Home press returns to page 1
                let (_, words) = try Phone.screen()
                if let l = find(words, "^" + NSRegularExpression.escapedPattern(for: label) + "$") {
                    try Phone.tap(l.x + l.w / 2, l.y - 0.045)      // the icon sits above its label
                    Phone.sleep(7); return true
                }
                try Phone.key("home"); Phone.sleep(1)
            }
        }
        try Phone.key("spotlight"); Phone.sleep(1.2)
        try Phone.type(cfg.search); Phone.sleep(2)
        let (png, words) = try Phone.screen()
        let hit = find(words, NSRegularExpression.escapedPattern(for: cfg.title))
        if hit == nil, dropped(words), retry { _ = try ensureConnected(); return try openApp(cfg, retry: false) }   // connection fell over while typing
        guard let hit else {                                       // never press Return blindly: it opens whatever Spotlight suggests
            try Phone.key("escape"); try Phone.key("home")
            log("Spotlight did not show \(cfg.title) for '\(cfg.search)' -> see \(png.lastPathComponent)"); return false
        }
        // Spotlight's field autocompletes the top hit ("kb스타뱅킹 — 열기"): Return opens it. Else the top-hit grid puts the
        // icon above the label; an '앱' list row is tappable as a whole.
        if words.contains(where: { $0.y > 0.85 && $0.text.lowercased().contains(cfg.title.lowercased()) }) {
            try Phone.key("return")
        } else if let h = find(words, "연관성 높은 항목"), hit.y - h.y > 0, hit.y - h.y < 0.1 {
            try Phone.tap(hit.x + min(hit.w, 0.25) / 2, hit.y - 0.06)
        } else {
            try Phone.tap(hit)
        }
        Phone.sleep(7)
        return try toHome(cfg)
    }

    /// iOS resumes an app where it was left; if this app isn't on its home screen, tap the top-left back control.
    private func toHome(_ cfg: AppConfig) throws -> Bool {
        guard let home = cfg.home else { return true }
        for _ in 0..<3 {
            let (_, words) = try Phone.screen()
            if find(words, home) != nil || find(words, Self.login) != nil { return true }
            guard let chevron = Self.backTarget(in: words) else { break }
            try Phone.tap(Self.checkedReadTarget(chevron)); Phone.sleep(2)
        }
        return true
    }

    /// Close a known popup with its safe button; the refreshed screen, or nil if nothing to do.
    private func dismiss(_ words: [OCR.Word]) throws -> (URL, [OCR.Word])? {
        for (text, buttons) in Self.popups where find(words, text) != nil {
            if let b = words.first(where: { buttons.match($0.text.trimmingCharacters(in: .whitespaces)) != nil }) {
                try Phone.tap(b); Phone.sleep(1.5); return try Phone.screen()
            }
        }
        return nil
    }

    /// Home screen (expanded) first; the full list page wins when it yields more accounts.
    private func readBalances(_ cfg: AppConfig) throws -> (URL, [OCR.Word], [(String, Int)]) {
        var (png, words) = try Phone.screen()
        if let r = try dismiss(words) { (png, words) = r }
        if let b = find(words, Self.extend) { try Phone.tap(b); Phone.sleep(1.5); (png, words) = try Phone.screen() }   // keep the idle session
        if let e = cfg.expand, let more = find(words, e) { try Phone.tap(Self.checkedReadTarget(more)); Phone.sleep(1.5); (png, words) = try Phone.screen() }
        var found = OCR.balances(words, account: cfg.account)
        if let l = cfg.list, let ctl = find(words, l) {           // the full account list, unless it bounced to a login screen
            try Phone.tap(Self.checkedReadTarget(ctl)); Phone.sleep(3)
            let (p2, w2) = try Phone.screen()
            if find(w2, Self.login) == nil {
                let more = OCR.balances(w2, account: cfg.account)
                if more.count >= found.count { (png, words, found) = (p2, w2, more) }
            }
        }
        return (png, words, found)
    }

    /// From the app's home: tap the account row, then read the list page by page (scrolling ~half a window so pages
    /// overlap) back TX_DAYS days. Rows accumulate across pages before parsing (see OCR.transactions).
    private func readTransactions(_ cfg: AppConfig) throws {
        var (_, words) = try Phone.screen()
        if let r = try dismiss(words) { words = r.1 }
        if find(words, cfg.txpage ?? #"^\d{1,2}:\d{2}\s+#"#) == nil {   // not already on a transaction list
            // the account row on the home; never the nav title (y<0.2) and never a row that is a bare number. Tap its name end:
            // a tap on the account number copies it and the app then offers a transfer
            guard let row = words.first(where: { Re(cfg.tx!).search($0.text) != nil && $0.y > 0.2 && Re(#"^\W*\d"#).match($0.text) == nil })
            else { log("\(cfg.key): no account row for transactions"); return }
            _ = try Self.checkedReadTarget(row)
            try Phone.tap(row.x + min(row.w, 0.2) / 2, row.y + row.h / 2); Phone.sleep(3)
            (_, words) = try Phone.screen()
            if let r = try dismiss(words) { words = r.1 }
        }
        let days = AppSettings.env("TX_DAYS").flatMap(Int.init) ?? 3
        let cutoff = KST.ymd(KST.day(KST.today, -days))
        let height = Int((try Phone.run(["window"])).split(separator: " ").dropFirst(4).first ?? "978") ?? 978
        let step = -Int(Double(height) * 0.5)
        var all: [String] = [], prev: [String]? = nil, seen = Set<String>(), new = 0
        for _ in 0..<120 {                                         // bounded by cutoff / end of list
            let (_, w) = try Phone.screen()
            let rows = OCR.rows(w)
            if rows == prev { break }                              // scroll didn't move anything: end of the list
            prev = rows
            all += [OCR.page] + rows
            let found = OCR.parse(app: cfg.key, rows: all, when: Date())
            for t in found where !seen.contains(t.uid) {
                seen.insert(t.uid)
                if try db.insertTransaction(t, app: cfg.key) { new += 1 }
            }
            if let oldest = found.map(\.ts).min(), oldest < cutoff { break }
            try Phone.run(["scroll", "\(step)", "0.5", "\(cfg.scrollY)"])
        }
        log("\(cfg.key): \(seen.count) transactions seen, \(new) new")
    }

    /// macOS notification. Strings go as argv, never spliced into AppleScript.
    func notify(_ title: String, _ body: String) {
        log("\(title): \(body)")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", String(body.prefix(200)), title]
        try? p.run()
    }
}
