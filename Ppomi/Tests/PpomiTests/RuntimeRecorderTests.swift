import XCTest
@testable import Ppomi

final class RuntimeRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-runtime-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Tools.fake = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func makeTools() throws -> Tools {
        let tools = try Tools(db: DB(path: directory.appendingPathComponent("ledger.db").path, writable: true))
        tools.currentText = "해줘"
        return tools
    }

    private func word(_ text: String) -> OCR.Word { .init(x: 0.1, y: 0.2, w: 0.3, h: 0.03, text: text) }

    func testNestedWrappersShareOneSpanAndDoNotOverwriteTerminalOutcome() {
        var events: [RuntimeEvent] = []
        let recorder = RuntimeRecorder { events.append($0) }
        let result = recorder.withCall("phone_screen") {
            recorder.withCall("phone_screen") {
                recorder.emit(.blocked)
                recorder.emit(.failed)
                return "original refusal"
            }
        }
        XCTAssertEqual(result, "original refusal")
        XCTAssertEqual(events.map(\.kind), [.started, .blocked])
        XCTAssertEqual(Set(events.map(\.callID)).count, 1)
        recorder.withCall("phone_screen") { recorder.emit(.read, method: .ocr) }
        XCTAssertEqual(Set(events.map(\.callID)).count, 2)
        XCTAssertEqual(events.last?.kind, .returned)
    }

    func testSinkFailurePreservesOriginalReturnAndThrownError() {
        enum Failure: Error { case sink, original }
        let recorder = RuntimeRecorder { _ in throw Failure.sink }
        XCTAssertEqual(recorder.withCall("sql") { 42 }, 42)
        XCTAssertThrowsError(try recorder.withCall("sql") { throw Failure.original }) { error in
            guard case Failure.original = error else { return XCTFail("The original error must survive") }
        }
    }

    func testUnknownToolNamesAreNotRecordedAndStepCannotCarryText() {
        var events: [RuntimeEvent] = []
        let recorder = RuntimeRecorder { events.append($0) }
        XCTAssertEqual(recorder.withCall("private profile value") { "unchanged" }, "unchanged")
        XCTAssertTrue(events.isEmpty)
        recorder.withCall("run_combo") { recorder.emit(.acting, method: .replay, step: -1) }
        XCTAssertNil(events.first(where: { $0.kind == .acting })?.step)
        XCTAssertTrue(events.allSatisfy { $0.tool == "run_combo" })
    }

    func testDefaultWriterIsLazyAndUsesTheLedgersSeparateRuntimeStore() throws {
        let tools = try makeTools()
        let ledger = directory.appendingPathComponent("ledger.db").path
        let runtime = RuntimeEventStore.path(for: ledger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime))
        _ = tools.execute("today_spending", [:])
        let events = try RuntimeEventStore(ledgerPath: ledger, writable: false).recent()
        XCTAssertEqual(events.map(\.kind), [.started, .returned])
        XCTAssertTrue(events.allSatisfy { $0.tool == "today_spending" })
        XCTAssertNotEqual(runtime, ledger)
    }

    func testControlAndMCPReadsKeepTheirBehaviorWithoutRecordingContents() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = [], hands: [[String]] = []
        let privateText = "private-person-address-123"
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        Tools.fake = (screen: { [self.word(privateText)] }, hand: { hands.append($0) })
        let result = tools.runtimeRecorder.withCall("windows_type") {
            tools.execute("windows_type", ["text": privateText])
        }
        XCTAssertTrue(result.hasPrefix("입력했다"))
        XCTAssertEqual(hands, [["type", privateText]])
        XCTAssertEqual(events.map(\.kind), [.started, .acting, .acted, .returned])
        XCTAssertEqual(Set(events.map(\.callID)).count, 1)
        XCTAssertFalse(String(describing: events).contains(privateText))

        events = []
        let screen = tools.screenForMCP()
        XCTAssertTrue(screen.text.contains(privateText))
        XCTAssertNil(screen.png)
        XCTAssertEqual(events.map(\.kind), [.started, .reading, .read, .returned])
        XCTAssertEqual(events.filter { $0.method == .ocr }.map(\.kind), [.reading, .read])
        XCTAssertFalse(String(describing: events).contains(privateText))
    }

    func testRefusedScreenNeverClaimsReadingOrCallsVLM() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = []
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        tools.currentText = "오늘 지출은?"
        Tools.fake = (screen: { XCTFail("refusal must precede capture"); return [] }, hand: { _ in XCTFail("refusal must precede action") })
        tools.inspectVisualScreen = { _, _, _, _ in XCTFail("no automatic VLM fallback"); return "" }
        XCTAssertTrue(tools.screenForMCP().text.hasPrefix("실행 안 함:"))
        XCTAssertEqual(events.map(\.kind), [.started, .blocked])
    }

    func testStringErrorResponsesAreFailedAndExplicitRefusalsRemainBlocked() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = []
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        for name in ["windows_open", "phone_open", "browser_open"] {
            events = []
            XCTAssertTrue(tools.execute(name, [:]).hasPrefix("오류:"))
            XCTAssertEqual(events.map(\.kind), [.started, .failed], name)
        }

        events = []
        let failure = NSError(domain: "private-browser-failure", code: 1)
        tools.openBrowser = { _ in throw failure }
        XCTAssertEqual(tools.execute("browser_open", ["url": "https://example.com"]), "오류: \(failure.localizedDescription)")
        XCTAssertEqual(events.map(\.kind), [.started, .failed])
        XCTAssertFalse(String(describing: events).contains("private-browser-failure"))

        events = []
        tools.visualAssistanceEnabled = { false }
        XCTAssertTrue(tools.execute("screen_inspect", ["surface": "windows", "question": "화면 확인"]).hasPrefix("실행 안 함:"))
        XCTAssertEqual(events.map(\.kind), [.started, .blocked], "Central response classification must not replace an explicit refusal")
    }

    func testOptionalFootprintReadFailureDoesNotMarkSuccessfulHandAsFailed() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = [], hands = 0, reads = 0
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        tools.currentApp = "private-app"
        tools.lastWords = [word("상세"), word("화면")]
        tools.footprintDir = directory.appendingPathComponent("footprints")
        Tools.fake = (screen: {
            reads += 1
            throw NSError(domain: "private-screen-failure", code: 1)
        }, hand: { _ in hands += 1 })

        XCTAssertEqual(tools.execute("phone_type", ["text": "참고"]), "입력했다. phone_screen 으로 확인하라.")
        XCTAssertEqual(hands, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(events.map(\.kind), [.started, .acting, .acted, .reading, .readFailed, .returned])
        XCTAssertEqual(events.first(where: { $0.kind == .readFailed })?.method, .ocr)
        XCTAssertFalse(String(describing: events).contains("private-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.footprintDir.path))

        events = []
        XCTAssertTrue(tools.execute("phone_screen", [:]).hasPrefix("오류:"))
        XCTAssertEqual(events.map(\.kind), [.started, .reading, .failed], "A required screen read still fails the call")
    }

    func testVisualCacheReportsFreshOCRAndOnlyOneModelObservation() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = [], requests = 0, captures = 0
        let png = directory.appendingPathComponent("synthetic.png")
        try Data("private image content".utf8).write(to: png)
        let privateText = "private-screen-question-result"
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        tools.visualAssistanceEnabled = { true }
        tools.windowsGateStatus = { (true, "READY") }
        tools.captureVisualScreen = { _ in captures += 1; return (png, [self.word(privateText)]) }
        tools.inspectVisualScreen = { _, _, _, _ in requests += 1; return privateText }
        let arguments = ["surface": "windows", "question": privateText]
        XCTAssertEqual(tools.execute("screen_inspect", arguments), privateText)
        XCTAssertEqual(tools.execute("screen_inspect", arguments), privateText)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(events.map(\.kind), [.started, .reading, .read, .observing, .observed, .returned,
                                           .started, .reading, .read, .cached, .returned])
        XCTAssertFalse(String(describing: events).contains(privateText))
    }

    func testAskRecordsActualResponseWithoutQuestionOrAnswerContents() throws {
        let tools = try makeTools()
        var events: [RuntimeEvent] = []
        let privateText = "private-user-answer"
        tools.runtimeRecorder = RuntimeRecorder { events.append($0) }
        tools.askOwner = { question, options in
            XCTAssertEqual(events.last?.kind, .waitingForUser)
            XCTAssertEqual(question, privateText)
            XCTAssertEqual(options, [privateText])
            return privateText
        }
        let options = String(decoding: try JSONSerialization.data(withJSONObject: [privateText]), as: UTF8.self)
        XCTAssertEqual(tools.execute("ask_choice", ["question": privateText, "options": options]), "사용자 선택: \(privateText)")
        XCTAssertEqual(events.map(\.kind), [.started, .waitingForUser, .userResponded, .returned])
        XCTAssertFalse(String(describing: events).contains(privateText))

        events = []
        tools.askOwner = { _, _ in nil }
        XCTAssertTrue(tools.execute("ask_choice", ["question": privateText, "options": options]).contains("답이 없었다"))
        XCTAssertEqual(events.map(\.kind), [.started, .waitingForUser, .handedOff])
    }

    func testReplayReportsVerificationMismatchAndKnownPathEndWithoutCompletionClaim() throws {
        let footprint = Footprint(app: "private-app", glyph: "⊙", target: "private-target",
                                  fingerprintBefore: ["목록", "버튼"], fingerprintAfter: ["상세", "화면"])
        for matches in [true, false] {
            var events: [RuntimeEvent] = [], reads = 0, acts = 0
            let recorder = RuntimeRecorder { events.append($0) }
            let result = try recorder.withCall("run_combo") {
                try Replay(footprints: [footprint], screen: {
                    reads += 1
                    return (reads == 1 ? ["목록", "버튼"] : matches ? ["상세", "화면"] : ["오류", "연결"]).map(self.word)
                }, act: { _ in acts += 1 }, wait: { _ in },
                   onEvent: { recorder.emit($0, method: .replay, step: $1) }).run()
            }
            XCTAssertEqual(acts, 1)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(result.steps.map(\.ok), [matches])
            XCTAssertEqual(events.map(\.kind), [.started, .acting, .acted, .verifying, matches ? .verified : .mismatch, .handedOff])
            XCTAssertTrue(events.filter { $0.method == .replay }.allSatisfy { $0.step == 1 })
            XCTAssertFalse(String(describing: events).contains("private-"))
            XCTAssertEqual(result.outcome, matches ? .done : .stopped("화면이 예상과 다름"))
        }
    }

    func testReplayApprovalHandoffDoesNotClaimAnAction() throws {
        let footprint = Footprint(app: "private-app", glyph: "⊙", target: "결제하기",
                                  fingerprintBefore: ["최종", "결제하기"], fingerprintAfter: [])
        var phases: [RuntimeEvent.Kind] = []
        let result = try Replay(footprints: [footprint], screen: { [self.word("최종"), self.word("결제하기")] },
                                act: { _ in XCTFail("approval handoff must precede action") }, wait: { _ in },
                                onEvent: { kind, step in phases.append(kind); XCTAssertEqual(step, 1) }).run()
        XCTAssertEqual(phases, [.handedOff])
        XCTAssertEqual(result.outcome, .handoff("승인 필요 지점", at: footprint))
    }
}
