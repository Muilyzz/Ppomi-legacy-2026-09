import XCTest
import CoreGraphics
@testable import Ppomi

final class AgentWindowTests: XCTestCase {
    private let rect = CGRect(x: 200, y: 80, width: 800, height: 760)

    func testIdentityRequiresBothVerifiedBundleAndInstalledExecutable() {
        let executable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        let installed: Set<String> = [executable]
        XCTAssertTrue(AgentWindowPolicy.matchesProcess(bundleID: "com.openai.codex", executablePath: executable,
            expectedBundleID: "com.openai.codex", installedExecutables: installed))
        XCTAssertFalse(AgentWindowPolicy.matchesProcess(bundleID: "com.openai.chat", executablePath: executable,
            expectedBundleID: "com.openai.codex", installedExecutables: installed))
        XCTAssertFalse(AgentWindowPolicy.matchesProcess(bundleID: "com.openai.codex", executablePath: "/tmp/ChatGPT",
            expectedBundleID: "com.openai.codex", installedExecutables: installed))
        XCTAssertFalse(AgentWindowPolicy.matchesProcess(bundleID: nil, executablePath: executable,
            expectedBundleID: "com.openai.codex", installedExecutables: installed))
        XCTAssertFalse(AgentWindowPolicy.matchesProcess(bundleID: "com.openai.codex", executablePath: nil,
            expectedBundleID: "com.openai.codex", installedExecutables: installed))
    }

    func testInitialSelectionPrefersMainConversationThenDeterministicID() {
        let main = candidate(21, isMain: true)
        let large = candidate(20, rect: CGRect(x: 0, y: 0, width: 1200, height: 900))
        XCTAssertEqual(AgentWindowPolicy.select([large, main], preferredID: nil)?.id, 21)
        XCTAssertEqual(AgentWindowPolicy.select([candidate(12), candidate(11)], preferredID: nil)?.id, 11)
        XCTAssertEqual(AgentWindowPolicy.select([candidate(11), candidate(12)], preferredID: nil)?.id, 11)
    }

    func testChosenWindowRemainsStableWhenAnotherWindowBecomesMain() {
        let chosen = candidate(11), newMain = candidate(12, isMain: true)
        XCTAssertEqual(AgentWindowPolicy.select([newMain, chosen], preferredID: 11)?.id, 11)
        XCTAssertEqual(AgentWindowPolicy.select([chosen, newMain], preferredID: 11)?.id, 11)
        XCTAssertEqual(AgentWindowPolicy.select([newMain], preferredID: 11)?.id, 12)
    }

    func testMinimizedPreferredWindowCanBeRestoredWithoutChoosingAnotherChat() {
        let minimized = candidate(11, isOnScreen: false), onScreen = candidate(12, isMain: true)
        XCTAssertEqual(AgentWindowPolicy.select([onScreen, minimized], preferredID: 11)?.id, 11)
        XCTAssertEqual(AgentWindowPolicy.select([onScreen, minimized], preferredID: nil)?.id, 12)
    }

    func testIgnoresCompanionPanelsModalDialogsAndSystemLayers() {
        let small = candidate(10, isMain: true, rect: CGRect(x: 0, y: 0, width: 460, height: 300))
        let panel = candidate(11, isStandard: false, isMain: true)
        let modal = candidate(12, isModal: true, isMain: true)
        let overlay = candidate(13, layer: 20)
        let main = candidate(14)
        XCTAssertEqual(AgentWindowPolicy.select([small, panel, modal, overlay, main], preferredID: 12)?.id, 14)
        XCTAssertNil(AgentWindowPolicy.select([small, panel, modal, overlay], preferredID: 12))
    }

    func testFrameMatchingRejectsAnimationsAndInvalidGeometry() {
        XCTAssertTrue(AgentWindowPolicy.framesMatch(rect, rect.offsetBy(dx: 1, dy: -1)))
        XCTAssertFalse(AgentWindowPolicy.framesMatch(rect, rect.offsetBy(dx: 3, dy: 0)))
        XCTAssertFalse(AgentWindowPolicy.framesMatch(rect, CGRect(x: 200, y: 80, width: 780, height: 760)))
        XCTAssertFalse(AgentWindowPolicy.usableFrame(CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 760)))
        XCTAssertFalse(AgentWindowPolicy.usableFrame(CGRect(x: 0, y: 0, width: -800, height: 760)))
        XCTAssertFalse(AgentWindowPolicy.usableFrame(CGRect(x: 0, y: 0, width: 800, height: CGFloat.nan)))
        XCTAssertNil(AgentWindowPolicy.select([candidate(11, axRect: rect.offsetBy(dx: 50, dy: 0))], preferredID: 11))
    }

    func testAmbiguousSameFrameMatchesCannotSelectTheWrongAXWindow() {
        let duplicate = candidate(11), alternative = candidate(12)
        XCTAssertNil(AgentWindowPolicy.select([duplicate, duplicate], preferredID: 11))
        XCTAssertEqual(AgentWindowPolicy.select([duplicate, duplicate, alternative], preferredID: 11)?.id, 12)
    }

    func testPairedApplicationsDoNotCauseSpuriousRevealButForeignWindowDoes() {
        let agent = MirroringOrder.Window(id: 11, owner: 100, layer: 0)
        let ppomi = MirroringOrder.Window(id: 20, owner: 200, layer: 0)
        let phone = MirroringOrder.Window(id: 30, owner: 300, layer: 0)
        let foreign = MirroringOrder.Window(id: 40, owner: 400, layer: 0)
        let system = MirroringOrder.Window(id: 50, owner: 500, layer: 24)
        let allowed: Set<pid_t> = [200, 300]
        XCTAssertTrue(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: allowed,
            windows: [system, ppomi, phone, agent, foreign]))
        XCTAssertFalse(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: allowed,
            windows: [ppomi, foreign, phone, agent]))
        XCTAssertFalse(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: [200],
            windows: [phone, agent]))
        XCTAssertFalse(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: allowed, windows: [ppomi, phone]))
        XCTAssertFalse(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: allowed,
            windows: [.init(id: 11, owner: 300, layer: 0)]))
        XCTAssertFalse(AgentWindowPolicy.isInFront(id: 11, pid: 100, allowedPIDs: allowed,
            windows: [.init(id: 11, owner: 100, layer: 3)]))
    }

    private func candidate(_ id: CGWindowID, isStandard: Bool = true, isModal: Bool = false,
                           isMain: Bool = false, isOnScreen: Bool = true, layer: Int = 0,
                           rect: CGRect? = nil, axRect: CGRect? = nil) -> AgentWindowPolicy.Candidate {
        let frame = rect ?? self.rect
        return .init(id: id, pid: 100, rect: frame, axRect: axRect ?? frame, isStandard: isStandard,
                     isModal: isModal, isMain: isMain, isOnScreen: isOnScreen, layer: layer)
    }
}
