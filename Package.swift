// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "xcode-hackatime",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "xcode-hackatime",
            path: "Sources/XcodeHackatime"
        )
    ]
)
