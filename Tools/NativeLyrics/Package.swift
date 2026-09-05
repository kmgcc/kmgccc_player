// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeLyrics",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NativeLyrics", targets: ["NativeLyrics"]),
        .executable(name: "NativeLyricsDemo", targets: ["NativeLyricsDemo"]),
        .executable(name: "LyricsProbe", targets: ["LyricsProbe"])
    ],
    targets: [
        .target(name: "NativeLyrics"),
        .executableTarget(name: "NativeLyricsDemo", dependencies: ["NativeLyrics"], resources: [.copy("Resources")]),
        .executableTarget(name: "LyricsProbe", dependencies: ["NativeLyrics"]),
        .testTarget(name: "NativeLyricsTests", dependencies: ["NativeLyrics"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
