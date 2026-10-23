// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapTranslate",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SnapTranslate", targets: ["SnapTranslate"])],
    targets: [
        .target(name: "TranslationCore"),
        .executableTarget(name: "SnapTranslate", dependencies: ["TranslationCore"]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"]),
        .testTarget(name: "SnapTranslateTests", dependencies: ["SnapTranslate"]),
    ]
)
