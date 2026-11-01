// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenDoodle",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ScreenDoodle",
            path: "Sources/ScreenDoodle"
        )
    ]
)