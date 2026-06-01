// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "toolsmith",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "toolsmith", targets: ["Toolsmith"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "Toolsmith",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "ToolsmithTests",
            dependencies: ["Toolsmith"]
        ),
    ]
)
