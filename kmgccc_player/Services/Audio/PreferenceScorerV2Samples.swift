//
//  PreferenceScorerV2Samples.swift
//  myPlayer2
//
//  V2 Algorithm Sample Calculations for verification.
//

import Foundation

extension PreferenceScorerV2 {
    /// Print all sample calculations for verification
    static func printAllSamples() {
        print("\n" + String(repeating: "=", count: 70))
        print("PREFERENCE SCORER V2 - SAMPLE CALCULATIONS")
        print(String(repeating: "=", count: 70))

        // Sample A: Low sample, neutral/cautious
        calculateAndPrintSample(
            playCount: 2,
            completePlayCount: 1,
            skipCount: 1,
            quickSkipCount: 1,
            totalPlayedSeconds: 120,  // ~50% avg listen ratio (假设duration=240)
            duration: 240,
            manualLikeState: .none,
            label: "A: Low sample, neutral/cautious (2 plays, 1 complete, 1 quickSkip)"
        )

        // Sample B: Clearly liked but not exaggerated
        calculateAndPrintSample(
            playCount: 12,
            completePlayCount: 9,
            skipCount: 1,
            quickSkipCount: 0,
            totalPlayedSeconds: 2400,  // ~83% avg listen ratio
            duration: 240,
            manualLikeState: .none,
            label: "B: Clearly liked but not exaggerated (12 plays, 9 complete)"
        )

        // Sample C: Clearly disliked but not banned
        calculateAndPrintSample(
            playCount: 10,
            completePlayCount: 1,
            skipCount: 6,
            quickSkipCount: 4,
            totalPlayedSeconds: 600,  // ~25% avg listen ratio
            duration: 240,
            manualLikeState: .none,
            label: "C: Clearly disliked but not banned (10 plays, mostly skipped)"
        )

        // Sample D: Ultra low sample, should not judge harshly
        calculateAndPrintSample(
            playCount: 1,
            completePlayCount: 0,
            skipCount: 1,
            quickSkipCount: 1,
            totalPlayedSeconds: 5,  // Quick skip
            duration: 240,
            manualLikeState: .none,
            label: "D: Ultra low sample, should not judge harshly (1 quickSkip)"
        )

        // Sample E: Manual liked
        calculateAndPrintSample(
            playCount: 5,
            completePlayCount: 4,
            skipCount: 0,
            quickSkipCount: 0,
            totalPlayedSeconds: 1100,
            duration: 240,
            manualLikeState: .liked,
            label: "E: Manual liked (should get gentle boost)"
        )

        // Sample F: Manual disliked
        calculateAndPrintSample(
            playCount: 8,
            completePlayCount: 5,
            skipCount: 2,
            quickSkipCount: 1,
            totalPlayedSeconds: 1400,
            duration: 240,
            manualLikeState: .disliked,
            label: "F: Manual disliked (should get gentle penalty)"
        )

        // Sample G: High plays, moderate completion ( plateau test )
        calculateAndPrintSample(
            playCount: 50,
            completePlayCount: 35,
            skipCount: 10,
            quickSkipCount: 5,
            totalPlayedSeconds: 9500,
            duration: 240,
            manualLikeState: .none,
            label: "G: High plays plateau test (should not exceed bounds)"
        )

        print(String(repeating: "=", count: 70))
        print("SAMPLE CALCULATIONS COMPLETE")
        print(String(repeating: "=", count: 70) + "\n")
    }
}
