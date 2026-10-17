// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Maestro",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Maestro", path: "Sources/Maestro")
    ]
)
