import CoreGraphics
import XCTest
@testable import Ppomi

final class AgentDockLayoutTests: XCTestCase {
    func testNaturalConversationWindowStaysBesidePhoneWithoutCoveringControls() throws {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let phone = CGRect(x: screen.maxX - 32 - 348, y: 159, width: 348, height: 766)
        let column = CGRect(x: 12, y: 8, width: phone.minX - 24, height: screen.height - 16)
        let header: CGFloat = 48, approval: CGFloat = 116, gap: CGFloat = 12
        let natural = CGSize(width: 920, height: 760)
        let frame = try XCTUnwrap(AgentDockLayout.frame(in: column, naturalSize: natural,
            minimumSize: CGSize(width: 600, height: 500), headerHeight: header, approvalHeight: approval, gap: gap))
        XCTAssertEqual(frame.size, natural)
        XCTAssertEqual(frame.midX, column.midX)
        XCTAssertEqual(frame.maxY, column.maxY - header - gap)
        XCTAssertGreaterThanOrEqual(frame.minY, column.minY + approval + gap)
        XCTAssertFalse(frame.intersects(phone))
        XCTAssertTrue(screen.contains(frame))
    }

    func testAlreadyReservedWorkbenchAreaDoesNotReserveApprovalTwice() throws {
        let area = CGRect(x: 12, y: 136, width: 536, height: 726)
        let frame = try XCTUnwrap(AgentDockLayout.frame(in: area,
            naturalSize: CGSize(width: 900, height: 800), minimumSize: CGSize(width: 500, height: 500),
            headerHeight: 42))
        XCTAssertEqual(frame, CGRect(x: 12, y: 136, width: 536, height: 672))
        XCTAssertEqual(frame.minY, area.minY)
        XCTAssertEqual(frame.maxY, area.maxY - 42 - 12)
    }

    func testSmallDisplayRefusesCompanionInsteadOfTakingApprovalSpace() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let phone = CGRect(x: 900, y: 0, width: 348, height: 766)
        let column = CGRect(x: screen.minX + 12, y: 8, width: phone.minX - 24, height: screen.height - 16)
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: CGSize(width: 700, height: 650),
            minimumSize: CGSize(width: 600, height: 550), headerHeight: 48, approvalHeight: 116))
        let tallApproval: CGFloat = 300 // Vertically stacked approval choices on a narrow display.
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: CGSize(width: 600, height: 450),
            minimumSize: CGSize(width: 500, height: 400), headerHeight: 48, approvalHeight: tallApproval))
    }

    func testNativeWindowsWidthCannotSqueezeCompanionBelowItsMinimum() {
        let desktop = CGRect(x: 404, y: 100, width: 1300, height: 820)
        let column = CGRect(x: 12, y: 136, width: desktop.minX - 24, height: 916)
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: CGSize(width: 900, height: 800),
            minimumSize: CGSize(width: 500, height: 450), headerHeight: 48))
        XCTAssertEqual(desktop, CGRect(x: 404, y: 100, width: 1300, height: 820))
    }

    func testResizeIsNativeReflowWithoutProportionalImageScaling() throws {
        let column = CGRect(x: 0, y: 0, width: 720, height: 900)
        let natural = CGSize(width: 1200, height: 600)
        let frame = try XCTUnwrap(AgentDockLayout.frame(in: column, naturalSize: natural,
            minimumSize: CGSize(width: 500, height: 450), headerHeight: 40, approvalHeight: 116))
        XCTAssertEqual(frame.size, CGSize(width: 720, height: 600))
        XCTAssertEqual(frame.maxY, 848)
        XCTAssertTrue(AgentDockLayout.accepts(actualSize: frame.size, in: column,
            headerHeight: 40, approvalHeight: 116))
    }

    func testActualNativeClampIsRecheckedBeforePlacement() throws {
        let column = CGRect(x: 12, y: 136, width: 600, height: 650)
        let requested = try XCTUnwrap(AgentDockLayout.frame(in: column,
            naturalSize: CGSize(width: 900, height: 800), minimumSize: CGSize(width: 500, height: 450), headerHeight: 48))
        XCTAssertEqual(requested.size, CGSize(width: 600, height: 590))
        XCTAssertTrue(AgentDockLayout.accepts(actualSize: requested.size, in: column, headerHeight: 48))
        XCTAssertFalse(AgentDockLayout.accepts(actualSize: CGSize(width: 640, height: 590), in: column, headerHeight: 48))
        XCTAssertFalse(AgentDockLayout.accepts(actualSize: CGSize(width: 600, height: 620), in: column, headerHeight: 48))
    }

    func testOffsetAndNegativeScreenOriginsPreserveClearance() throws {
        let column = CGRect(x: -1716, y: -712, width: 1000, height: 1000)
        let frame = try XCTUnwrap(AgentDockLayout.frame(in: column, naturalSize: CGSize(width: 800, height: 700),
            minimumSize: CGSize(width: 600, height: 400), headerHeight: 48, approvalHeight: 180))
        XCTAssertEqual(frame, CGRect(x: -1616, y: -472, width: 800, height: 700))
        XCTAssertGreaterThanOrEqual(frame.minY, column.minY + 192)
        XCTAssertEqual(frame.maxY, column.maxY - 60)
        XCTAssertTrue(column.contains(frame))
    }

    func testExactMinimumFitsAndInvalidGeometryNeverProducesADockFrame() throws {
        let column = CGRect(x: 10, y: 20, width: 600, height: 684)
        let size = CGSize(width: 600, height: 500)
        XCTAssertEqual(AgentDockLayout.frame(in: column, naturalSize: size, minimumSize: size,
            headerHeight: 44, approvalHeight: 116), CGRect(x: 10, y: 148, width: 600, height: 500))
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: .zero, minimumSize: size))
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: size, minimumSize: CGSize(width: -1, height: 500)))
        XCTAssertNil(AgentDockLayout.frame(in: .null, naturalSize: size, minimumSize: size))
        XCTAssertNil(AgentDockLayout.frame(in: .infinite, naturalSize: size, minimumSize: size))
        XCTAssertNil(AgentDockLayout.frame(in: CGRect(x: 0, y: 0, width: -600, height: 684), naturalSize: size, minimumSize: size))
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: size, minimumSize: size, headerHeight: -.infinity))
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: size, minimumSize: size, approvalHeight: 684))
        XCTAssertNil(AgentDockLayout.frame(in: column, naturalSize: size, minimumSize: size, gap: -1))
        XCTAssertFalse(AgentDockLayout.accepts(actualSize: CGSize(width: CGFloat.nan, height: 500), in: column))
    }
}
