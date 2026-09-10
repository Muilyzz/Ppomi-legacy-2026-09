// swift-tools-version: 6.0
// 뽀미 — the Mac body of the personal money agent: menu bar app, mirroring control, kiosk, ledger views.
// Build: swift build   Run: swift run Ppomi   Test: swift test
import PackageDescription

let package = Package(
    name: "Ppomi",
    platforms: [.macOS("26.0")],   // 배포는 내가 하니 최신만 지원 (.v26 열거값은 아직 없어 문자열로)
    targets: [
        .executableTarget(name: "Ppomi", path: "Sources/Ppomi", resources: [.copy("Web"), .copy("Fonts"), .copy("Catalog"), .copy("AccountingData"), .copy("SpatialData")], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedLibrary("sqlite3"),
                          // TCC reads usage strings from an embedded Info.plist (no app bundle here); build from the package root
                          .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Ppomi/Info.plist"])]),
        .testTarget(name: "PpomiTests", dependencies: ["Ppomi"], path: "Tests/PpomiTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
