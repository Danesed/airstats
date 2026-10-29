// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "muStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "muStats", targets: ["MuStats"]),
        .library(name: "MuStatsKit", targets: ["MuStatsKit"]),
        .library(name: "MuStatsUI", targets: ["MuStatsUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Metric collection. Deliberately Swift 5 language mode: the collectors are
        // queue-confined by construction (see SamplingCore) rather than by the type
        // system, and the low-level Mach/IOKit code they wrap is not Sendable-clean.
        .target(
            name: "MuStatsKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "MuStatsUI",
            dependencies: ["MuStatsKit", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MuStats",
            dependencies: ["MuStatsKit", "MuStatsUI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle ships as a framework, and Scripts/build.sh puts it in
            // Contents/Frameworks. Without this the binary looks only where SwiftPM
            // linked it from and the assembled .app dies at launch with a dyld error.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Named for MuStatsKit because that is where almost everything under test
        // lives, but it also links MuStatsUI: the pieces of UI logic worth testing
        // are the pure ones (threshold evaluation, render models), and giving them a
        // second test target would split the suite for no gain.
        .testTarget(
            name: "MuStatsKitTests",
            dependencies: ["MuStatsKit", "MuStatsUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
