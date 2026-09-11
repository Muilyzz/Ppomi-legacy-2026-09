import Foundation

/// One native approval at a time. Session replacement, Stop and EOF revoke the waiter.
/// Only the host's human-input methods can answer; this is not an executeTool capability.
final class AgentExecutorApproval: @unchecked Sendable {
    struct Question {
        let id: String
        let text: String
        let options: [String]
        var json: [String: Any] { ["id": id, "text": text, "options": options] }
    }
    private let condition = NSCondition()
    private var revision = UUID()
    private var question: Question?
    private var answer: String?
    var onChange: (() -> Void)?

    var current: Question? {
        condition.lock(); defer { condition.unlock() }
        return question
    }

    func reset(revision: UUID) {
        condition.lock()
        self.revision = revision; question = nil; answer = nil
        condition.broadcast(); condition.unlock()
        onChange?()
    }

    func ask(_ html: String, options: [String], revision expected: UUID, timeout: TimeInterval = 300) -> String? {
        condition.lock()
        guard expected == revision, question == nil, !options.isEmpty else { condition.unlock(); return nil }
        let pending = Question(id: UUID().uuidString, text: HTML.plain(html), options: options)
        question = pending; answer = nil
        condition.unlock(); onChange?(); condition.lock()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while revision == expected && question?.id == pending.id && answer == nil {
            if !condition.wait(until: deadline) { break }
        }
        let result = revision == expected && question?.id == pending.id ? answer : nil
        if question?.id == pending.id { question = nil; answer = nil }
        condition.unlock(); onChange?()
        return result
    }

    func respond(id: String, choice: String) throws {
        condition.lock(); defer { condition.unlock() }
        guard let question, question.id == id, question.options.contains(choice), answer == nil else {
            throw AgentNativeError.invalidRequest
        }
        answer = choice; condition.broadcast()
    }
}
