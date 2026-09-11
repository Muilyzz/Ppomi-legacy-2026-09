import Darwin
import Foundation
import XCTest
@testable import Ppomi

final class ScreenControlLeaseTests: XCTestCase {
    private var directory: URL!
    private var ledgerPath: String { directory.appendingPathComponent("ledger.db").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiFocus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAllScreenFamiliesAndCompositeToolsRequireVisibleSurfaces() {
        for name in ["phone_screen", "phone_tap", "phone_installed", "phone_future_tool", "windows_screen",
                     "windows_open", "windows_future_tool", "android_screen", "android_open", "android_future_tool",
                     "run_combo", "inbody_capture", "collect_now", "screen_inspect", "profile_fill", "browser_open"] {
            XCTAssertTrue(ScreenControlLease.requiresVisibleSurface(tool: name), name)
        }
        for name in ["android_status", "accounting_records", "accounting_import", "accounting_reclassify",
                     "accounting_template", "health_records", "record_health", "today_spending", "balances",
                     "profile_status", "profile_save", "profile_delete", "web_text", "pay_preference"] {
            XCTAssertFalse(ScreenControlLease.requiresVisibleSurface(tool: name), name)
        }
        XCTAssertTrue(ScreenControlLease.blockedMessage.hasPrefix("실행 안 함:"))
        XCTAssertTrue(ScreenControlLease.blockedMessage.contains("제어로 돌아가기"))
    }

    func testSharedCallsPreventFocusUntilEveryCallFinishes() throws {
        let first = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        let second = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        defer { first.release(); second.release() }
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        first.release()
        first.release()
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: ledgerPath), "Closing a different descriptor must not release the second call")
        second.release()
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        focus.release()
    }

    func testFocusedRecordsRejectNewCallsAndOtherFocusOwners() throws {
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        // Failed contenders close their own descriptors; they must leave the focus lock intact.
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        focus.release()
        let next = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        next.release()
    }

    func testDeinitializationReleasesFocusWithoutPersistedStaleState() throws {
        var focus: ScreenControlLease? = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        XCTAssertNotNil(focus)
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        focus = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: ScreenControlLease.path(for: ledgerPath)))
        let call = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        call.release()
    }

    func testParallelReleaseIsIdempotentAndDoesNotReleaseAnotherCall() throws {
        let first = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        let other = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        defer { first.release(); other.release() }
        DispatchQueue.concurrentPerform(iterations: 20) { _ in first.release() }
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        other.release()
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        focus.release()
    }

    func testCanonicalPathsCoordinateButDifferentLedgersDoNot() throws {
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let aliasPath = alias.appendingPathComponent("ledger.db").path
        XCTAssertEqual(ScreenControlLease.path(for: ledgerPath), ScreenControlLease.path(for: aliasPath))
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: aliasPath))
        let separate = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: directory.appendingPathComponent("other.db").path))
        separate.release()
    }

    func testMissingParentFailsClosedWithoutCreatingUserDirectories() throws {
        let absent = directory.appendingPathComponent("absent")
        XCTAssertThrowsError(try ScreenControlLease.beginFocus(ledgerPath: absent.appendingPathComponent("ledger.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testLockFileIsPrivateAndCannotFollowSymlinks() throws {
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        let attributes = try FileManager.default.attributesOfItem(atPath: ScreenControlLease.path(for: ledgerPath))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        focus.release()
        let otherPath = directory.appendingPathComponent("other.db").path
        let target = directory.appendingPathComponent("untouched.txt")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: ScreenControlLease.path(for: otherPath), withDestinationPath: target.path)
        XCTAssertThrowsError(try ScreenControlLease.beginFocus(ledgerPath: otherPath))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testFocusBlocksControlInAnotherProcessUntilRestored() throws {
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        defer { focus.release() }
        XCTAssertEqual(try childLockAttempt("LOCK_SH"), 2)
        XCTAssertEqual(try childLockAttempt("LOCK_EX"), 2)
        XCTAssertNil(try ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        focus.release()
        XCTAssertEqual(try childLockAttempt("LOCK_SH"), 0)
    }

    func testOtherProcessControlBlocksFocusAndProcessExitReleasesItsLock() throws {
        let executable = "/usr/bin/perl"
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: executable), "The cross-process lock probe needs macOS Perl")
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-MFcntl=:flock,:DEFAULT", "-e", """
            alarm(5);
            $| = 1;
            sysopen(my $handle, $ARGV[0], O_RDWR | O_CREAT, 0600) or exit 3;
            flock($handle, LOCK_SH | LOCK_NB) or exit 2;
            print "1";
            scalar <STDIN>;
            """, ScreenControlLease.path(for: ledgerPath)]
        child.standardInput = input
        child.standardOutput = output
        let finished = expectation(description: "Kernel closes the separate process's lock on exit")
        child.terminationHandler = { _ in finished.fulfill() }
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        try output.fileHandleForWriting.close()
        // The child's alarm bounds this handshake even if acquiring its lock unexpectedly fails.
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("1".utf8))
        XCTAssertNil(try ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        let alongside = try XCTUnwrap(ScreenControlLease.beginControl(ledgerPath: ledgerPath))
        alongside.release()
        XCTAssertEqual(Darwin.kill(child.processIdentifier, SIGKILL), 0)
        wait(for: [finished], timeout: 5)
        let focus = try XCTUnwrap(ScreenControlLease.beginFocus(ledgerPath: ledgerPath))
        focus.release()
    }

    /// Perl ships with macOS and exposes the same flock syscall without building a helper executable.
    private func childLockAttempt(_ operation: String) throws -> Int32 {
        let executable = "/usr/bin/perl"
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: executable), "The cross-process lock probe needs macOS Perl")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-MFcntl=:flock,:DEFAULT", "-e", """
            alarm(3);
            sysopen(my $handle, $ARGV[0], O_RDWR | O_CREAT, 0600) or exit 3;
            exit(flock($handle, \(operation) | LOCK_NB) ? 0 : 2);
            """, ScreenControlLease.path(for: ledgerPath)]
        let finished = expectation(description: "Separate process finishes its nonblocking lock attempt")
        child.terminationHandler = { _ in finished.fulfill() }
        try child.run()
        wait(for: [finished], timeout: 5)
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        return child.terminationStatus
    }
}
