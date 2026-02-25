// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickTranslate",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "QuickTranslate",
            path: "Sources"
        )
    ]
)
