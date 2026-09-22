//
//  DeviceTelemetryClassifierRegressionTests.swift
//  kmgccc_player/Tests
//
//  Standalone regression checks for coarse Apple Silicon classification.
//  Run with:
//    swiftc -parse-as-library \
//      kmgccc_player/Services/Telemetry/DeviceTelemetryClassifier.swift \
//      Tests/DeviceTelemetryClassifierRegressionTests.swift \
//      -o /tmp/device_telemetry_regression && /tmp/device_telemetry_regression
//

import Foundation

@main
struct DeviceTelemetryClassifierRegressionTests {
    static func main() {
        expectAppleSilicon("Apple M1", "M1")
        expectAppleSilicon("Apple M1 Pro", "M1 Pro")
        expectAppleSilicon("Apple M1 Max", "M1 Max")
        expectAppleSilicon("Apple M2 Ultra", "M2 Ultra")
        expectAppleSilicon("Apple M3 MAX 16-core CPU", "M3 Max")
        expectAppleSilicon("Apple M4 pro 14-core CPU", "M4 Pro")
        expectAppleSilicon("Apple M5", "M5")
        expectAppleSilicon("Apple M5 Pro", "M5 Pro")
        expectAppleSilicon("Apple M5 Max", "M5 Max")
        expectAppleSilicon("Apple M5 Ultra", "M5 Ultra")
        expectAppleSilicon("Apple M3-Max", "M3 Max")
        expectAppleSilicon("Apple M3Max", "M3 Max")
        expectAppleSilicon("Apple A17 Pro", "A17 Pro")
        expectAppleSilicon("Apple A18 Pro", "A18 Pro")
        expectAppleSilicon("Future Apple M12 Ultra", "M12 Ultra")

        // Intel processors are not supported targets and must resolve to unknown
        expectAppleSilicon("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", DeviceTelemetryClassifier.unknown)
        expectAppleSilicon("Intel(R) Xeon(R) W-3245M CPU @ 3.20GHz", DeviceTelemetryClassifier.unknown)

        // Multi-candidate priority: detailed tier (Max/Ultra/Pro) must win over coarse SoC tokens
        expect(
            DeviceTelemetryClassifier.chipTier(
                fromCandidates: ["Apple M5", "Apple M5 Max", "MacBook Pro (16-inch, M5 Max, 2026)"],
                memoryGB: 128
            ) == "M5 Max",
            "Expected M5 Max to win over coarse SoC token M5"
        )
        expect(
            DeviceTelemetryClassifier.chipTier(
                fromCandidates: ["Apple M3", "Apple M3 Ultra"]
            ) == "M3 Ultra",
            "Expected M3 Ultra to win over coarse SoC token M3"
        )
        expect(
            DeviceTelemetryClassifier.chipTier(
                fromCandidates: ["unrecognized SoC", "Apple A18 Pro"]
            ) == "A18 Pro",
            "Expected chip source fallback to preserve A18 Pro"
        )

        // Unknown marketing words and core-count details must never leave the
        // classifier; only the coarse generation is retained.
        expectAppleSilicon("Apple M3 Extreme 16-core CPU", "M3")
        expectAppleSilicon("Apple processor", DeviceTelemetryClassifier.unknown)

        // MacBook Neo variations
        expectDeviceFamily("MacBook Neo", "MacBook Neo")
        expectDeviceFamily("MacBookNeo1,1", "MacBook Neo")
        expectDeviceFamily("MacBook Neo (13-inch, A18 Pro, 2026)", "MacBook Neo")
        expectDeviceFamily("MacBook (Neo, 13-inch, 2026)", "MacBook Neo")
        expectDeviceFamily("MacBook (Neo)", "MacBook Neo")
        expectDeviceFamily("MacBook, Neo", "MacBook Neo")

        // A-series chip on generic MacBook should resolve to MacBook Neo
        expect(
            DeviceTelemetryClassifier.deviceFamily(
                fromCandidate: "MacBook (13-inch, 2026)",
                chipTier: "A18 Pro"
            ) == "MacBook Neo",
            "Expected generic MacBook with A18 Pro to classify as MacBook Neo"
        )

        // Standard families
        expectDeviceFamily("MacBook Pro", "MacBook Pro")
        expectDeviceFamily("MacBookPro18,3", "MacBook Pro")
        expectDeviceFamily("MacBook Air", "MacBook Air")
        expectDeviceFamily("MacBookAir10,1", "MacBook Air")
        expectDeviceFamily("Mac Studio", "Mac Studio")
        expectDeviceFamily("MacStudio2,1", "Mac Studio")
        expectDeviceFamily("Mac Studio (2025)", "Mac Studio")
        expectDeviceFamily("Mac mini", "Mac mini")
        expectDeviceFamily("Macmini9,1", "Mac mini")
        expectDeviceFamily("iMac", "iMac")
        expectDeviceFamily("iMac21,1", "iMac")
        expectDeviceFamily("iMac (24-inch, 2024)", "iMac")
        expectDeviceFamily("iMac Pro", "iMac")
        expectDeviceFamily("iMacPro1,1", "iMac")
        expectDeviceFamily("Mac Pro", "Mac Pro")
        expectDeviceFamily("MacPro7,1", "Mac Pro")

        // Apple Silicon model identifier fallbacks
        expectDeviceFamily("Mac15,9", "MacBook Pro")
        expectDeviceFamily("Mac15,12", "MacBook Air")
        expectDeviceFamily("Mac14,13", "Mac Studio")
        expectDeviceFamily("Mac14,3", "Mac mini")
        expectDeviceFamily("Mac15,4", "iMac")
        expectDeviceFamily("Mac14,8", "Mac Pro")

        print("DeviceTelemetryClassifierRegressionTests passed")
    }

    private static func expectAppleSilicon(_ brand: String, _ expected: String) {
        let actual = DeviceTelemetryClassifier.chipTier(brandString: brand)
        expect(actual == expected, "Expected \(brand) -> \(expected), got \(actual)")
    }

    private static func expectDeviceFamily(_ candidate: String, _ expected: String) {
        let actual = DeviceTelemetryClassifier.deviceFamily(fromCandidate: candidate)
        expect(actual == expected, "Expected \(candidate) -> \(expected), got \(actual ?? "nil")")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
