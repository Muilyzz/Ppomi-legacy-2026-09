import Foundation

/// The Tauri host supplies its staged resource root; standalone apps and SwiftPM keep their existing lookup.
enum AppResources {
    static let bundle: Bundle = {
        if let path = ProcessInfo.processInfo.environment["PPOMI_RESOURCE_DIR"], path.hasPrefix("/"),
           let bundle = Bundle(url: URL(fileURLWithPath: path).appendingPathComponent("Ppomi_Ppomi.bundle")) { return bundle }
        return Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Ppomi_Ppomi.bundle"))
        } ?? Bundle.module
    }()
}
