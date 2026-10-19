// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualBassLab",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "VirtualBassLab", targets: ["VirtualBassLab"])
    ],
    targets: [
        .executableTarget(
            name: "VirtualBassLab",
            dependencies: [],
            path: "Sources/VirtualBassLab"
        )
    ],
    swiftLanguageModes: [.v5]
)
