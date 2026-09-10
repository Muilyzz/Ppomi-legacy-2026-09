import Foundation

/// Prepared off the UI thread. The settings and active readers change only after this succeeds.
struct PreparedLedgerSettings {
    let path: String
    let me: String
    let ledger: Ledger
    let questions: DB
    let greetOnArrival: Bool

    static func prepare(dbPath: String, me: String) throws -> PreparedLedgerSettings {
        let draftPath = dbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = me.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draftPath.isEmpty else { throw ValidationError("DB 경로를 입력해 주세요.") }
        guard !name.isEmpty else { throw ValidationError("내 이름을 입력해 주세요.") }
        let path = normalizedPath(draftPath)
        if let fixed = ProcessInfo.processInfo.environment["PPOMI_DB"], normalizedPath(fixed) != path {
            throw ValidationError("실행 환경의 PPOMI_DB가 장부 경로를 고정하고 있습니다. 실행 환경에서 경로를 바꿔 주세요.")
        }

        // Open read-only first: a typo must not silently create a new, empty ledger.
        let ledger = try Ledger.load(dbPath: path, me: name)
        let questions = try DB(path: path, writable: true)
        // Prove that approval answers can be written without changing any stored value.
        try questions.withLockedAccess {
            try questions.run("BEGIN IMMEDIATE TRANSACTION")
            do {
                try questions.run("UPDATE state SET value = value WHERE 0")
                try questions.run("ROLLBACK")
            } catch {
                try? questions.run("ROLLBACK")
                throw error
            }
        }
        let greeting = try questions.state("greet:on") != "0"
        return PreparedLedgerSettings(path: path, me: name, ledger: ledger,
                                      questions: questions, greetOnArrival: greeting)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private struct ValidationError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
