import Foundation

/// Packaged apps read Contents/Resources; SwiftPM executables and tests use the build bundle.
enum AppResources {
    static let bundle = Bundle.main.resourceURL.flatMap {
        Bundle(url: $0.appendingPathComponent("Ppomi_Ppomi.bundle"))
    } ?? Bundle.module
}
