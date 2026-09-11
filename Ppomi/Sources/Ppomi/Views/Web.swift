// Page templates: Web/<name>.html with theme.css spliced in at /*THEME*/ so every page shares one look.
import Foundation

enum Web {
    /// Ppomi_Ppomi.bundle in Contents/Resources (dist/Ppomi.app, scripts/make-app.sh) or wherever SwiftPM put it.
    static let bundle = AppResources.bundle
    /// Web/ inside the resource bundle: the base URL for pages loaded as strings so ./Agent/fonts/… resolves.
    static var directory: URL { FamilyUpdateRuntime.shared.directory ?? bundle.resourceURL!.appendingPathComponent("Web", isDirectory: true) }
    static func file(_ name: String, _ ext: String) -> String {
        if FamilyUpdateRuntime.shared.directory != nil {
            guard let file = FamilyUpdateRuntime.shared.fileURL("\(name).\(ext)"),
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { return "" }
            return contents
        }
        return try! String(contentsOf: bundle.url(forResource: name, withExtension: ext, subdirectory: "Web")!, encoding: .utf8)
    }
    /// The template with the shared theme in place; callers then fill their own /*DATA*/ placeholders.
    static func page(_ name: String) -> String {
        file(name, "html").replacingOccurrences(of: "/*THEME*/", with: file("tokens", "css") + "\n" + file("theme", "css"))
    }
}
