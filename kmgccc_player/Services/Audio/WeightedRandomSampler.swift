//
//  WeightedRandomSampler.swift
//  myPlayer2
//
//  Weighted random sampling for shuffle selection.
//

import Foundation

/// Performs weighted random sampling for shuffle selection.
@MainActor
struct WeightedRandomSampler {

    /// Select a random track ID based on weights using weighted selection.
    /// - Parameters:
    ///   - candidates: Array of candidate track IDs.
    ///   - weights: Dictionary of track ID to weight.
    ///   - exclude: Track ID to exclude from selection (optional).
    /// - Returns: Selected track ID or nil if no valid candidates.
    static func sample(
        from candidates: [UUID],
        weights: [UUID: Double],
        exclude: UUID? = nil
    ) -> UUID? {
        let validCandidates = candidates.filter { $0 != exclude }
        guard !validCandidates.isEmpty else { return nil }

        // Calculate total weight.
        let totalWeight = validCandidates.reduce(0) { sum, trackID in
            sum + (weights[trackID] ?? 1.0)
        }

        guard totalWeight > 0 else {
            // Fallback to uniform random if all weights are zero.
            return validCandidates.randomElement()
        }

        // Weighted random selection.
        var randomValue = Double.random(in: 0..<totalWeight)

        for trackID in validCandidates {
            let weight = weights[trackID] ?? 1.0
            randomValue -= weight
            if randomValue <= 0 {
                return trackID
            }
        }

        // Fallback (should rarely happen due to floating point).
        return validCandidates.last
    }

    /// Generate multiple weighted random samples without replacement.
    /// Used for pre-generating the shuffle queue.
    static func sampleMultiple(
        from candidates: [UUID],
        weights: [UUID: Double],
        count: Int,
        exclude: UUID? = nil
    ) -> [UUID] {
        var availableCandidates = candidates.filter { $0 != exclude }
        var result: [UUID] = []

        let targetCount = min(count, availableCandidates.count)

        for _ in 0..<targetCount {
            guard !availableCandidates.isEmpty else { break }

            // Recalculate total weight for remaining candidates.
            let totalWeight = availableCandidates.reduce(0) { sum, trackID in
                sum + (weights[trackID] ?? 1.0)
            }

            guard totalWeight > 0 else {
                // Uniform random fallback.
                if let selected = availableCandidates.randomElement() {
                    result.append(selected)
                    availableCandidates.removeAll { $0 == selected }
                }
                continue
            }

            // Weighted selection.
            var randomValue = Double.random(in: 0..<totalWeight)
            var selected: UUID?

            for trackID in availableCandidates {
                let weight = weights[trackID] ?? 1.0
                randomValue -= weight
                if randomValue <= 0 {
                    selected = trackID
                    break
                }
            }

            if let selected = selected ?? availableCandidates.last {
                result.append(selected)
                availableCandidates.removeAll { $0 == selected }
            }
        }

        return result
    }
}
