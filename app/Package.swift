// swift-tools-version: 6.0
import PackageDescription

// sigstop — an open-source macOS menu bar app.
//
// Deliberately a plain SwiftPM package with NO .xcodeproj:
//   * builds with Command Line Tools alone (no Xcode install required, works in CI)
//   * no generated XML project file to merge-conflict on every PR
//   * `open Package.swift` still gives a full Xcode experience to anyone who wants one
//
// Layering is enforced by the dependency graph below and must stay one-way:
//     SigstopApp -> SigstopSensors -> SigstopCore
// SigstopCore must never import AppKit. See CLAUDE.md §3.1.

let package = Package(
    name: "sigstop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sigstop", targets: ["SigstopApp"]),
        .library(name: "SigstopCore", targets: ["SigstopCore"]),
    ],
    targets: [
        // Pure domain. No AppKit, no I/O, no clock reads. Fully unit-testable.
        .target(
            name: "SigstopCore",
            resources: [.copy("Message/corpus.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The only target permitted to touch macOS APIs.
        .target(
            name: "SigstopSensors",
            dependencies: ["SigstopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SigstopApp",
            dependencies: ["SigstopCore", "SigstopSensors"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SigstopCoreTests",
            dependencies: ["SigstopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
