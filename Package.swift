// swift-tools-version: 6.0
// JoeScreen — a CoScreen-style shared-desktop app for macOS + iOS/iPadOS.
//
// This Package.swift is the PRIMARY machine-checkable green gate (see §9 of the build spec):
// all non-app library targets live here so `swift build` / `swift test` exercise the
// load-bearing logic (wire protocol, coordinate mapping, authorization, admission control,
// codec-selection, redaction) WITHOUT any paired hardware or a running SFU.
//
// App + broadcast-extension product targets live in Apps/JoeScreen.xcodeproj (Xcode layer),
// which consumes this package locally. See DECISIONS.md D8.
//
// Dependency pins (DECISIONS.md D7 — resolved artifacts, bump-only policy):
//   • livekit/client-sdk-swift 2.15.1   (media plane; replaces stasel/WebRTC — D3)
//   • migueldeicaza/SwiftTerm  1.13.0    (F12 terminal rendering)
//   • apple/swift-certificates 1.19.3    (LAN QUIC TLS plumbing — seam only, shipped dark)
// Rule: no dependency that links a SECOND libwebrtc may ever enter the graph (D7/R22).

import PackageDescription

let package = Package(
    name: "JoeScreen",
    platforms: [
        // Deployment floor per DECISIONS.md D2: macOS 14 / iOS 17 gets SCContentSharingPicker,
        // GroupSessionJournal, .unreliable messenger, ShareLink start. Built with the 26.1 SDK;
        // newer capabilities are #available-gated in code, never by raising the floor.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "JoeScreenKit", targets: ["JoeScreenKit"]),
        .library(name: "JoeScreenBridge", targets: ["JoeScreenBridge"]),
        .library(name: "JoeScreenCaptureMac", targets: ["JoeScreenCaptureMac"]),
        .library(name: "JoeScreenInputMac", targets: ["JoeScreenInputMac"]),
        .library(name: "JoeScreenUI", targets: ["JoeScreenUI"]),
        // The ONLY target that links LiveKit — the concrete `MediaTransport` adapter (D3/R22).
        .library(name: "JoeScreenLiveKit", targets: ["JoeScreenLiveKit"]),
    ],
    dependencies: [
        // NOTE: the default `swift build`/`swift test` gate targets (`JoeScreenKit` + its tests, and
        // Bridge/CaptureMac) do NOT link LiveKit — the pure-logic seams stay dependency-free so the
        // machine gate is fast and offline. LiveKit is consumed ONLY by the `JoeScreenLiveKit`
        // adapter target (and, transitively, the Xcode app layer), which keeps the "exactly one
        // libwebrtc in the process" rule (R22) enforced by the dependency graph.
        //
        // Resolved against the network (pins are real tags verified 2026-07); `Package.resolved` is
        // committed so subsequent resolves are reproducible/offline.
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.15.1"),
        // SwiftTerm (F12 terminal) and swift-certificates (LAN QUIC TLS) stay dark until their
        // milestones — uncomment when F12 / the LAN mesh path are built:
        // .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.13.0"),
        // .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.3"),
    ],
    targets: [
        // ── JoeScreenKit: the shared brain. Pure Swift, dependency-free, Sendable-clean. ──
        // This is what the machine gate cares about most: every non-networked seam is here and
        // unit-tested. Framework-touching wrappers (SessionManager, LiveKitTransport, codec VT
        // wrappers) are compiled here too but their platform-only bits are #if-guarded.
        .target(
            name: "JoeScreenKit",
            path: "Sources/JoeScreenKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),

        // ── JoeScreenBridge: App Group IPC shared between iOS host app and broadcast extension. ──
        // Deliberately depends on NOTHING (no GroupActivities, no LiveKit) so the extension can
        // link it under the ~50 MB jetsam budget (D11/R7).
        .target(
            name: "JoeScreenBridge",
            path: "Sources/JoeScreenBridge",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),

        // ── macOS-only capture. Compiles to an empty module on iOS via #if os(macOS) guards. ──
        .target(
            name: "JoeScreenCaptureMac",
            dependencies: ["JoeScreenKit"],
            path: "Sources/JoeScreenCaptureMac",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),

        // ── macOS-only input injection (Developer-ID, non-sandboxed — D6). ──
        .target(
            name: "JoeScreenInputMac",
            dependencies: ["JoeScreenKit"],
            path: "Sources/JoeScreenInputMac",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),

        // ── Shared SwiftUI feature layer. ──
        .target(
            name: "JoeScreenUI",
            dependencies: ["JoeScreenKit"],
            path: "Sources/JoeScreenUI",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),

        // ── JoeScreenLiveKit: the one and only LiveKit-linking target (D3/D7/R22). ──
        // The concrete `LiveKitTransport` actor conforming to JoeScreenKit's `MediaTransport`
        // protocol lives here so JoeScreenKit stays dependency-free and "exactly one libwebrtc in
        // the process" is guaranteed by the dependency graph. Swift 5 language mode per-target:
        // LiveKit's 2.15.1 public API is not fully Swift-6-strict-concurrency clean, and D1
        // pre-authorizes a per-target Swift-5 fallback for SDK-adjacent targets (JoeScreenKit itself
        // stays Swift 6). Recorded in DECISIONS.md D1.
        .target(
            name: "JoeScreenLiveKit",
            dependencies: [
                "JoeScreenKit",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "Sources/JoeScreenLiveKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // ── Tests: the machine gate. All pure logic, no hardware, no network. ──
        .testTarget(
            name: "JoeScreenKitTests",
            dependencies: ["JoeScreenKit"],
            path: "Tests/JoeScreenKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JoeScreenBridgeTests",
            dependencies: ["JoeScreenBridge"],
            path: "Tests/JoeScreenBridgeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JoeScreenCaptureMacTests",
            dependencies: ["JoeScreenCaptureMac"],
            path: "Tests/JoeScreenCaptureMacTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // ── LiveKit integration tests (M2). These need a running SFU: every test SKIPS (not fails)
        // unless `LIVEKIT_URL` is set in the environment, so the offline machine gate stays green.
        // Run against a dev server with:
        //   livekit-server --dev &
        //   LIVEKIT_URL=ws://localhost:7880 swift test --filter JoeScreenLiveKitTests
        .testTarget(
            name: "JoeScreenLiveKitTests",
            dependencies: ["JoeScreenLiveKit", "JoeScreenKit"],
            path: "Tests/JoeScreenLiveKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
