import XCTest
@testable import Ppomi

final class MirroringRecoveryTests: XCTestCase {
    private func button(_ title: String, enabled: Bool = true) -> Mirroring.ButtonEvidence {
        .init(labels: [title], enabled: enabled)
    }
    private var connected: Mirroring.ConnectionSnapshot {
        Mirroring.connectionSnapshot(texts: ["iPhone 미러링"], buttons: [button("홈"), button("앱 전환기")])
    }
    private var retryable: Mirroring.ConnectionSnapshot {
        Mirroring.connectionSnapshot(texts: ["iPhone 사용 중", "iPhone을 잠그십시오"], buttons: [button("다시 시도")])
    }

    func testRecoveryButtonRequiresExactEnabledUniqueNativeEvidence() {
        for title in Mirroring.reconnectLabels {
            XCTAssertTrue(Mirroring.connectionSnapshot(texts: ["연결이 중단됨"], buttons: [button(title)]).canReconnect, title)
        }
        for buttons in [[], [button("연결", enabled: false)], [button("다시 시도 도움말")],
                        [button("연결 취소")], [button("연결"), button("다시 시도")]] {
            XCTAssertFalse(Mirroring.connectionSnapshot(texts: ["연결이 중단됨", "연결"], buttons: buttons).canReconnect)
        }
        XCTAssertTrue(Mirroring.connectionSnapshot(texts: ["연결이 중단됨"], buttons: [
            .init(labels: ["다시 시도", "다시 시도"], enabled: true)
        ]).canReconnect, "one button's title and description are not duplicate controls")
    }

    func testInUseAndRecoveryAvailabilityAreIndependent() {
        XCTAssertEqual(retryable.state, .inUse)
        XCTAssertTrue(retryable.inUse)
        XCTAssertTrue(retryable.canReconnect)
        XCTAssertFalse(retryable.connected)
        let withoutButton = Mirroring.connectionSnapshot(texts: ["iPhone 사용 중"], buttons: [])
        XCTAssertEqual(withoutButton.state, .inUse); XCTAssertFalse(withoutButton.canReconnect)
        XCTAssertEqual(Mirroring.classify(["KB 앱 사용 중"]), .connected, "unrelated app prose does not prove physical iPhone use")
    }

    func testConnectedRequiresBothEnabledNativeStreamControls() {
        XCTAssertTrue(connected.connected)
        XCTAssertTrue(Mirroring.connectionSnapshot(texts: ["iPhone Mirroring"], buttons: [button("Home"), button("App Switcher")]).connected)
        for buttons in [[], [button("홈")], [button("앱 전환기")], [button("홈", enabled: false), button("앱 전환기")]] {
            XCTAssertFalse(Mirroring.connectionSnapshot(texts: ["홈", "앱 전환기", "KB스타뱅킹"], buttons: buttons).connected)
        }
        for text in ["연결 중…", "Connecting…", "iPhone 잠금 해제", "iPhone 사용 중"] {
            XCTAssertFalse(Mirroring.connectionSnapshot(texts: [text], buttons: [button("홈"), button("앱 전환기")]).connected)
        }
        XCTAssertFalse(Mirroring.connectionSnapshot(texts: ["iPhone 미러링"], buttons: [button("홈"), button("앱 전환기"), button("연결", enabled: false)]).connected)
        XCTAssertFalse(Mirroring.connectionSnapshot(texts: [], buttons: []).connected)
        XCTAssertEqual(Mirroring.classify([]), .disconnected)
        XCTAssertEqual(Mirroring.classify(["연결 중…"]), .disconnected)
    }

    func testOnePressCanRecoverPreviouslyInUseOverlay() throws {
        let waiting = Mirroring.connectionSnapshot(texts: ["연결 중…"], buttons: [])
        var frames = [retryable, waiting, connected], presses = 0, waits = 0
        let final = Mirroring.recoverOnce(observe: { frames.removeFirst() }, press: { presses += 1; return true }, settle: { waits += 1 })
        XCTAssertTrue(final.connected); XCTAssertEqual(presses, 1); XCTAssertEqual(waits, 2)
        XCTAssertNoThrow(try Phone.requireConnected(final))
    }

