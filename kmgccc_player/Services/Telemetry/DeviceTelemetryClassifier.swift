//
//  DeviceTelemetryClassifier.swift
//  myPlayer2
//
//  kmgccc_player - Coarse-grained, privacy-preserving device classification for
//  anonymous telemetry. Pure (Foundation only, no IOKit/AppKit) so the parsing
//  logic stays unit-testable in isolation.
//
//  Design rules:
//  - Only ever emit coarse product-family / chip-generation-and-tier buckets.
//    Never leak a precise model identifier (e.g. "Mac15,6"), full CPU marketing
//    string, serial, UUID, or user-assigned device name.
//  - These are *restricted strings*, not fixed enums: future Mac product lines,
//    chip generations, and known performance tiers (M5 Pro/M6 Max/A19 Pro/...)
//    flow through naturally; only genuinely unrecognizable inputs collapse to
//    "unknown".
//

import Foundation

enum DeviceTelemetryClassifier {
    static let unknown = "unknown"

    // MARK: - Device family

    /// Canonicalize a candidate string (a marketing name such as "MacBook Pro" or
    /// an Intel-style model identifier such as "MacBookPro18,3") into a coarse
    /// product-family label.
    ///
    /// Accepts an optional `chipTier` to correlate A-series chips with MacBook Neo.
    static func deviceFamily(
        fromCandidate candidate: String?,
        chipTier: String? = nil
    ) -> String? {
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()

        // 1. MacBook Neo
        // Direct neo mention with arbitrary punctuation/spaces (e.g. "MacBook Neo",
        // "MacBookNeo1,1", "MacBook (Neo, 13-inch, 2026)", "MacBook, Neo")
        if (lower.contains("macbook") && lower.contains("neo")) || lower.contains("macbookneo") {
            return "MacBook Neo"
        }
        // If candidate is a generic "MacBook" and chip is A-series (A17/A18/A19), it is MacBook Neo
        if let chip = chipTier?.lowercased(), chip.hasPrefix("a"),
           lower.contains("macbook"), !lower.contains("pro"), !lower.contains("air") {
            return "MacBook Neo"
        }

        // 2. Standard product families (order matters: specific before generic)
        if lower.contains("macbook pro") || lower.contains("macbookpro") { return "MacBook Pro" }
        if lower.contains("macbook air") || lower.contains("macbookair") { return "MacBook Air" }
        if lower.contains("mac studio") || lower.contains("macstudio") { return "Mac Studio" }
        if lower.contains("mac mini") || lower.contains("macmini") { return "Mac mini" }
        // Check iMac before "Mac Pro": "iMacPro1,1" contains the "macpro" substring,
        // and we deliberately fold "iMac Pro" into the coarse "iMac" bucket.
        if lower.contains("imac") { return "iMac" }
        if lower.contains("mac pro") || lower.contains("macpro") { return "Mac Pro" }
        if lower.contains("macbook") { return "MacBook" }

        // 3. Apple Silicon model identifier fallback when IORegistry product-name is missing
        if let fallback = appleSiliconModelFallback(raw) {
            return fallback
        }

        return nil
    }

    /// Known Apple Silicon Mac... model identifiers mapping as fallback.
    static func appleSiliconModelFallback(_ identifier: String) -> String? {
        let airModels: Set<String> = [
            "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13"
        ]
        let proModels: Set<String> = [
            "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10",
            "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
            "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8"
        ]
        let miniModels: Set<String> = [
            "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11"
        ]
        let studioModels: Set<String> = [
            "Mac14,13", "Mac14,14"
        ]
        let macProModels: Set<String> = [
            "Mac14,8"
        ]
        let imacModels: Set<String> = [
            "Mac15,4", "Mac15,5"
        ]

        if airModels.contains(identifier) { return "MacBook Air" }
        if proModels.contains(identifier) { return "MacBook Pro" }
        if miniModels.contains(identifier) { return "Mac mini" }
        if studioModels.contains(identifier) { return "Mac Studio" }
        if macProModels.contains(identifier) { return "Mac Pro" }
        if imacModels.contains(identifier) { return "iMac" }

        return nil
    }

    /// Resolve the family from an ordered list of candidates (preferred source
    /// first). Falls back to `unknown` if none can be recognized.
    static func deviceFamily(
        fromCandidates candidates: [String?],
        chipTier: String? = nil
    ) -> String {
        for candidate in candidates {
            if let family = deviceFamily(fromCandidate: candidate, chipTier: chipTier) {
                return family
            }
        }
        return unknown
    }

