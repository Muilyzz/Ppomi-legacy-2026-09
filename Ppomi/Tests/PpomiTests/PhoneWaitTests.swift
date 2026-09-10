import XCTest
@testable import Ppomi

final class PhoneWaitTests: XCTestCase {
    private func snap(inUse: Bool = false, connected: Bool = false, needsUnlock: Bool = false) -> Mirroring.ConnectionSnapshot {
        .init(state: connected ? .connected : .inUse, connected: connected, inUse: inUse, needsUnlock: needsUnlock, connecting: false, canReconnect: false)
    }

    func testReturnsAsSoonAsTheMirrorReconnects() {
        var sequence = [snap(inUse: true), snap(inUse: true), snap(connected: true)]
        var slept = 0
        let text = Tools.waitForPhone(seconds: 90, observe: { sequence.removeFirst() }, sleep: { slept += 1 })
        XCTAssertTrue(text.hasPrefix("연결됨"), text)
        XCTAssertEqual(slept, 2)
    }

    func testGivesUpAfterTheBudgetWithoutAskingTheUserItself() {
        var clock = Date(timeIntervalSince1970: 0)
        var polls = 0
        let text = Tools.waitForPhone(seconds: 30, observe: { polls += 1; return snap(inUse: true) },
                                      sleep: { clock = clock.addingTimeInterval(10) }, now: { clock })
        XCTAssertTrue(text.hasPrefix("아직 사용 중"), text)
        XCTAssertEqual(polls, 4)
        XCTAssertFalse(text.contains("?"))
    }

    func testUnlockRequestIsReportedImmediately() {
        let text = Tools.waitForPhone(seconds: 90, observe: { snap(needsUnlock: true) }, sleep: { XCTFail("must not wait") })
        XCTAssertTrue(text.contains("연결 인증"), text)
    }
}