    func testUnchangedOverlayNeverPressesTwiceAndDoesNotClaimConnection() {
        var presses = 0, reads = 0
        let final = Mirroring.recoverOnce(observe: { reads += 1; return self.retryable }, press: { presses += 1; return true }, settle: {}, polls: 100)
        XCTAssertEqual(presses, 1); XCTAssertEqual(reads, 7); XCTAssertFalse(final.connected)
        XCTAssertThrowsError(try Phone.requireConnected(final)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("미러링 앱이")); XCTAssertTrue(message.contains("사용 중"))
            XCTAssertFalse(message.contains("잠금 해제)이라"))
        }
    }

    func testDisabledAmbiguousAbsentAndPhysicalUnlockStatesNeverPress() {
        let snapshots = [
            Mirroring.connectionSnapshot(texts: [], buttons: [], hasWindow: false),
            Mirroring.connectionSnapshot(texts: [], buttons: []),
            Mirroring.connectionSnapshot(texts: ["iPhone 사용 중"], buttons: []),
            Mirroring.connectionSnapshot(texts: ["연결이 중단됨"], buttons: [button("연결", enabled: false)]),
            Mirroring.connectionSnapshot(texts: ["연결이 중단됨"], buttons: [button("연결"), button("재개")]),
            Mirroring.connectionSnapshot(texts: ["iPhone 잠금 해제"], buttons: [button("연결")])
        ]
        for snapshot in snapshots {
            let final = Mirroring.recoverOnce(observe: { snapshot }, press: { XCTFail("must not press"); return true }, settle: { XCTFail("must not poll") })
            XCTAssertFalse(final.connected); XCTAssertThrowsError(try Phone.requireConnected(final))
        }
    }

    func testFailedNativePressReobservesWithoutRetry() {
        var reads = 0, presses = 0
        let final = Mirroring.recoverOnce(observe: { reads += 1; return self.retryable }, press: { presses += 1; return false }, settle: { XCTFail("must not poll") })
        XCTAssertEqual(reads, 2); XCTAssertEqual(presses, 1); XCTAssertFalse(final.connected)
    }

    func testConnectingWithoutButtonWaitsForEvidenceAndNeverPresses() {
        let waiting = Mirroring.connectionSnapshot(texts: ["연결 중…"], buttons: [])
        var frames = [waiting, connected]
        XCTAssertTrue(Mirroring.recoverOnce(observe: { frames.removeFirst() }, press: { XCTFail("must not press"); return false }, settle: {}).connected)
        let final = Mirroring.recoverOnce(observe: { waiting }, press: { XCTFail("must not press"); return false }, settle: {})
        XCTAssertFalse(final.connected); XCTAssertThrowsError(try Phone.requireConnected(final))
    }

    func testAlreadyConnectedDoesNotPressOrPoll() {
        let final = Mirroring.recoverOnce(observe: { self.connected }, press: { XCTFail("must not press"); return false }, settle: { XCTFail("must not poll") })
        XCTAssertTrue(final.connected)
    }

    func testBackgroundPolicyNeverPressesAnInUseMessageEvenBesideConnectingText() {
        for snapshot in [retryable, Mirroring.connectionSnapshot(texts: ["연결 중…", "iPhone 사용 중"], buttons: [button("연결")])] {
            XCTAssertTrue(snapshot.inUse)
            let final = Mirroring.recoverOnce(observe: { snapshot }, press: { XCTFail("watcher must not press"); return false },
                settle: { XCTFail("watcher must not wait on human use") }, allowInUse: false)
            XCTAssertFalse(final.connected)
        }
        let disconnected = Mirroring.connectionSnapshot(texts: ["연결이 중단됨"], buttons: [button("다시 시도")])
        var frames = [disconnected, connected], presses = 0
        XCTAssertTrue(Mirroring.recoverOnce(observe: { frames.removeFirst() }, press: { presses += 1; return true }, settle: {}, allowInUse: false).connected)
        XCTAssertEqual(presses, 1)
    }

    func testRecoveryLeaseIsExclusiveAndSeparateFromSharedScreenControl() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-mirror-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        let alias = directory.appendingPathComponent("alias.db").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        let control = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: path))
        defer { control.release() }
        let recovery = try XCTUnwrap(ScreenControlLease.beginMirroringRecovery(ledgerPath: path))
        XCTAssertNil(try ScreenControlLease.beginMirroringRecovery(ledgerPath: path), "watcher and explicit gate cannot recover concurrently")
        XCTAssertNil(try ScreenControlLease.beginMirroringRecovery(ledgerPath: alias), "a ledger symlink cannot create a second recovery lock")
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: path), "records focus remains blocked throughout control")
        recovery.release()
        let next = try XCTUnwrap(ScreenControlLease.beginMirroringRecovery(ledgerPath: path))
        next.release()
    }

    func testPhoneGateRecoversBeforeRefusingOldInUseAndNeverCapturesWhenRecoveryFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-mirror-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Tools.fake = nil; try? FileManager.default.removeItem(at: directory) }
        let tools = try Tools(db: DB(path: directory.appendingPathComponent("ledger.db").path, writable: true))
        tools.currentText = "폰에서 읽어줘"
        tools.phoneGateStatus = { (true, "IN_USE") }
        var captures = 0, presses = 0
        Tools.fake = (screen: { captures += 1; return [OCR.Word(x: 0.2, y: 0.3, w: 0.2, h: 0.03, text: "합성 홈")] },
                      hand: { _ in XCTFail("no phone input expected") })
        var frames = [retryable, connected]
        tools.wakePhone = {
            try Phone.requireConnected(Mirroring.recoverOnce(observe: { frames.removeFirst() }, press: { presses += 1; return true }, settle: {}))
        }
        XCTAssertTrue(tools.execute("phone_screen", [:]).contains("합성 홈"))
        XCTAssertEqual(presses, 1); XCTAssertEqual(captures, 1)

        tools.wakePhone = {
            try Phone.requireConnected(Mirroring.recoverOnce(observe: { self.retryable }, press: { presses += 1; return true }, settle: {}))
        }
        XCTAssertTrue(tools.execute("phone_screen", [:]).hasPrefix("실행 안 함:"))
        XCTAssertEqual(presses, 2); XCTAssertEqual(captures, 1)
    }

    func testWakeAcceptsCLIConnectedWhenAXChromeButtonsAreMissing() {
        let empty = Mirroring.connectionSnapshot(texts: [], buttons: [])
        XCTAssertFalse(empty.connected)
        XCTAssertTrue(Phone.acceptsStream(empty, cliState: "CONNECTED"))
        XCTAssertFalse(Phone.acceptsStream(empty, cliState: "IN_USE"))
        XCTAssertFalse(Phone.acceptsStream(empty, cliState: "NONE"))
        XCTAssertFalse(Phone.acceptsStream(retryable, cliState: "CONNECTED"))
        let unlock = Mirroring.connectionSnapshot(texts: ["iPhone 잠금 해제"], buttons: [])
        XCTAssertTrue(unlock.needsUnlock)
        XCTAssertFalse(Phone.acceptsStream(unlock, cliState: "CONNECTED"))
        XCTAssertTrue(Phone.acceptsStream(connected, cliState: "DISCONNECTED"))
    }
}
