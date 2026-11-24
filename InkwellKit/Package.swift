// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "InkwellKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(
            name: "InkwellKit",
            targets: ["InkwellKit"]
        ),
    ],
    targets: [
        .target(
            name: "InkwellKit",
            dependencies: ["InkwellCore", "InkwellMarkdown", "InkwellTemplate", "InkwellMedia", "InkwellPublish", "InkwellGitHub", "InkwellSync"],
            swiftSettings: settings
        ),
        .target(name: "InkwellCore", swiftSettings: settings),
        .target(name: "InkwellMarkdown", swiftSettings: settings),
        .target(name: "InkwellTemplate", dependencies: ["InkwellCore", "InkwellMarkdown"], swiftSettings: settings),
        .target(name: "InkwellMedia", dependencies: ["InkwellCore"], swiftSettings: settings),
        .target(name: "InkwellPublish", dependencies: ["InkwellCore"], swiftSettings: settings),
        .target(name: "InkwellGitHub", swiftSettings: settings),
        .target(name: "InkwellSync", dependencies: ["InkwellGitHub"], swiftSettings: settings),
        .testTarget(
            name: "InkwellKitTests",
            dependencies: ["InkwellCore", "InkwellMarkdown", "InkwellTemplate", "InkwellMedia", "InkwellPublish", "InkwellGitHub", "InkwellSync"],
            resources: [.copy("Fixtures")],
            swiftSettings: settings
        ),
    ]
)
