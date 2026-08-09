// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BBCD4Mac",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "BBCD4Mac", targets: ["BBCD4Mac"]),
    ],
    targets: [
        .executableTarget(
            name: "BBCD4Mac",
            resources: [.process("Resources")]
        ),
    ]
)
