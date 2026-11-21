// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "K24Cutter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "K24Cutter",
            path: "Sources/K24Cutter"
        )
    ]
)
