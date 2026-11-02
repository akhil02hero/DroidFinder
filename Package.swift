// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DroidFinder",
    platforms: [.macOS(.v14)],
    targets: [
        // libmtp's header only; the library is opened at runtime (see LibMTP.swift).
        .systemLibrary(name: "CLibMTP", path: "Sources/CLibMTP"),
        .executableTarget(name: "DroidFinder", dependencies: ["CLibMTP"], path: "Sources/DroidFinder"),
    ],
    swiftLanguageVersions: [.v5]
)
