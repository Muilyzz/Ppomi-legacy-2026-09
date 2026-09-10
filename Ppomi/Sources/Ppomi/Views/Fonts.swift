// Pretendard Variable, bundled in Fonts/, on one 6-step scale multiplied by AppSettings.uiScale.
import AppKit
import SwiftUI

enum Fonts {
    static let family = "Pretendard Variable"
    static let steps: [CGFloat] = [11, 12, 14, 16, 21, 24]
    /// Posted after AppSettings.uiScale changes; native labels re-apply fonts, the web view updates --ui-scale.
    static let scaleChanged = Notification.Name("ppomi.uiScale")
    /// Observed by ppomiTheme() so SwiftUI roots without an AppState dependency re-render on a scale change.
    final class Scale: ObservableObject { @Published var value = AppSettings.uiScale }
    static let scale = Scale()

    /// Registered for this process once; false when the bundle lacks the file (system font is used instead).
    static let registered: Bool = {
        guard let url = AppResources.bundle.url(forResource: "PretendardVariable", withExtension: "ttf", subdirectory: "Fonts") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || NSFont(name: family, size: 12) != nil
    }()

    static func size(_ step: Int) -> CGFloat { steps[max(1, min(6, step)) - 1] * AppSettings.uiScale }
}

extension NSFont {
    static func ppomi(_ step: Int, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        let size = Fonts.size(step)
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: Fonts.family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]]
        if monospacedDigits {
            attributes[.featureSettings] = [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                             NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        }
        guard Fonts.registered, let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size) else {
            return monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
        return font
    }
}

extension Font {
    static func ppomi(_ step: Int, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> Font {
        Font(NSFont.ppomi(step, weight: weight, monospacedDigits: monospacedDigits))
    }
    /// Numbers and ids only.
    static func ppomiMono(_ step: Int) -> Font { .system(size: Fonts.size(step), design: .monospaced) }
}
