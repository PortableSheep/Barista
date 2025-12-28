// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Barista",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Barista", targets: ["Barista"])
    ],
    targets: [
        .executableTarget(
            name: "Barista",
            path: "Sources"
        )
    ]
)
