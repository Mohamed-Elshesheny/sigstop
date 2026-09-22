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
//
// THE ONE DEPENDENCY. Sparkle is attached to SigstopApp and to nothing else. SigstopCore
// and SigstopSensors stay dependency-free and must never import it, so the engines still
// build and test with no third-party code anywhere near them.
//
// Why a dependency at all, in a repo whose rule was zero: shipping outside the App Store
// with an ad-hoc signature means Apple code signing verifies nothing about who built an
// update — there is no Team ID to check against. Sparkle signs every update with EdDSA.
// The private key stays in the maintainer's Keychain, the PUBLIC key is compiled into the
// app as SUPublicEDKey, and Sparkle refuses any archive whose signature does not verify.
// A compromised GitHub account, CDN or network therefore still cannot hand this app code
// to run. The alternative was hand-rolling download-and-verify, which is the one thing
// nobody should hand-roll. See docs/RELEASING.md.

let package = Package(
    name: "sigstop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sigstop", targets: ["SigstopApp"]),
        .library(name: "SigstopCore", targets: ["SigstopCore"]),
    ],
    dependencies: [
        // Pinned exactly, not by range. An updater that quietly changes version underneath
        // you is the wrong thing to be relaxed about.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Pure domain. No AppKit, no I/O, no clock reads. Fully unit-testable.
        .target(
            name: "SigstopCore",
            resources: [.copy("Message/corpus.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The only target permitted to touch macOS APIs. Still dependency-free.
        .target(
            name: "SigstopSensors",
            dependencies: ["SigstopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The only target that links anything third-party, and the only one that links
        // anything that can open a socket.
        .executableTarget(
            name: "SigstopApp",
            dependencies: [
                "SigstopCore",
                "SigstopSensors",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Scripted days against the real engine. Not a test target on purpose: its output
        // is a timeline a person reads, and it is meant to be run and looked at when the
        // question is "when does this actually prompt", which no assertion answers well.
        .executableTarget(
            name: "Scenarios",
            dependencies: ["SigstopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SigstopCoreTests",
            dependencies: ["SigstopCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Providers are pure functions of a SignalContext and the Tier 2 collectors are
        // pure functions of a process table, so this target needs no window server and no
        // logged-in session either: it constructs literals and calls functions. It exists
        // because DEBUGGING lives entirely in this layer and an activity that cannot be
        // tested is an activity nobody can trust.
        .testTarget(
            name: "SigstopSensorsTests",
            dependencies: ["SigstopSensors"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
