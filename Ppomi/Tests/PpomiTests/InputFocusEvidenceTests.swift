import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Ppomi

final class InputFocusEvidenceTests: XCTestCase {
    private var directory: URL!
    private let width = 1000, height = 800

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private struct Rectangle {
        var x = 560, y = 250, width = 240, height = 36, shade: UInt8 = 68
        var sides = true, bottom = true
    }

    private func fixture(_ rectangles: [Rectangle] = [], black: Bool = false, text: Bool = false) throws -> URL {
        var pixels = [UInt8](repeating: black ? 0 : 255, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        func set(_ x: Int, _ y: Int, _ shade: UInt8) {
            for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = shade }
        }
        for box in rectangles {
            for x in box.x..<(box.x + box.width) {
                set(x, box.y, box.shade)
                if box.bottom { set(x, box.y + box.height - 1, box.shade) }
            }
            if box.sides {
                for y in box.y..<(box.y + box.height) { set(box.x, y, box.shade); set(box.x + box.width - 1, y, box.shade) }
            }
        }
        if text {
            // A row of disconnected E-shaped glyphs, with long total text width but no four-sided field outline.
            for start in stride(from: 570, to: 780, by: 14) {
                for y in 256..<279 { set(start, y, 30) }
                for x in start..<(start + 9) { for y in [256, 267, 278] { set(x, y, 30) } }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }

    func testFocusedTargetAcceptsDarkRectangleAndLeavesSourceUnchanged() throws {
        let image = try fixture([Rectangle()], text: true), data = try Data(contentsOf: image)
        XCTAssertTrue(try InputFocusEvidence.focused(png: image, x: 0.68, y: 0.335))
        XCTAssertEqual(try Data(contentsOf: image), data)
    }

    func testInactiveOrFocusInAnotherFieldDoesNotAuthorizeTarget() throws {
        let inactive = Rectangle(shade: 204)
        XCTAssertFalse(try InputFocusEvidence.focused(png: fixture([inactive]), x: 0.68, y: 0.335))
        XCTAssertFalse(try InputFocusEvidence.focused(png: fixture([inactive, Rectangle(y: 350)]), x: 0.68, y: 0.335))
        XCTAssertFalse(try InputFocusEvidence.focused(png: fixture([Rectangle(), Rectangle(y: 350)]), x: 0.68, y: 0.335))
    }

    func testTextPartialBordersAndBlankFramesAreNotFocusEvidence() throws {
        for file in [try fixture(text: true), try fixture([Rectangle(sides: false)]),
                     try fixture([Rectangle(bottom: false)]), try fixture(), try fixture(black: true)] {
            XCTAssertFalse(try InputFocusEvidence.focused(png: file, x: 0.68, y: 0.335))
        }
    }

    func testWrongDimensionsBorderClicksAndOutOfBoundsFailClosed() throws {
        XCTAssertFalse(try InputFocusEvidence.focused(png: fixture([Rectangle(width: 30)]), x: 0.575, y: 0.335))
        XCTAssertFalse(try InputFocusEvidence.focused(png: fixture([Rectangle(height: 90)]), x: 0.68, y: 0.36))
        let image = try fixture([Rectangle()])
        XCTAssertFalse(try InputFocusEvidence.focused(png: image, x: 0.56, y: 0.335))
        for point in [(-0.1, 0.3), (0.7, 1.1), (Double.nan, 0.3), (0.7, Double.infinity), (0.0, 0.0)] {
            XCTAssertFalse(try InputFocusEvidence.focused(png: image, x: point.0, y: point.1))
        }
        XCTAssertThrowsError(try InputFocusEvidence.focused(png: directory.appendingPathComponent("missing.png"), x: 0.7, y: 0.3))
    }
}
