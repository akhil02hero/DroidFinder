// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DroidFinder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DroidFinder", path: "Sources/DroidFinder")
    ],
    swiftLanguageVersions: [.v5]
)
