// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PpomiSharedAccounting",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ppomi_accounting_core", type: .dynamic, targets: ["SharedAccountingCore"]),
        .executable(name: "accounting-core", targets: ["AccountingCoreCLI"])
    ],
    targets: [
        // stage.py refreshes these byte-for-byte from the canonical Mac sources.
        .target(name: "SharedAccountingCore", path: "build/Sources/SharedAccountingCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AccountingCoreCLI", dependencies: ["SharedAccountingCore"],
                          path: "Sources/AccountingCoreCLI", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
