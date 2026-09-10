import XCTest
import AppKit
@testable import Ppomi

final class VisualLiveTests: XCTestCase {
    /// Opt in explicitly: one paid request, using a synthetic shape, never a real device or document.
    func testSyntheticShapeOnConfiguredOpenAIAccount() throws {
        guard ProcessInfo.processInfo.environment["PPOMI_VISION_LIVE_TEST"] == "1" else {
            throw XCTSkip("Explicit opt-in required for a paid, synthetic-screen API check")
        }
        let image = NSImage(size: NSSize(width: 800, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 80, y: 390, width: 160, height: 120).fill()
        NSColor.systemYellow.setFill()
        NSRect(x: 520, y: 90, width: 160, height: 120).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-vlm-synthetic-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let text = try VisualInspector(model: AppSettings.visionModel).inspect(
            png: png, words: [], question: "노란색 사각형 중심의 위치를 알려 줘.", surface: "windows")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let target = try XCTUnwrap(result["target"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(target["x"] as? Double), 0.75, accuracy: 0.10)
        XCTAssertEqual(try XCTUnwrap(target["y"] as? Double), 0.75, accuracy: 0.10)
        print("Synthetic VLM check: \(text)")
    }
}
