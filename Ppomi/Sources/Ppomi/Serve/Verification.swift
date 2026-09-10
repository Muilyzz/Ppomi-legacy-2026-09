// 검증 장부: 명세 단계 하나를 실제 대상(폰·Mac 브라우저·Windows)에서 확인한 판정. 발자국(걸음의 자동 기록) 옆 data/playbooks/<id>.verify.jsonl 에 한 줄씩 쌓인다.
// 발자국은 "어느 화면에서 무엇을 눌렀나"이고, 판정은 "명세의 이 단계가 이 패키지 버전에서 맞나(ok) · 실제 라벨·경로가 다르다(changed) · 진행 불가(fail)"다.
// 판정은 버전에 묶인다: 다른 버전의 판정은 stale 로만 세고 검증으로 치지 않는다(playbook-format.md 의 버전 규칙).
import Foundation

struct StepVerification: Codable, Equatable {
    static let outcomes = ["ok", "changed", "fail"]
    var id = UUID().uuidString
    var app: String                 // package id
    var version: String             // manifest.version at the time
    var capability: String
    var step: String
    var outcome: String
    var actual: String? = nil       // what the screen really said when it differs from the spec; never personal data
    var note: String? = nil
    var at = ISO8601DateFormatter().string(from: Date())
    var by = "agent"                // agent | human
    var key: String { capability + "/" + step }
}

/// Current version only: the last judgement per step, and the counts the kiosk, MCP and the developer page show.
struct VerificationSummary: Codable, Equatable {
    var version: String
    var total = 0, ok = 0, changed = 0, fail = 0, unverified = 0, stale = 0
    var steps: [String: StepVerification] = [:]
    var last: String? = nil
}

enum VerificationStore {
    struct Invalid: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

    static func url(_ app: String, in dir: URL = Playbooks.dir) -> URL { dir.appendingPathComponent(app + ".verify.jsonl") }

    static func load(_ app: String, in dir: URL = Playbooks.dir) -> [StepVerification] {
        guard let raw = try? String(contentsOf: url(app, in: dir), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(StepVerification.self, from: Data($0.utf8)) }
    }

    static func append(_ v: StepVerification, in dir: URL = Playbooks.dir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = String(decoding: try JSONEncoder().encode(v), as: UTF8.self) + "\n"
        let file = url(v.app, in: dir)
        if let h = try? FileHandle(forWritingTo: file) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: Data(line.utf8)) }
        else { try line.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// What the MCP tool accepts: a step that exists in the manifest and one of three outcome words.
    static func judge(_ record: PlaybookRecord, capability: String, step: String, outcome: String, actual: String? = nil, note: String? = nil, by: String = "agent") throws -> StepVerification {
        guard let cap = record.manifest.capabilities.first(where: { $0.id == capability }) else {
            throw Invalid("기능 없음: \(capability) · 있는 것: " + record.manifest.capabilities.map(\.id).joined(separator: ", "))
        }
        guard cap.steps.contains(where: { $0.id == step }) else {
            throw Invalid("단계 없음: \(capability)/\(step) · 있는 것: " + cap.steps.map(\.id).joined(separator: ", "))
        }
        guard StepVerification.outcomes.contains(outcome) else { throw Invalid("outcome 은 ok · changed · fail 중 하나") }
        func some(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        return StepVerification(app: record.id, version: record.manifest.version, capability: capability, step: step, outcome: outcome, actual: some(actual), note: some(note), by: by)
    }

    static func summary(_ record: PlaybookRecord, in dir: URL = Playbooks.dir) -> VerificationSummary {
        var s = VerificationSummary(version: record.manifest.version)
        var stale = Set<String>()
        for v in load(record.id, in: dir) {                       // file order is time order: the last line per step wins
            if v.version == s.version { s.steps[v.key] = v; s.last = v.at } else { stale.insert(v.key) }
        }
        for cap in record.manifest.capabilities {
            for step in cap.steps {
                let key = cap.id + "/" + step.id
                s.total += 1
                switch s.steps[key]?.outcome {
                case "ok": s.ok += 1
                case "changed": s.changed += 1
                case "fail": s.fail += 1
                default: s.unverified += 1; if stale.contains(key) { s.stale += 1 }
                }
            }
        }
        return s
    }
}
