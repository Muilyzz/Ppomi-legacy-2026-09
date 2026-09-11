import AppKit
import XCTest
@testable import Ppomi

/// 평상시(제어 창 없음)엔 기록이 제어 열에 보이고, 그때도 페이지가 살아 있어야 한다: layout 이 보임 여부를 알린다.
@MainActor final class RecordsVisibilityTests: XCTestCase {
    func testLayoutReportsRecordsOnScreenForFocusAndIdleStatusView() {
        _ = NSApplication.shared
        let content = WorkbenchContent(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        var seen: [Bool] = []
        content.onRecordsVisibility = { seen.append($0) }
        content.layout()                                   // 자리 힌트 없음, 집중 아님 → 기록 안 보임
        content.phoneSlot.hint = "iPhone · 연결 끊김"       // 평상시: 힌트가 있으면 상태 뷰
        content.layout()
        content.recordsFocused = true                       // 집중
        content.phoneSlot.hint = ""
        content.layout()
        XCTAssertEqual(seen, [false, true, true])
        XCTAssertFalse(content.recordsArea.isHidden)
    }
}
