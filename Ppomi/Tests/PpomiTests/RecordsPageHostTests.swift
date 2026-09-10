import AppKit
import XCTest
@testable import Ppomi

final class RecordsPageHostTests: XCTestCase {
    @MainActor func testNavigationCreatesPagesLazilyAndPreservesTheirNativeState() throws {
        _ = NSApplication.shared
        let host = RecordsPageHost(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        var creations: [AppState.Tab] = []
        let timeline = NSTextField(string: "선택한 날짜와 기간")
        let health = NSSegmentedControl(labels: ["전체", "3개월"], trackingMode: .selectOne, target: nil, action: nil)
        let makePage: (AppState.Tab) -> NSView = { tab in
            creations.append(tab)
            return tab == .timeline ? timeline : health
        }
        host.select(.timeline, makePage: makePage)
        timeline.stringValue = "유지할 입력"
        host.select(.health, makePage: makePage)
        health.selectedSegment = 1
        host.select(.timeline, makePage: makePage)
        host.select(.health, makePage: makePage)
        host.frame.size = CGSize(width: 640, height: 500)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(creations, [.timeline, .health])
        XCTAssertEqual(host.subviews.count, 2)
        XCTAssertEqual(timeline.stringValue, "유지할 입력")
        XCTAssertEqual(health.selectedSegment, 1)
        XCTAssertTrue(timeline.isHidden)
        XCTAssertFalse(health.isHidden)
        XCTAssertTrue(timeline.superview === host)
        XCTAssertTrue(health.superview === host)
        XCTAssertEqual(health.frame, host.bounds)
        XCTAssertEqual(host.subviews.filter { !$0.isHidden }.count, 1)
    }
}
