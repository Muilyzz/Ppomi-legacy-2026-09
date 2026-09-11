// 소뇌: the brain's path through an app, kept as footprints (one step each, hub record shape) next to the playbook
// (data/playbooks/<app>.jsonl), and replayed without the brain until a screen's fingerprint stops matching.
// Pure logic — the phone comes in through closures, so it runs in tests on fake screens.
import Foundation

struct Footprint: Codable, Equatable {
    struct Verified: Codable, Equatable {
        struct ReplayCounts: Codable, Equatable { var ok = 0, fail = 0 }
        var ok = 0, fail = 0
        // Older totals include repeated brain actions. Only these counters prove automatic replay.
        var replayOK: Int? = nil
        var replayFail: Int? = nil
        var replayVersions: [String: ReplayCounts]? = nil
    }
    var id = UUID().uuidString
    var app: String
    var appVersion: String? = nil
    var glyph: String                    // ▶ ⊙ ⌨ ↓ ⎋ 👤 🎟 🔍 📝 ✋
    var target: String                   // ⊙/↓: tap regex, ⌨: text, ▶: app title, ⎋: key name
    var fingerprintBefore: [String]
    var fingerprintAfter: [String]
    var note: String? = nil
    var createdAt = ISO8601DateFormatter().string(from: Date())
    var verified = Verified()
    var source = "brain"                 // brain | hub | manual

    static let replayable: Set<String> = ["▶", "⊙", "⌨", "↓", "⎋"]
    /// Tools.payWord's word list without its end anchor: a target is a regex ("결제|취소" would slip past `\s*$`).
    static let payWord = Re("(?<!바로)(" + Tools.payWords + ")")
    static func isPayTarget(_ s: String) -> Bool { payWord.search(s) != nil }

    /// nil when the cerebellum may take this step itself; else why the brain gets it back.
    var handoff: String? {
        if !Self.replayable.contains(glyph) { return glyph == "👤" ? "사용자 차례" : glyph == "✋" ? "승인 필요 지점" : "두뇌 판단" }
        if (glyph == "⊙" || glyph == "↓") && Self.isPayTarget(target) { return "승인 필요 지점" }
        return nil
    }
}

enum Fingerprint {
    static let threshold = 0.5

    /// The screen's stable words, top to bottom: no token with a digit (amounts, times, dates, counts), no 1-char token,
    /// no bare symbols, no 이름+님 (고객님·회원님 are UI words), 2~24 chars, unique, at most 8. OCR lines are split on whitespace ("406,600원 결제하기" → 결제하기).
    static func words(from words: [OCR.Word]) -> [String] {
        var out: [String] = []
        for line in OCR.rowGroups(words).flatMap({ $0.words.sorted { $0.x < $1.x } }) {
            for raw in line.text.split(whereSeparator: \.isWhitespace) {
                let t = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                guard (2...24).contains(t.count), t.contains(where: \.isLetter), !t.contains(where: \.isNumber), !out.contains(t),
                      !t.hasSuffix("님") || ["고객님", "회원님"].contains(t) else { continue }
                out.append(t)
                if out.count == 8 { return out }
            }
        }
        return out
    }

    /// Jaccard; 0 when both are empty (a blank frame matches nothing).
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        let x = Set(a), y = Set(b), u = x.union(y)
        return u.isEmpty ? 0 : Double(x.intersection(y).count) / Double(u.count)
    }
}

