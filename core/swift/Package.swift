// swift-tools-version: 6.3
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Bassline",
    platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26), .tvOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "Bassline", targets: ["Bassline"]),
    ],
    targets: [
        .target(name: "Bassline", swiftSettings: settings),
        .testTarget(name: "BasslineTests", dependencies: ["Bassline"], swiftSettings: settings),
    ]
)
