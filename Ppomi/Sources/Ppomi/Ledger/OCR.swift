// OCR words → rows → balances and transactions. Ported line for line from am.py (row_groups, parse_balances,
// parse_transactions, parse_kb_transactions); the archived frames in data/shots are the oracle (Tests/parse-parity.json).
// ICU regex (NSRegularExpression) keeps Python's unicode \d \s \w semantics, and `match` is anchored like Python's re.match.
import Foundation

enum OCR {
    /// One word as `phone ocr` emits it: normalized box, y grows downward.
    struct Word: Decodable, Equatable {
        var x, y, w, h: Double
        var text: String
    }

    /// One transaction as the list parsers read it; `rows` is its span in the row list (for the evidence column).
    struct Tx: Equatable {
        var ts: String          // "YYYY-MM-DD HH:MM"
        var kind: String        // approval | cancel | deposit | withdrawal
        var amount: Int
        var merchant: String
        var card: String        // tag: "체크카드", "스마트출금", ... ("" for transfers in)
        var cumulative: Int     // balance after
        var uid: String
        var rows: ClosedRange<Int>
    }

    /// Separates scrolled pages in the row list handed to the parsers.
    static let page = "\u{0}page"

    /// Per app: the OCR row that is an account (APPS[app]["account"] in am.py). KB rows carry a (last4) token.
    static let account: [String: String] = [
        "KB": #"\(\d{4}\)|\d{6}-\d{2}-\d{6}"#,
        "KBANK": "통장|계좌|박스|입출금|적금|예금|청약",
        "KAKAO": "통장|입출금|세이프박스|적금|모임|예금",
        "TOSS": "통장|계좌|뱅크|은행|입출금|적금|예금|청약",
    ]

    /// A row pattern only that app's transaction list has (a frame is that list when >= 2 rows match).
    static let listMarkers: [String: Re] = ["KAKAO": txMeta, "KB": kbTx]

