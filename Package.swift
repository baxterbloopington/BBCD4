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
            path: ".",
            exclude: [
                "release", "Tests"
            ],
            resources: [
                .copy("bbcd4_icon.icns"),
                .copy("bbcd4_icon.png"),
                .copy("default-streams.json")
            ]
        ),
        .testTarget(name: "BBCD4MacTests", dependencies: ["BBCD4Mac"], path: "Tests"),
    ]
)
