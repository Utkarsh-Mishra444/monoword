// swift-tools-version:6.0
import PackageDescription

// A checkout may carry uncommitted extensions in Sources/*/Local (gitignored); the build scripts
// then pass -DLOCAL_EXTENSIONS (decided per run, so SwiftPM's manifest cache cannot go stale).

let package = Package(
    name: "Monoword",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Monoword", targets: ["MonowordApp"]),
    ],
    targets: [
        // Text cleaning, tokenizing, timing and the reading cursor. No AppKit here, so the same
        // rules can be ported to other platforms and unit tested.
        .target(
            name: "MonowordCore",
            path: "Sources/MonowordCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app (AppKit + a SwiftUI settings window). Bundled by scripts/build-app.sh.
        .executableTarget(
            name: "MonowordApp",
            dependencies: ["MonowordCore"],
            path: "Sources/MonowordApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "MonowordCoreTests",
            dependencies: ["MonowordCore"],
            path: "Tests/MonowordCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
