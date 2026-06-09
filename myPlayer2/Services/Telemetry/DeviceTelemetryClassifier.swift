//
//  DeviceTelemetryClassifier.swift
//  myPlayer2
//
//  kmgccc_player - Coarse-grained, privacy-preserving device classification for
//  anonymous telemetry. Pure (Foundation only, no IOKit/AppKit) so the parsing
//  logic stays unit-testable in isolation.
//
//  Design rules:
//  - Only ever emit coarse product-family / chip-generation buckets. Never leak a
//    precise model identifier (e.g. "Mac15,6"), full CPU marketing string, serial,
//    UUID, or user-assigned device name.
//  - These are *restricted strings*, not fixed enums: future Mac product lines,
//    chip families, and chip tiers (M5/M6/A19/...) flow through naturally; only
//    genuinely unrecognizable inputs collapse to "unknown".
//

import Foundation

enum DeviceTelemetryClassifier {
    static let unknown = "unknown"

    // MARK: - Device family

    /// Canonicalize a candidate string (a marketing name such as "MacBook Pro" or
    /// an Intel-style model identifier such as "MacBookPro18,3") into a coarse
    /// product-family label.
    ///
    /// Returns `nil` when no known family token is recognized, so the caller can
    /// try the next source (e.g. IORegistry product-name vs. `hw.model`) before
    /// falling back to `unknown`. Apple Silicon identifiers like "Mac15,6" carry no
    /// family token and therefore return `nil` here by design.
    static func deviceFamily(fromCandidate candidate: String?) -> String? {
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        // Order matters: match more specific families before generic "MacBook".
        if lower.contains("macbook pro") || lower.contains("macbookpro") { return "MacBook Pro" }
        if lower.contains("macbook air") || lower.contains("macbookair") { return "MacBook Air" }
        if lower.contains("mac studio") || lower.contains("macstudio") { return "Mac Studio" }
        if lower.contains("mac mini") || lower.contains("macmini") { return "Mac mini" }
        // Check iMac before "Mac Pro": "iMacPro1,1" contains the "macpro" substring,
        // and we deliberately fold "iMac Pro" into the coarse "iMac" bucket.
        if lower.contains("imac") { return "iMac" }
        if lower.contains("mac pro") || lower.contains("macpro") { return "Mac Pro" }
        if lower.contains("macbook") { return "MacBook" }
        return nil
    }

    /// Resolve the family from an ordered list of candidates (preferred source
    /// first). Falls back to `unknown` if none can be recognized.
    static func deviceFamily(fromCandidates candidates: [String?]) -> String {
        for candidate in candidates {
            if let family = deviceFamily(fromCandidate: candidate) {
                return family
            }
        }
        return unknown
    }

    // MARK: - Chip family

    /// Coarse processor family: "Apple Silicon" / "Intel" / "unknown".
    /// `isAppleSilicon` comes from `hw.optional.arm64` (reflects hardware even
    /// under Rosetta); `brandString` is a best-effort fallback only.
    static func chipFamily(isAppleSilicon: Bool?, brandString: String?) -> String {
        if isAppleSilicon == true { return "Apple Silicon" }
        if isAppleSilicon == false { return "Intel" }
        if let brand = brandString?.lowercased() {
            if brand.contains("apple") { return "Apple Silicon" }
            if brand.contains("intel") { return "Intel" }
        }
        return unknown
    }

    // MARK: - Chip tier

    /// Coarse chip generation. For Apple Silicon this is the family token only
    /// ("M1"/"M2"/.../"M6"/"A19"), never the full marketing name ("Apple M3 Pro
    /// 11-core CPU"). For Intel it is simply "Intel".
    static func chipTier(family: String, brandString: String?) -> String {
        switch family {
        case "Intel":
            return "Intel"
        case "Apple Silicon":
            if let brand = brandString, let token = firstChipToken(in: brand) {
                return token
            }
            return unknown
        default:
            return unknown
        }
    }

    /// Extract the first standalone "M<digits>" / "A<digits>" token (case
    /// insensitive), normalized to an uppercase leading letter. This is what lets
    /// future tiers (M5/M6/A19/...) pass without hardcoding an enum.
    static func firstChipToken(in brand: String) -> String? {
        let pattern = "\\b([MmAa])(\\d{1,3})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(brand.startIndex..., in: brand)
        guard let match = regex.firstMatch(in: brand, range: range),
              let letterRange = Range(match.range(at: 1), in: brand),
              let digitsRange = Range(match.range(at: 2), in: brand) else {
            return nil
        }
        return "\(brand[letterRange].uppercased())\(brand[digitsRange])"
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
