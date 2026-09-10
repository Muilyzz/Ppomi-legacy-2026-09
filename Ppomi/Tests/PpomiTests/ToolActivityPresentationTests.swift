import XCTest
@testable import Ppomi

final class ToolActivityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testEmptyAndUnavailableStreamsDoNotInventWork() {
        XCTAssertNil(presentation([]).summary)
        let missing = ToolActivityPresentation(events: [], unavailable: true, now: now)
        XCTAssertEqual(missing.summary, "도구 상태 확인 불가")
        XCTAssertTrue(missing.calls.isEmpty)
    }

    func testQuietCallBecomesUnknownWithoutClaimingFailure() throws {
        let call = UUID()
        let event = event(call, .reading, at: 970)
        let boundary = try XCTUnwrap(presentation([event]).calls.first)
        XCTAssertTrue(boundary.isActive)
        XCTAssertFalse(boundary.isStale)
        let stale = try XCTUnwrap(ToolActivityPresentation(events: [event], unavailable: false,
                                                          now: now.addingTimeInterval(0.1)).calls.first)
        XCTAssertFalse(stale.isActive)
        XCTAssertEqual(stale.status, "갱신 없음 · 상태 미확인")
    }

    func testFreshActiveCallTakesPriorityOverAnotherCallsReturnedResult() throws {
        let first = UUID(), second = UUID()
        let events = [event(first, .started, at: 920), event(second, .started, at: 990),
                      event(first, .verifying, at: 995), event(second, .returned, at: 996)]
        let shown = presentation(events)
        XCTAssertEqual(shown.calls.map(\.id), [first, second])
        XCTAssertTrue(try XCTUnwrap(shown.calls.first).isActive)
        XCTAssertEqual(shown.calls[0].events.map(\.kind), [.started, .verifying])
        XCTAssertEqual(shown.calls[1].events.map(\.kind), [.started, .returned])
        XCTAssertEqual(shown.calls[1].status, "결과 반환")
    }

    func testOldUnfinishedCallCannotDisplaceAFreshReturnedCall() {
        let old = UUID(), latest = UUID()
        let shown = presentation([event(old, .started, at: 900), event(latest, .started, at: 995),
                                  event(latest, .returned, at: 998)])
        XCTAssertEqual(shown.calls.first?.id, latest)
        XCTAssertEqual(shown.calls.first?.status, "결과 반환")
        XCTAssertEqual(shown.calls.last?.status, "갱신 없음 · 상태 미확인")
    }

    func testReturnedAndHandedOffNeverClaimBusinessSuccessOrAgentContinuation() {
        for (kind, text) in [(RuntimeEvent.Kind.returned, "결과 반환"), (.handedOff, "에이전트에 반환 · 이후 미확인")] {
            let shown = presentation([event(UUID(), kind, at: 900)])
            XCTAssertEqual(shown.calls.first?.status, text)
            XCTAssertFalse(shown.calls.first?.isActive ?? true)
        }
    }

    func testInsertionOrderBreaksTimestampTiesAndTerminalResultsStayTerminal() {
        let first = UUID(), second = UUID()
        let shown = presentation([event(first, .started, at: 999), event(second, .started, at: 999)])
        XCTAssertEqual(shown.calls.first?.id, second)

        let ended = presentation([event(first, .failed, at: 998), event(first, .reading, at: 999)])
        XCTAssertEqual(ended.calls.first?.last.kind, .failed)
        XCTAssertFalse(ended.calls.first?.isActive ?? true)
        XCTAssertEqual(ended.calls.first?.events.map(\.kind), [.failed, .reading])
    }

    func testReplayReportsOnlyAnAttemptNumberAndHumanHandoffNamesItsRecipient() {
        let replay = RuntimeEvent(callID: UUID(), timestamp: now, tool: "run_combo", kind: .verifying, method: .replay, step: 3)
        XCTAssertEqual(ToolActivityPresentation.replayLabel(for: replay), "재생 동작 3")
        let missing = RuntimeEvent(callID: UUID(), timestamp: now, tool: "run_combo", kind: .handedOff, method: .replay, step: 0)
        XCTAssertNil(ToolActivityPresentation.replayLabel(for: missing))
        let human = RuntimeEvent(callID: UUID(), timestamp: now, tool: "run_combo", kind: .handedOff, method: .human)
        XCTAssertEqual(presentation([human]).calls.first?.status, "사용자에게 넘김 · 이후 미확인")
        XCTAssertFalse(presentation([human]).calls.first?.isActive ?? true)
    }

    func testSummaryNamesTheObservedMethodAndPreservesPendingHumanContext() {
        let call = UUID()
        let observing = RuntimeEvent(callID: call, timestamp: now, tool: "screen_inspect", kind: .observing, method: .vlm)
        XCTAssertEqual(presentation([observing]).summary, "화면 관찰 · VLM · 화면 관찰 중")
        let returned = RuntimeEvent(callID: call, timestamp: now, tool: "screen_inspect", kind: .returned, method: .tool)
        let shown = presentation([observing, returned])
        XCTAssertEqual(shown.summary, "화면 관찰 · 결과 반환")
        XCTAssertEqual(shown.text(priority: "응답 대기 · 확인해 주세요", fallback: "기본 문구"), "응답 대기 · 확인해 주세요")
        XCTAssertEqual(shown.calls.count, 1, "The pending question must not discard the accessible call history")
    }

    private func presentation(_ events: [RuntimeEvent]) -> ToolActivityPresentation {
        ToolActivityPresentation(events: events, unavailable: false, now: now)
    }

    private func event(_ callID: UUID, _ kind: RuntimeEvent.Kind, at timestamp: TimeInterval) -> RuntimeEvent {
        RuntimeEvent(callID: callID, timestamp: Date(timeIntervalSince1970: timestamp), tool: "phone_screen", kind: kind, method: .ocr)
    }
}
