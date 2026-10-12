// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PopupLab",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PopupKit", targets: ["PopupKit"]),
        .executable(name: "PopupLab", targets: ["PopupLab"])
    ],
    targets: [
        .target(name: "PopupKit"),
        .executableTarget(name: "PopupLab", dependencies: ["PopupKit"])
    ],
    swiftLanguageModes: [.v5]
)
