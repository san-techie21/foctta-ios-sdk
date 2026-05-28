// swift-tools-version: 5.9
//
// FOCTTA iOS SDK — Swift Package Manager manifest.
//
// Distribution: SPM-only. CocoaPods support intentionally not provided —
// CocoaPods trunk goes read-only 2 Dec 2026 (see Firebase migration
// guide). New SDKs shipping in 2026 use SPM.
//
// Minimum iOS: 15.0 — covers ≥95% of installed base in India. Gives us
// SwiftUI 3 (refreshable, searchable, AsyncImage) without the iOS 13/14
// SwiftUI bug minefield.
//
// PrivacyInfo.xcprivacy is shipped as a resource — App Store
// submission has required this manifest for SDKs since Feb 2025.

import PackageDescription

let package = Package(
    name: "FOCTTA",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        // macOS minimum is here purely to make `swift build` / `swift test`
        // succeed under SPM's default host-platform compilation. The SDK
        // itself ships against iOS only — customers consume it via Xcode
        // building for iOS, not macOS. v12 is the floor that gives us
        // native async/await + Task.sleep(nanoseconds:) without needing
        // @available guards everywhere. (Codemagic build on 28 May 2026
        // surfaced the missing-macOS-platform error in our retry loop.)
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "FOCTTA",
            targets: ["FOCTTA"]
        )
    ],
    dependencies: [
        // Persistence — GRDB.swift (mature SQLite wrapper, single dep,
        // Codable support, WAL mode, optional SQLCipher integration).
        // Pinned to 6.x; bumps require a CHANGELOG entry.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0"),

        // No Alamofire — URLSession + async/await is enough and reduces
        // attack surface for BFSI audit.

        // Testing — Point-Free's swift-snapshot-testing for UI snapshot
        // tests (golden-file diffs of SwiftUI banner / preference center).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),

        // Apple Swift-DocC plugin — generates the static API reference
        // site that gets published to GitHub Pages on each release tag.
        // See .github/workflows/publish-docc.yml.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "FOCTTA",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                // 22-language string catalogs (synced from web widget via
                // scripts/sync-sdk-translations.ts).
                .process("Resources/Localization"),
                // Privacy manifest — required for App Store submission
                // by any app that depends on this SDK.
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "FOCTTATests",
            dependencies: [
                "FOCTTA",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
