// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tunaboat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TunaboatCore", targets: ["TunaboatCore"]),
        .executable(name: "tunaboat", targets: ["tunaboat"]),
        .executable(name: "TunaboatApp", targets: ["TunaboatApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TunaboatCore"),
        .executableTarget(
            name: "tunaboat",
            dependencies: [
                "TunaboatCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "TunaboatApp",
            dependencies: ["TunaboatCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TunaboatCoreTests", dependencies: ["TunaboatCore"]),
    ]
)
