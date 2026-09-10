import AppKit
import XCTest
@testable import Ppomi

final class AndroidWindowTests: XCTestCase {
    private let frame = CGRect(x: 120, y: 80, width: 360, height: 760)

    func testExecutableIdentityRequiresAnInstalledPathBeforeUsingTheWindowTitle() {
        let mirror = "/opt/homebrew/Cellar/scrcpy/4.1_1/bin/scrcpy"
        let emulator = "/Users/person/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"
        XCTAssertEqual(AndroidWindowPolicy.kind(executablePath: mirror, mirrorPaths: [mirror], emulatorPaths: [emulator]), .mirror)
        XCTAssertEqual(AndroidWindowPolicy.kind(executablePath: emulator, mirrorPaths: [mirror], emulatorPaths: [emulator]), .emulator)
        for unrelated in [nil, "/tmp/scrcpy", "/tmp/qemu-system-aarch64"] {
            XCTAssertNil(AndroidWindowPolicy.kind(executablePath: unrelated, mirrorPaths: [mirror], emulatorPaths: [emulator]))
        }
    }

    func testOnlyThePpomiMirrorAndEmulatorDisplayQualify() {
        XCTAssertTrue(AndroidWindowPolicy.acceptsTitle("Ppomi Android", kind: .mirror))
        XCTAssertFalse(AndroidWindowPolicy.acceptsTitle("Pixel 8", kind: .mirror))
        XCTAssertFalse(AndroidWindowPolicy.acceptsTitle("Ppomi Android settings", kind: .mirror))
        XCTAssertTrue(AndroidWindowPolicy.acceptsTitle("Android Emulator - Pixel_8_API_35:5554", kind: .emulator))
        XCTAssertFalse(AndroidWindowPolicy.acceptsTitle("Extended controls", kind: .emulator))
        XCTAssertFalse(AndroidWindowPolicy.acceptsTitle("Ppomi Android", kind: .emulator))
    }

    func testMirrorSupersedesEmulatorAndRemainsTheRevealTargetWhenMinimized() {
        let emulator = candidate(1, kind: .emulator, main: true)
        let mirror = candidate(2, onScreen: false)
        let selected = AndroidWindowPolicy.select([emulator, mirror], preferredID: emulator.id)
        XCTAssertEqual(selected?.id, mirror.id)
        XCTAssertEqual(selected?.isOnScreen, false)
        XCTAssertEqual(AndroidWindowPolicy.select([emulator], preferredID: mirror.id)?.id, emulator.id)
    }

    func testResizingMirrorDoesNotRedirectToEmulatorAndAmbiguousFramesAreRejected() {
        let emulator = candidate(1, kind: .emulator)
        let moving = candidate(2, axFrame: frame.offsetBy(dx: 10, dy: 0))
        XCTAssertNil(AndroidWindowPolicy.select([emulator, moving], preferredID: moving.id, mirrorPresent: true))
        let mirror = candidate(3)
        XCTAssertNil(AndroidWindowPolicy.select([mirror, mirror], preferredID: mirror.id))
        XCTAssertNil(AndroidWindowPolicy.select([candidate(4, standard: false), candidate(5, layer: 3)], preferredID: nil))
    }

    func testCompactPortraitFitsShortPaneWhileDesktopKeepsItsMinimumWidth() throws {
        let available = CGSize(width: 500, height: 484)
        let target = try XCTUnwrap(AndroidWindowPolicy.compactSize(current: frame.size, available: available))
        XCTAssertLessThan(target.width, 240)
        XCTAssertLessThanOrEqual(target.height, available.height - 16)
        XCTAssertEqual(target.width / target.height, frame.width / frame.height, accuracy: 0.001)
        XCTAssertNil(WorkSurfaceCompactLayout.size(current: frame.size, available: available))
        XCTAssertNil(AndroidWindowPolicy.compactSize(current: frame.size, available: CGSize(width: 100, height: 100)))
        XCTAssertFalse(AndroidWindowPolicy.framesMatch(frame, frame.offsetBy(dx: .infinity, dy: 0)))
    }

    /// Opt-in integration check uses the same native adapter as the workbench and restores its geometry.
    @MainActor func testLiveMirrorCanBeMeasuredCompactedAndPlaced() throws {
        guard ProcessInfo.processInfo.environment["PPOMI_ANDROID_WINDOW_LIVE"] == "1" else {
            throw XCTSkip("Set PPOMI_ANDROID_WINDOW_LIVE=1 with the Ppomi Android mirror running")
        }
        XCTAssertTrue(AndroidWindow.hasMirror)
        let original = try XCTUnwrap(AndroidWindow.liveWindow())
        XCTAssertEqual(AndroidWindow.axFrame(), original.rect)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
        defer {
            _ = AndroidWindow.resize(original.rect.size)
            settle()
            AndroidWindow.place(original.rect.origin)
            settle()
        }
        let available = CGSize(width: 540, height: 600)
        XCTAssertTrue(AndroidWindow.requestCompactSize(available: available))
        settle()
        let compact = try XCTUnwrap(AndroidWindow.liveWindow())
        XCTAssertEqual(compact.id, original.id)
        XCTAssertLessThanOrEqual(compact.rect.width, available.width)
        XCTAssertLessThanOrEqual(compact.rect.height, available.height)
        XCTAssertEqual(AndroidWindow.axFrame(), compact.rect)
        let moved = CGPoint(x: original.rect.minX + 20, y: original.rect.minY + 20)
        AndroidWindow.place(moved)
        settle()
        let placed = try XCTUnwrap(AndroidWindow.liveWindow())
        XCTAssertEqual(placed.id, original.id)
        XCTAssertEqual(placed.rect.minX, moved.x, accuracy: 2)
        XCTAssertEqual(placed.rect.minY, moved.y, accuracy: 2)
        print("Android live mirror: \(original.rect) → compact \(compact.rect) → placed \(placed.rect)")
    }

    private func candidate(_ id: CGWindowID, kind: AndroidWindowPolicy.Kind = .mirror,
                           main: Bool = false, onScreen: Bool = true, standard: Bool = true,
                           layer: Int = 0, axFrame: CGRect? = nil) -> AndroidWindowPolicy.Candidate {
        .init(id: id, pid: kind == .mirror ? 100 : 200, kind: kind,
              title: kind == .mirror ? "Ppomi Android" : "Android Emulator - Pixel_8_API_35:5554",
              rect: frame, axRect: axFrame ?? frame, isStandard: standard, isMain: main, isOnScreen: onScreen, layer: layer)
    }
}
