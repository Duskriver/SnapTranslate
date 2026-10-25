// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapTranslate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SnapTranslate", targets: ["SnapTranslate"])],
    dependencies: [
        // Keep compatibility with the project's Swift 6.0 toolchain.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.6.0")),
    ],
    targets: [
        .target(name: "TranslationCore"),
        .executableTarget(name: "SnapTranslate", dependencies: [
            "TranslationCore",
            .product(name: "Markdown", package: "swift-markdown"),
        ]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"]),
        .testTarget(name: "SnapTranslateTests", dependencies: ["SnapTranslate"]),
    ]
)
