// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "InkwellKit",
    defaultLocalization: "en",
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
            dependencies: ["InkwellCore", "InkwellMarkdown", "InkwellTemplate", "InkwellMedia", "InkwellPublish", "InkwellGitHub", "InkwellSync", "InkwellDesign"],
            swiftSettings: settings
        ),
        .target(name: "InkwellCore", resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellMarkdown", resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellTemplate", dependencies: ["InkwellCore", "InkwellMarkdown"], swiftSettings: settings),
        .target(name: "InkwellMedia", dependencies: ["InkwellCore"], resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellPublish", dependencies: ["InkwellCore"], resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellGitHub", resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellSync", dependencies: ["InkwellGitHub"], resources: [.process("Localizable.xcstrings")], swiftSettings: settings),
        .target(name: "InkwellDesign", dependencies: ["InkwellCore"], resources: [.copy("Themes"), .copy("ElementKit"), .process("Localizable.xcstrings"), .process("Themes.xcstrings")], swiftSettings: settings),
        .testTarget(
            name: "InkwellKitTests",
            dependencies: ["InkwellCore", "InkwellMarkdown", "InkwellTemplate", "InkwellMedia", "InkwellPublish", "InkwellGitHub", "InkwellSync", "InkwellDesign"],
            resources: [.copy("Fixtures")],
            swiftSettings: settings
        ),
    ]
)
