// swift-tools-version: 6.2
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let excludedDirectories = ["release", "Tests", "BBCD4.xcodeproj"].filter {
    FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent($0).path)
}
let localTestTargets: [Target] = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("Tests").path)
    ? [.testTarget(name: "BBCD4MacTests", dependencies: ["BBCD4Mac"], path: "Tests")]
    : []

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
            exclude: excludedDirectories,
            resources: [
                .copy("bbcd4_icon.icns"),
                .copy("bbcd4_icon.png"),
                .copy("default-streams.json")
            ]
        ),
    ] + localTestTargets
)
