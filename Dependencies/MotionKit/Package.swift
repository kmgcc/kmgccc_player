// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MotionKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MotionKit",
            targets: ["MotionKit"]
        ),
        .executable(
            name: "MotionKitDemo",
            targets: ["MotionKitDemo"]
        )
    ],
    targets: [
        .target(
            name: "MotionKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MotionKitDemo",
            dependencies: ["MotionKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MotionKitTests",
            dependencies: ["MotionKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
