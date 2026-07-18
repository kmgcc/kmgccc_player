//
//  ArtworkForegroundPolarity.swift
//  myPlayer2
//
//  Shared foreground-polarity decision for artwork-overlaid UI.
//
//  Two layers consume foreground polarity:
//
//    1. `ArtworkForegroundPolarityPolicy.globalPolarity` - a conservative,
//       whole-image decision derived from `ArtworkColorAnalysis` statistics.
//       It replaces the old single `avgHslL >= 0.58` threshold, which switched
//       too many mid-tone covers to dark ink. The stricter gate raises the
//       eligibility floor and only commits to dark foreground when the cover
//       is *clearly* bright (HSL, WCAG luma, or pale-high-brightness). This is
//       the value baked into `ArtworkColorAnalysis.usesDarkForeground` and the
//       `SemanticPalette` global readability profile.
//
//    2. `RenderedBackdropReadabilityMap` (separate file) - a local,
//       per-surface decision that samples the *final rendered* backdrop at the
//       exact pixel regions where text/controls land, and compares the two
//       candidate foregrounds' contrast directly. Local polarity may override
//       the global default for a single surface only (Home Hero, Cover Gradient
//       Blur fullscreen controls, queue, and Quick Panel).
//
//  Invariant: within one visual group (one Mini Player, one Hero card) there
//  is exactly one polarity. Colour, blend mode, spectrum depth and glass
//  material scheme must all derive from that single polarity - never a mix.
//

import AppKit

/// Foreground ink polarity for UI overlaid on artwork.
nonisolated enum ArtworkForegroundPolarity: String, Equatable, Sendable {
    /// Dark ink on a bright background. The cover is bright enough that dark
    /// foreground reads with better contrast.
    case darkOnLightBackground
    /// Light ink on a dim background.
    case lightOnDarkBackground

    var usesDarkForeground: Bool { self == .darkOnLightBackground }

    /// Convenience for the opposite polarity (used when a local contrast pass
    /// overrides the global default).
    var inverted: ArtworkForegroundPolarity {
        switch self {
        case .darkOnLightBackground: return .lightOnDarkBackground
        case .lightOnDarkBackground: return .darkOnLightBackground
        }
    }
}

/// Whole-image foreground-polarity policy. Pure function over analysis
/// statistics; no SwiftUI / ThemeStore coupling so it can run inside
/// SelfCheck and the Golden Master CLI.
nonisolated enum ArtworkForegroundPolarityPolicy {
    /// Conservative global polarity. Dark foreground requires clear evidence
    /// that the cover is bright; mid-tone covers default to light foreground.
    ///
    /// This is the production value behind `ArtworkColorAnalysis.usesDarkForeground`.
    /// Do not re-introduce a single loose `avgHslL` threshold here - the
    /// historical Cover Blur strict gate was centralized exactly to stop the
    /// "dark colour with light blend flags" mixed profile.
    static func globalPolarity(
        avgHslLightness: CGFloat,
        weightedLuma: CGFloat,
        avgBrightness: CGFloat,
        avgSaturation: CGFloat
    ) -> ArtworkForegroundPolarity {
        let T = ColorSystemTokens.ReadabilityForeground.self
        guard avgHslLightness >= T.eligibilityAvgHslL else {
            return .lightOnDarkBackground
        }
        let clearlyBrightByHSL = avgHslLightness >= T.clearlyBrightAvgHslL
        let clearlyBrightByLuma = weightedLuma >= T.clearlyBrightWcagLuma
        let paleHighBrightness = avgBrightness >= T.paleBrightnessFloor
            && avgSaturation < T.paleSaturationCeiling
        return (clearlyBrightByHSL || clearlyBrightByLuma || paleHighBrightness)
            ? .darkOnLightBackground
            : .lightOnDarkBackground
    }

    /// Which sub-gate committed to the decision. For parity / DEBUG reports.
    static func globalGateReason(
        avgHslLightness: CGFloat,
        weightedLuma: CGFloat,
        avgBrightness: CGFloat,
        avgSaturation: CGFloat
    ) -> GlobalGateReason {
        let T = ColorSystemTokens.ReadabilityForeground.self
        guard avgHslLightness >= T.eligibilityAvgHslL else {
            return .belowEligibility
        }
        if avgHslLightness >= T.clearlyBrightAvgHslL { return .clearlyBrightHSL }
        if weightedLuma >= T.clearlyBrightWcagLuma { return .clearlyBrightLuma }
        if avgBrightness >= T.paleBrightnessFloor
            && avgSaturation < T.paleSaturationCeiling {
            return .paleHighBrightness
        }
        return .borderlineLight
    }

    /// Diagnostic label for the sub-gate that produced a polarity.
    enum GlobalGateReason: String, Sendable {
        /// `avgHslLightness` below the eligibility floor -> light foreground.
        case belowEligibility
        /// Clearly bright by HSL lightness -> dark foreground.
        case clearlyBrightHSL
        /// Clearly bright by WCAG luma -> dark foreground.
        case clearlyBrightLuma
        /// Pale + high brightness, low saturation -> dark foreground.
        case paleHighBrightness
        /// Passed eligibility but not clearly bright -> light foreground.
        case borderlineLight
    }
}