enum FootprintStore {
    static func record(_ app: String, in dir: URL = Playbooks.dir) -> PlaybookRecord? {
        let records = PlaybookCatalog.load(in: dir, includeBundled: dir.standardizedFileURL == Playbooks.dir.standardizedFileURL)
        return records.first { $0.id.caseInsensitiveCompare(app) == .orderedSame }
            ?? records.first { $0.name.caseInsensitiveCompare(app) == .orderedSame }
            ?? records.first { $0.matches(app) }
    }
    static func key(_ app: String, in dir: URL = Playbooks.dir) -> String { record(app, in: dir)?.id ?? app }
    private static func legacyURL(_ app: String, in dir: URL) -> URL {
        dir.appendingPathComponent(app.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces) + ".jsonl")
    }
    static func url(_ app: String, in dir: URL = Playbooks.dir) -> URL {
        legacyURL(key(app, in: dir), in: dir)
    }
    static func load(_ app: String, in dir: URL = Playbooks.dir) -> [Footprint] {
        // Canonical IDs survive renames. Read legacy names too, without deleting or rewriting old files.
        let identities = record(app, in: dir)?.identities ?? [app]
        var seen = Set<String>(), files = Set<String>(), out: [Footprint] = []
        let dec = JSONDecoder()
        for identity in identities + [app] {
            let file = legacyURL(identity, in: dir)
            guard files.insert(file.path).inserted, let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in raw.split(whereSeparator: \.isNewline) {
                if let fp = try? dec.decode(Footprint.self, from: Data(line.utf8)), seen.insert(fp.id).inserted { out.append(fp) }
            }
        }
        return out
    }
    static func append(_ app: String, _ fp: Footprint, in dir: URL = Playbooks.dir) throws { try save(app, load(app, in: dir) + [fp], in: dir) }
    /// verified.ok / .fail += 1 for that id; nothing when the id is unknown.
    static func bump(_ app: String, id: String, ok: Bool, replay: Bool = false, version: String? = nil, in dir: URL = Playbooks.dir) throws {
        var fps = load(app, in: dir)
        guard let i = fps.firstIndex(where: { $0.id == id }) else { return }
        if ok { fps[i].verified.ok += 1 } else { fps[i].verified.fail += 1 }
        if replay {
            if ok { fps[i].verified.replayOK = (fps[i].verified.replayOK ?? 0) + 1 }
            else { fps[i].verified.replayFail = (fps[i].verified.replayFail ?? 0) + 1 }
            if let version {
                var versions = fps[i].verified.replayVersions ?? [:]
                var counts = versions[version] ?? .init()
                if ok { counts.ok += 1 } else { counts.fail += 1 }
                versions[version] = counts
                fps[i].verified.replayVersions = versions
            }
        }
        try save(app, fps, in: dir)
    }
    // ponytail: whole-file rewrite per write; fine for a few hundred lines per app
    private static func save(_ app: String, _ fps: [Footprint], in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        try (fps.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n").write(to: url(app, in: dir), atomically: true, encoding: .utf8)
    }
}

/// Walk the footprints from the current screen: pick the best-matching step, take it, check the screen after; stop at the
/// first screen that matches nothing (.done after ≥1 step) or differs from what the step promised, and hand a step the
/// cerebellum must not take (pay tap, the person's turn, judgement) back to the brain untouched.
struct Replay {
    enum Outcome: Equatable { case done, stopped(String), handoff(String, at: Footprint) }
    struct Result { var steps: [(fp: Footprint, ok: Bool)] = []; var outcome = Outcome.done; var lastWords: [OCR.Word] = [] }

    var footprints: [Footprint]
    var screen: () throws -> [OCR.Word]
    var act: (Footprint) throws -> Void
    var wait: (Double) -> Void
    var settle = 1.5
    /// Only execution phases and ordinals leave the replay engine; footprints and targets stay here.
    var onEvent: ((RuntimeEvent.Kind, Int?) -> Void)? = nil

    func run(maxSteps: Int = 12) throws -> Result {
        var r = Result(); r.lastWords = try screen()
        var last: String? = nil
        while r.steps.count < maxSteps {
            let now = Fingerprint.words(from: r.lastWords)
            let best = footprints.lazy.filter { $0.id != last }                                   // never the same step twice in a row
                .map { ($0, Fingerprint.similarity(now, $0.fingerprintBefore)) }
                .filter { $0.1 >= Fingerprint.threshold }
                .max { ($0.1, $0.0.verified.ok) < ($1.1, $1.0.verified.ok) }
            guard let fp = best?.0 else {
                r.outcome = r.steps.isEmpty ? .stopped("아는 화면이 아님") : .done
                onEvent?(.handedOff, r.steps.count)
                return r
            }
            let step = r.steps.count + 1
            if let why = fp.handoff { r.outcome = .handoff(why, at: fp); onEvent?(.handedOff, step); return r }
            // the regex may land on a pay button on this screen even when its text does not say so ("." or "하기")
            if fp.glyph == "⊙" || fp.glyph == "↓" {
                let re = Re(fp.target)
                if r.lastWords.contains(where: { re.search($0.text) != nil && Footprint.isPayTarget($0.text) }) {
                    r.outcome = .handoff("승인 필요 지점", at: fp); onEvent?(.handedOff, step); return r
                }
            }
            onEvent?(.acting, step)
            try act(fp)
            onEvent?(.acted, step)
            wait(settle)
            onEvent?(.verifying, step)
            r.lastWords = try screen()
            let ok = Fingerprint.similarity(Fingerprint.words(from: r.lastWords), fp.fingerprintAfter) >= Fingerprint.threshold
            r.steps.append((fp, ok))
            onEvent?(ok ? .verified : .mismatch, step)
            if !ok { r.outcome = .stopped("화면이 예상과 다름"); onEvent?(.handedOff, step); return r }
            last = fp.id
        }
        r.outcome = .stopped("최대 걸음 수"); onEvent?(.handedOff, r.steps.count); return r
    }
}