    // MARK: - Chip tier

    /// Specificity ranking for chip candidates: detailed tier (Pro/Max/Ultra)
    /// must strictly take precedence over coarse SoC generational tokens (M3/M5).
    enum ChipTierRank: Int, Comparable {
        case unknown = 0
        case baseGeneration = 1 // M1, M2, M3, M4, M5, A17
        case detailedTier = 2   // M1 Pro, M3 Max, M5 Max, M2 Ultra, A18 Pro

        static func < (lhs: ChipTierRank, rhs: ChipTierRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct ChipClassification {
        let tier: String
        let rank: ChipTierRank
    }

    /// Coarse Apple chip generation and performance tier. Keeps the generation
    /// plus a known "Pro" / "Max" / "Ultra" suffix when present (for example
    /// "M1 Max"), but never emits the full marketing name or core count
    /// ("Apple M3 Pro 11-core CPU").
    static func chipTier(brandString: String?) -> String {
        guard let brand = brandString, let tier = firstChipTier(in: brand) else {
            return unknown
        }
        return tier
    }

    /// Resolve a chip tier from preferred-to-fallback system sources by specificity.
    /// A detailed tier (e.g. "M5 Max" or "M3 Ultra" from `machdep.cpu.brand_string`)
    /// will always take priority over a coarse generation token (e.g. "M5" or "M3"
    /// from `product-soc-name`), preventing Max/Ultra machines from being folded
    /// into base models.
    static func chipTier(fromCandidates candidates: [String?], memoryGB: Int? = nil) -> String {
        var best: ChipClassification?

        for candidate in candidates {
            guard let classified = classifyChip(candidate: candidate) else { continue }
            if let current = best {
                if classified.rank > current.rank {
                    best = classified
                }
            } else {
                best = classified
            }
        }

        return best?.tier ?? unknown
    }

    /// Classify a candidate string into a tier and rank.
    static func classifyChip(candidate: String?) -> ChipClassification? {
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // 1. Apple Silicon M/A pattern:
        // Matches "M1", "M1 Pro", "M3 Max", "M3-Max", "M3Max", "M5 Ultra", "A18 Pro"
        let pattern = #"\b([MA])(\d{1,3})(?:[\s-]*(Pro|Max|Ultra)\b)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = regex.firstMatch(in: raw, range: range),
               let letterRange = Range(match.range(at: 1), in: raw),
               let digitsRange = Range(match.range(at: 2), in: raw) {
                var tier = "\(raw[letterRange].uppercased())\(raw[digitsRange])"
                var rank: ChipTierRank = .baseGeneration

                if match.range(at: 3).location != NSNotFound,
                   let suffixRange = Range(match.range(at: 3), in: raw) {
                    switch raw[suffixRange].lowercased() {
                    case "pro":
                        tier += " Pro"
                        rank = .detailedTier
                    case "max":
                        tier += " Max"
                        rank = .detailedTier
                    case "ultra":
                        tier += " Ultra"
                        rank = .detailedTier
                    default:
                        break
                    }
                }
                return ChipClassification(tier: tier, rank: rank)
            }
        }

        return nil
    }

    /// Extract the first standalone "M<digits>" / "A<digits>" token and an
    /// optional known performance suffix.
    static func firstChipTier(in brand: String) -> String? {
        classifyChip(candidate: brand)?.tier
    }

    // MARK: - Memory

    /// Convert physical memory in bytes to a rounded GB integer. Returns `nil`
    /// (→ unknown on the server) when the value is implausible. Never emits raw
    /// byte counts. Range follows the agreed 1...2048 GB envelope and supports
    /// non-power-of-two capacities (12, 36, 96, ...).
    static func memoryGB(fromBytes bytes: UInt64) -> Int? {
        guard bytes > 0 else { return nil }
        let gib = Double(bytes) / 1_073_741_824.0
        let rounded = Int(gib.rounded())
        guard rounded >= 1, rounded <= 2048 else { return nil }
        return rounded
    }

    // MARK: - OS major

    /// Major-version-only OS bucket, e.g. "macOS 26". Never includes the patch
    /// level, to avoid adding a finer-grained fingerprint.
    static func osMajor(fromMajorVersion major: Int) -> String {
        guard major > 0 else { return unknown }
        return "macOS \(major)"
    }
}
