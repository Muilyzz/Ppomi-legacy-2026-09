// Every color comes from Palette.generated.swift (agent/theme.json); light/dark follows the appearance.
import AppKit
import SwiftUI

enum Palette {
    private static func color(_ pick: @escaping (ThemeColors.Set) -> String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = UInt32(pick(isDark ? ThemeColors.dark : ThemeColors.light).dropFirst(), radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                           blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
        }
    }

    static let bg = color(\.bg)
    static let surface = color(\.surface)
    static let surface2 = color(\.surface2)
    static let line = color(\.line)
    static let line2 = color(\.line2)
    static let fg = color(\.fg)
    static let fg2 = color(\.fg2)
    static let accent = color(\.accent)
    static let accentSoft = color(\.accentSoft)
    static let accentFg = color(\.accentFg)
    static let onAccent = color(\.onAccent)
    static let bad = color(\.bad)
}

extension NSColor {
    /// A plain color for APIs that copy the value at assignment time (SceneKit materials).
    func resolved(for appearance: NSAppearance) -> NSColor {
        var cg = cgColor
        appearance.performAsCurrentDrawingAppearance { cg = self.cgColor }
        return NSColor(cgColor: cg) ?? self
    }
}

extension ShapeStyle where Self == Color {
    static var bg: Color { Color(nsColor: Palette.bg) }
    static var surface: Color { Color(nsColor: Palette.surface) }
    static var surface2: Color { Color(nsColor: Palette.surface2) }
    static var line: Color { Color(nsColor: Palette.line) }
    static var line2: Color { Color(nsColor: Palette.line2) }
    static var fg: Color { Color(nsColor: Palette.fg) }
    static var fg2: Color { Color(nsColor: Palette.fg2) }
    static var accent: Color { Color(nsColor: Palette.accent) }
    static var accentSoft: Color { Color(nsColor: Palette.accentSoft) }
    static var accentFg: Color { Color(nsColor: Palette.accentFg) }
    static var onAccent: Color { Color(nsColor: Palette.onAccent) }
    static var bad: Color { Color(nsColor: Palette.bad) }
}

extension View {
    /// Root of every SwiftUI hierarchy: body font, text color, control tint; re-evaluated when Fonts.scale changes.
    func ppomiTheme() -> some View { Themed(content: self) }
}

private struct Themed<Content: View>: View {
    @ObservedObject var scale = Fonts.scale
    let content: Content
    var body: some View { content.font(.ppomi(3)).foregroundStyle(.fg).tint(.accent).controlSize(.ppomi) }
}

extension ControlSize {
    /// System controls (segmented pickers, bordered buttons) do not follow .font: bump their size with the scale instead.
    static var ppomi: ControlSize { Fonts.scale.value >= 1.75 ? .extraLarge : Fonts.scale.value >= 1.25 ? .large : .regular }
    static var ppomiSmall: ControlSize { Fonts.scale.value >= 1.75 ? .large : Fonts.scale.value >= 1.25 ? .regular : .small }
}