    static func words(jsonl url: URL) -> [Word] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(Word.self, from: Data($0.utf8)) }
    }

    /// Group words into visual rows by y-center (plain clustering, no layout model).
    static func rowGroups(_ words: [Word], tol: Double = 0.012) -> [(cy: Double, words: [Word])] {
        var rows: [(cy: Double, words: [Word])] = []
        // stable like Python's sorted: ties keep input order
        for (_, w) in words.enumerated().sorted(by: { ($0.1.y + $0.1.h / 2, $0.0) < ($1.1.y + $1.1.h / 2, $1.0) }) {
            let cy = w.y + w.h / 2
            if let last = rows.last, abs(last.cy - cy) < tol { rows[rows.count - 1].words.append(w) }
            else { rows.append((cy, [w])) }
        }
        return rows
    }

    static func rows(_ words: [Word], tol: Double = 0.012) -> [String] {
        rowGroups(words, tol: tol).map { g in
            g.words.enumerated().sorted { ($0.1.x, $0.0) < ($1.1.x, $1.0) }.map(\.1.text).joined(separator: " ")
        }
    }

    // ---------------------------------------------------------------- balances
    static let balance = Re(#"(?<![\d,])(-?)(\d{1,3}(?:,\d{3})+|\d+)\s*원"#)
    static let notBalance = Re(#"누적|총 ?자산|총 ?잔액|이벤트|혜택|수수료|배달비|출시|\d+개 계좌|모두 ?보기|전체보기|내역|송금|적립금|만료|다시 연결|예금 • 적금"#)
    private static let hangul2 = Re("[가-힣]{2,}"), last4 = Re(#"\(\d{4}\)"#), acctNo = Re(#"\d[\d-]{6,}\d"#)
    private static let wonOrNoise = Re(#"-?\d[\d,]*\s*원|이체|:"#), noiseLetter = Re(#"(?<=[\d)])\s+[A-Za-z](?=\s|$)|\s+[A-Za-z]$"#)
    private static let splitLetters = Re(#"\b([A-Za-z]) (?=[A-Za-z]\b)"#), trim = Re(#"^(?:[^\w가-힣(<]|<(?![가-힣]))+|[\s*•·]+$"#)   // keep '<기시>' (신한 loan class) in front

    /// (account label, balance) pairs. The balance is the N원 on the account row itself, else within the next 4 rows
    /// (KB's full list puts 신규일/만기일 lines between a savings account and its balance). Stops at the next account row
    /// and never reuses a balance row, so wrapped names / headers can't double-count. When the account row is just a
    /// number (name on the row above, as in KB's 전체계좌조회), the name row becomes the label.
    static let pager = Re(#"\s*\d+/\d+\s*$"#)
    static func balances(_ words: [Word], account accountRe: String) -> [(String, Int)] {
        let acct = Re(accountRe), exact = Re("^(?:" + accountRe + ")$"), rows = rows(words)   // a whole-row name (e.g. '^총 자산$') is asked for on purpose: no summary-row skip
        var out: [(String, Int)] = [], used = Set<Int>()
        for (i, r) in rows.enumerated() {
            guard acct.search(r) != nil, notBalance.search(r) == nil || exact.search(r) != nil else { continue }
            for j in i..<min(i + 5, rows.count) {
                if used.contains(j) || (j > i && acct.search(rows[j]) != nil) { break }
                guard let m = balance.search(rows[j]), notBalance.search(rows[j]) == nil else { continue }
                var label = (hangul2.search(r) != nil || i == 0) ? r : rows[i - 1] + " " + r
                label = last4.sub(label, "(****)")
                label = acctNo.sub(label) { "…" + $0[0]!.suffix(4) }          // full account numbers: keep last 4
                label = wonOrNoise.sub(label, " ")
                label = noiseLetter.sub(label, "")                             // OCR noise letters after numbers / at end
                label = label.replacingOccurrences(of: "|", with: "I")         // 'A|' -> 'AI' (OCR)
                label = splitLetters.sub(label, "$1")                          // 'A I' -> 'AI' (split by OCR)
                label = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                label = trim.sub(label, "")                                    // chevrons/bullets in front, hidden-balance '*' at the end
                label = pager.sub(label, "")                                   // KB스타기업뱅킹 home card: '사업자응원통장-보통예금 1/1' -> the name
                label = label.replacingOccurrences(of: "보동예금", with: "보통예금")   // OCR reads 통 as 동 on 신한's dark list
                label = label.replacingOccurrences(of: "총자산 투자성과", with: "총 자산")   // 삼성증권: 종합잔고 screen and the home 자산 tab are the same account
                out.append((label, Int(m[1]! + m[2]!.replacingOccurrences(of: ",", with: ""))!)); used.insert(j)
                break
            }
        }
        return out
    }

    // ---------------------------------------------------------------- 카카오뱅크 transaction list
    // A date header (MM.DD), then per transaction two rows: "<merchant> -12,000원" and "HH:MM #체크카드 518,574원".
    static let txDate = Re(#"^(\d{1,2})\.(\d{1,2})(?![\d,])"#)                       // '09.02', also with trailing OCR noise
    static let txAmt = Re(#"^(.+?)\s+([+\-–—~]?)\s?(\d[\d,]*)\s*원$"#)                // deposits carry no sign; OCR reads '-' as '~' at times
    static let txMeta = Re(#"^(\d{1,2}):(\d{2})\s+(?:#?\s*(.+?)\s+)?(-?\d[\d,]*)\s*원$"#)  // tag may have spaces / a split '#', or be absent

    /// Rows must be the concatenation of every page read so far (newest first), pages separated by `page`: the date
    /// header for a page's first transactions is on an earlier page, and a merchant/time row pair can straddle a boundary.
    static func transactions(_ rows: [String], when: Date, app: String) -> [Tx] {
        let now = ymd(when)
        var out: [Tx] = [], cur: (Int, Int, Int)?, prev: (Int, Int, Int)?
        var pending: (merchant: String, sign: String, amount: Int, row: Int)?
        for (j, r) in rows.enumerated() {
            if r == page {
                // a page opens with the rows that sat just above its first date header on the previous page (the pages overlap).
                // If that header is the one already current, those rows are newer than it: use the date before it.
                if let nxt = rows[(j + 1)...].first(where: { $0 == page || txDate.match($0) != nil }), nxt != page,
                   let m = txDate.match(nxt), let c = cur, (Int(m[1]!)!, Int(m[2]!)!) == (c.1, c.2) { cur = prev }
                pending = nil; continue
            }
            if let m = txDate.match(r) {
                let mo = Int(m[1]!)!, d = Int(m[2]!)!
                prev = cur; cur = (year(mo, d, now), mo, d); pending = nil; continue
            }
            if let m = txMeta.match(r) {                  // checked first: an unsigned balance row also looks like an amount row
                if let p = pending, let c = cur {
                    let tag = (m[3] ?? "").trimmed, balance = Int(m[4]!.replacingOccurrences(of: ",", with: ""))!
                    let ts = stamp(c.0, c.1, c.2, Int(m[1]!)!, Int(m[2]!)!)
                    // natural key from numbers only — OCR of the merchant text drifts between captures, digits don't
                    out.append(Tx(ts: ts, kind: kind(sign: p.sign, tag: tag, merchant: p.merchant), amount: p.amount, merchant: p.merchant,
                                  card: String(tag.drop(while: { $0 == "#" })), cumulative: balance,
                                  uid: "\(app):\(ts):\(p.sign)\(p.amount):\(balance)", rows: p.row...j))
                }
                pending = nil; continue
            }
            if let m = txAmt.match(r), cur != nil {
                pending = (m[1]!.trimmed, ["", "+"].contains(m[2]!) ? "+" : "-", Int(m[3]!.replacingOccurrences(of: ",", with: ""))!, j)
                continue
            }
            pending = nil                                 // any other row breaks a merchant/time pair
        }
        return out
    }

    /// '+' is a deposit, or a refund when 취소 appears; '-' is card spend when the tag says 체크카드, else an account withdrawal.
    static func kind(sign: String, tag: String, merchant: String) -> String {
        if sign == "+" { return tag.contains("취소") || merchant.contains("취소") ? "cancel" : "deposit" }
        return tag.contains("체크카드") ? "approval" : "withdrawal"
    }

    // ---------------------------------------------------------------- KB스타뱅킹 거래내역조회
    // A month header (YYYY.MM), then per transaction four consecutive rows: "MM.DD HH:MM:SS | 타입", "<상대/적요>",
    // "-100,000원" ('+' for deposits), "518,574원" (balance after). A page boundary cutting through one drops it there.
    static let kbMonth = Re(#"^(\d{4})\.(\d{2})(?![\d,.])"#)                         // '2026.08', not the range line '2026.06.04 ~'
    static let kbTx = Re(#"^(\d{1,2})\.(\d{1,2})\s+(\d{1,2}):(\d{2}):\d{2}\s*[|Il1]?\s*(.*)$"#)   // OCR reads '|' as I/l/1
    static let kbWon = Re(#"^([+\-–—~]?)\s?(\d[\d,]*)\s*원$"#)

    static func kbTransactions(_ rows: [String], when: Date, app: String) -> [Tx] {
        let now = ymd(when)
        var out: [Tx] = [], yr: Int?, i = 0
        while i < rows.count {
            if let m = kbMonth.match(rows[i]) { yr = Int(m[1]!); i += 1; continue }
            guard let m = kbTx.match(rows[i]), i + 3 < rows.count else { i += 1; continue }
            guard let amt = kbWon.match(rows[i + 2]), let bal = kbWon.match(rows[i + 3]), kbWon.match(rows[i + 1]) == nil
            else { i += 1; continue }                     // four-row shape broken (page boundary, wrapped memo)
            let mo = Int(m[1]!)!, d = Int(m[2]!)!, h = Int(m[3]!)!, mi = Int(m[4]!)!
            let tag = m[5]!.trimmed, merchant = rows[i + 1].trimmed
            // ponytail: a '-' lost by OCR reads as a withdrawal; the balance column could confirm the sign, add if it ever bites
            let sign = amt[1]! == "+" ? "+" : "-"
            let amount = Int(amt[2]!.replacingOccurrences(of: ",", with: ""))!, balance = Int(bal[2]!.replacingOccurrences(of: ",", with: ""))!
            let ts = stamp(yr ?? year(mo, d, now), mo, d, h, mi)
            out.append(Tx(ts: ts, kind: kind(sign: sign, tag: tag, merchant: merchant), amount: amount, merchant: merchant, card: tag,
                          cumulative: balance, uid: "\(app):\(ts):\(sign)\(amount):\(balance)", rows: i...(i + 3)))
            i += 4
        }
        return out
    }

    /// PARSERS in am.py: KB has its own list shape; everything else reads like 카카오뱅크.
    static func parse(app: String, rows: [String], when: Date) -> [Tx] {
        app == "KB" ? kbTransactions(rows, when: when, app: app) : transactions(rows, when: when, app: app)
    }

    // ---------------------------------------------------------------- dates
    private static func ymd(_ d: Date) -> (Int, Int, Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year!, c.month!, c.day!)
    }
    /// A MM.DD read after today's MM.DD belongs to last year.
    private static func year(_ mo: Int, _ d: Int, _ now: (Int, Int, Int)) -> Int { now.0 - ((mo, d) > (now.1, now.2) ? 1 : 0) }
    private static func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> String {
        String(format: "%04d-%02d-%02d %02d:%02d", y, mo, d, h, mi)
    }
}

/// Python-flavoured regex over ICU: `match` anchors at the start, `search` anywhere, `sub` replaces every match.
struct Re {
    let re: NSRegularExpression
    /// A pattern that is not a regex (a brain's tap target like "예약(") is matched literally rather than crashing the server.
    init(_ pattern: String) { re = (try? NSRegularExpression(pattern: pattern)) ?? (try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern))) }

    struct Match {
        let s: NSString, r: NSTextCheckingResult
        /// Group i, nil when it did not participate (Python's m.group(i) is None).
        subscript(_ i: Int) -> String? { let g = r.range(at: i); return g.location == NSNotFound ? nil : s.substring(with: g) }
    }
    private func all(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    func match(_ s: String) -> Match? { re.firstMatch(in: s, options: .anchored, range: all(s)).map { Match(s: s as NSString, r: $0) } }
    func search(_ s: String) -> Match? { re.firstMatch(in: s, range: all(s)).map { Match(s: s as NSString, r: $0) } }
    func sub(_ s: String, _ template: String) -> String { re.stringByReplacingMatches(in: s, range: all(s), withTemplate: template) }
    func sub(_ s: String, _ f: (Match) -> String) -> String {
        let ns = NSMutableString(string: s)
        for m in re.matches(in: s, range: all(s)).reversed() { ns.replaceCharacters(in: m.range, with: f(Match(s: s as NSString, r: m))) }
        return ns as String
    }
}

private extension String {
    /// Python str.strip(): unicode whitespace at both ends.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
