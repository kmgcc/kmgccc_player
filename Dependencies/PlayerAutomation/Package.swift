// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlayerAutomation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PlayerAutomationProtocol",
            targets: ["PlayerAutomationProtocol"]
        ),
        .library(
            name: "PlayerAutomationIPC",
            targets: ["PlayerAutomationIPC"]
        ),
        .executable(
            name: "player-automation",
            targets: ["AutomationTool"]
        )
    ],
    targets: [
        .target(
            name: "PlayerAutomationProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PlayerAutomationIPC",
            dependencies: ["PlayerAutomationProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AutomationTool",
            dependencies: ["PlayerAutomationProtocol", "PlayerAutomationIPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlayerAutomationTests",
            dependencies: ["PlayerAutomationProtocol", "PlayerAutomationIPC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
