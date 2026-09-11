import AppKit
import XCTest
@testable import Ppomi

final class PaletteFontsTests: XCTestCase {
    private func hex(_ color: NSColor, _ appearance: NSAppearance.Name) -> String {
        var c = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB)! }
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private func alpha(_ color: NSColor, _ appearance: NSAppearance.Name) -> CGFloat {
        var c = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB)! }
        return c.alphaComponent
    }

    func testPaletteReadsTheGeneratedValuesInBothAppearances() {
        XCTAssertEqual(hex(Palette.surface2, .darkAqua), String(ThemeColors.dark.surface2.prefix(7)))
        XCTAssertEqual(hex(Palette.accent, .aqua), ThemeColors.accent)
        XCTAssertEqual(hex(Palette.surface, .aqua), String(ThemeColors.light.surface.prefix(7)))
        XCTAssertEqual(hex(Palette.bg, .aqua), String(ThemeColors.light.bg.prefix(7)))
        XCTAssertEqual(hex(Palette.bg, .darkAqua), String(ThemeColors.dark.bg.prefix(7)))
        XCTAssertEqual(hex(Palette.fg2, .darkAqua), String(ThemeColors.dark.fg2.prefix(7)))
        XCTAssertEqual(hex(Palette.bad, .aqua), String(ThemeColors.light.bad.prefix(7)))
        XCTAssertEqual(alpha(Palette.line, .aqua), 1)
        XCTAssertLessThan(alpha(Palette.line, .darkAqua), 1)
        XCTAssertNotEqual(hex(Palette.fg, .aqua), hex(Palette.fg, .darkAqua))
    }

    func testPretendardRegistersAndScalesWithUIScale() {
        XCTAssertTrue(Fonts.registered)
        defer { AppSettings.uiScaleOverride = nil }
        AppSettings.uiScaleOverride = 1
        let body = NSFont.ppomi(3), bold = NSFont.ppomi(3, weight: .bold)
        XCTAssertEqual(body.familyName, Fonts.family)
        XCTAssertEqual(body.pointSize, 14)
        XCTAssertNotEqual(body.fontName, bold.fontName)
        XCTAssertEqual(NSFont.ppomi(6).pointSize, 24)
        AppSettings.uiScaleOverride = 2
        XCTAssertEqual(NSFont.ppomi(3, monospacedDigits: true).pointSize, 28)
        XCTAssertEqual(NSFont.ppomi(3, monospacedDigits: true).familyName, Fonts.family)
    }
}
