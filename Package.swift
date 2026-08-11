// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wattson",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Wattson",
            path: "Sources/Wattson"
        )
    ]
)
