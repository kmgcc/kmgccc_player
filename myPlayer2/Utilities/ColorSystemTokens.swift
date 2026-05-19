//
//  ColorSystemTokens.swift
//  myPlayer2
//
//  Central registry for colour-decision thresholds, clamps, ceilings, and
//  fixed targets used by the palette / theme system. Phase 1 lifts magic
//  numbers from `SemanticPaletteFactory` (and the `isEffectivelyMonochrome`
//  gate that drives it) into named constants without changing any value or
//  algorithmic structure — so Phase 2's Ultra Dark / Near Monochrome split
//  has a single place to retune from.
//
//  Naming reflects semantic intent (`Accent.darkMinLByHueViolet`,
//  `EffectiveMonochrome.branch3HighSatAreaShare`) so future phases can swap
//  the underlying expression — e.g., OKLCH equivalents — without touching
//  call sites.
//
//  Out of scope for Phase 1:
//  - LED OKLCH baseline / hue-aware chroma caps  → owned by LEDColorResolver
//    until Phase 6 (Tone Ladder).
//  - ArtworkColorExtractor's internal palette filtering thresholds (bucket
//    weights, distinctness gaps, WCAG contrast loop)  → revisited in Phase 2
//    when the extractor surfaces structured outputs.
//

import AppKit

nonisolated enum ColorSystemTokens {

    // MARK: - Optimized accent (SemanticPaletteFactory.optimizedAccent)
    //
    // Drives `globalAccent` and `uiAccentOnDark` / `uiAccentOnLight` on
    // covers that are NOT effectively monochrome. Constants here cluster
    // around: hue-aware lightness floor on dark mode, hue-aware saturation
    // ceiling on light mode, warm-band hue guard, and the three saturation
    // safety nets for low-colour artwork.

    enum Accent {

        // Dark-mode hue-aware lightness floor: yellow/orange already glow at
        // lower L, blue/violet/red need more L to remain readable.
        static let darkMinLByHueYellowOrange: CGFloat = 0.66  // hue 0.10..<0.18
        static let darkMinLByHueGreen: CGFloat        = 0.70  // hue 0.18..<0.42
        static let darkMinLByHueCyanBlue: CGFloat     = 0.74  // hue 0.42..<0.72
        static let darkMinLByHueViolet: CGFloat       = 0.76  // hue 0.72..<0.85
        static let darkMinLByHueDefault: CGFloat      = 0.72  // red / magenta / pink

        // Dark-mode saturation & lightness clamp.
        static let darkSaturationLift: CGFloat = 1.06
        static let darkSaturationFloor: CGFloat = 0.32
        static let darkSaturationCeiling: CGFloat = 0.86
        static let darkLightnessCeiling: CGFloat = 0.82

        // Light-mode hue-aware saturation ceiling: garish hues (medical
        // green, magenta, industrial blue) cap lower; warm hues can stay
        // richer. Combined with a soft shoulder for smooth compression.
        static let lightSatCeilingPinkMagenta: CGFloat     = 0.46  // 0.83..<1.00, 0.00..<0.03
        static let lightSatCeilingPurpleViolet: CGFloat    = 0.50  // 0.72..<0.83
        static let lightSatCeilingMedicalGreen: CGFloat    = 0.48  // 0.30..<0.50
        static let lightSatCeilingIndustrialBlue: CGFloat  = 0.54  // 0.50..<0.65
        static let lightSatCeilingDeepBlue: CGFloat        = 0.58  // 0.65..<0.72
        static let lightSatCeilingWarmRedOrange: CGFloat   = 0.66  // 0.03..<0.10
        static let lightSatCeilingYellowAmber: CGFloat     = 0.68  // 0.10..<0.20
        static let lightSatCeilingChartreuse: CGFloat      = 0.56  // 0.20..<0.30
        static let lightSatCeilingDefault: CGFloat         = 0.54

        // Light-mode saturation shoulder + outer clamp.
        static let lightSaturationLift: CGFloat = 1.02
        static let lightSaturationFloor: CGFloat = 0.30
        static let lightSaturationOuterCeiling: CGFloat = 0.72
        static let lightSatShoulderSoftness: CGFloat = 0.10

        // Light-mode lightness clamp.
        static let lightLightnessScale: CGFloat = 0.78
        static let lightLightnessFloor: CGFloat = 0.30
        static let lightLightnessCeiling: CGFloat = 0.50

        // Hue guard for the warm-yellow / beige / ochre band — small brown
        // spots can drift the dominant bucket past the warm band, so snap
        // back to avgHue when confidence is high enough.
        static let warmGuardHueLo: CGFloat = 0.07
        static let warmGuardHueHi: CGFloat = 0.20
        static let warmGuardHueConfidenceMin: CGFloat = 0.16
        static let warmBandHueLo: CGFloat = 0.06
        static let warmBandHueHi: CGFloat = 0.20
        static let warmGuardDriftThreshold: CGFloat = 0.06

        // Saturation safety nets for low-colour covers. Three increasingly
        // strict tiers, activated by different colorfulness/avgSaturation
        // levels (kept here so Phase 2 can re-orthogonalise them).
        static let strictMonoSatCapDark: CGFloat = 0.18
        static let strictMonoSatCapLight: CGFloat = 0.14
        static let nearMonoSatCapDark: CGFloat = 0.26
        static let nearMonoSatCapLight: CGFloat = 0.20
        static let lowConfidenceSatCapDark: CGFloat = 0.40
        static let lowConfidenceSatCapLight: CGFloat = 0.32

        // Activation gates for the safety-net branches.
        static let nearMonoColorfulnessThreshold: CGFloat = 0.10
        static let nearMonoAvgSaturationThreshold: CGFloat = 0.12
        static let lowConfidenceHueConfidenceThreshold: CGFloat = 0.18
    }

    // MARK: - Near-monochrome accent (SemanticPaletteFactory.nearMonochromeAccent)
    //
    // Drives the accent on covers where `isEffectivelyMonochrome == true`.
    // Output is a desaturated tone, hue chosen from the average (if any
    // hue is usable) or a fixed neutral hue otherwise.

    enum NearMonochrome {

        // Average-hue usability gates (need a tiny bit of colour to pick a
        // hue from the average).
        static let avgHueUsableSaturation: CGFloat = 0.055
        static let avgHueUsableAvgSaturation: CGFloat = 0.055

        // Neutral-hue choice when the average has no usable hue: cool
        // charcoal under dark covers, warm paper otherwise.
        static let neutralHueChoiceLightnessThreshold: CGFloat = 0.34
        static let neutralCoolHue: CGFloat = 0.58
        static let neutralWarmHue: CGFloat = 0.10

        // Strict-mono gate (any one of these is enough). Used to pick the
        // tighter saturation cap below.
        static let strictMonoColorfulness: CGFloat = 0.055
        static let strictMonoAvgSaturation: CGFloat = 0.085
        static let strictMonoHighSatAreaShare: CGFloat = 0.06

        // Output saturation cap (strict vs softer mono branch).
        static let strictMonoSatCapDark: CGFloat = 0.08
        static let strictMonoSatCapLight: CGFloat = 0.07
        static let nearMonoSatCapDark: CGFloat = 0.14
        static let nearMonoSatCapLight: CGFloat = 0.12

        // Output saturation floor and scaling of the input average sat.
        static let saturationFloorDark: CGFloat = 0.035
        static let saturationFloorLight: CGFloat = 0.025
        static let saturationScale: CGFloat = 0.72

        // Dark-mode tone-lift: dimmer cover → lift output L slightly.
        // (In the original code, the pivot doubled as the input-ramp range —
        // i.e., `(pivot - avgHslL) / pivot`. Phase 1 keeps that coupling but
        // surfaces the range under its own name.)
        static let darkBaseLightness: CGFloat = 0.66
        static let darkLiftPivot: CGFloat = 0.42        // avgHslL at which lift = 0
        static let darkLiftRange: CGFloat = 0.42        // input ramp denominator
        static let darkLiftMax: CGFloat = 0.08
        static let darkCeilingLightness: CGFloat = 0.74

        // Light-mode tone-drop: brighter cover → drop output L slightly.
        static let lightBaseLightness: CGFloat = 0.40
        static let lightDropPivot: CGFloat = 0.52       // avgHslL at which drop = 0
        static let lightDropRange: CGFloat = 0.42       // input ramp denominator
        static let lightDropMax: CGFloat = 0.08
        static let lightFloorLightness: CGFloat = 0.32
        static let lightCeilingLightness: CGFloat = 0.42
    }

    // MARK: - User-fallback accent (no artwork tint)
    //
    // Applied to the user's configured fallback accent when `useArtworkTint`
    // is off. Mirrors the dark/light L bands of `Accent` but lives in HSL
    // (since it routes through `ColorMath.clampLightness`, not OKLCH).

    enum FallbackAccent {
        static let darkMinL: CGFloat = 0.66
        static let darkMaxL: CGFloat = 0.82
        static let lightMinL: CGFloat = 0.30
        static let lightMaxL: CGFloat = 0.50
    }

    // MARK: - Readable text on artwork (SemanticPaletteFactory.readableTextOnArtwork)
    //
    // Produces a desaturated tone variant of `bestTextSourceColor`, biased
    // toward either the dark or light end depending on `usesDarkForeground`.
    // Phase 4 will unify the readability profile across surfaces; for now
    // these are the established clamps.

    enum ReadableText {

        // Dark foreground (text-on-light-cover): lift the saturation a hair,
        // then clamp into a comfortable mid range; fix L at deep charcoal.
        static let darkForegroundSaturationLift: CGFloat = 0.04
        static let darkForegroundSatLo: CGFloat = 0.10
        static let darkForegroundSatHi: CGFloat = 0.34
        static let darkForegroundLightness: CGFloat = 0.12

        // Light foreground (text-on-dark-cover): keep the saturation
        // narrower so very saturated highlights don't bloom; fix L near
        // off-white.
        static let lightForegroundSatLo: CGFloat = 0.04
        static let lightForegroundSatHi: CGFloat = 0.24
        static let lightForegroundLightness: CGFloat = 0.92

        // Secondary text alpha (slightly translucent).
        static let secondaryAlpha: CGFloat = 0.86
    }

    // MARK: - Cover gradient (SemanticPaletteFactory.coverGradientDominant / coverGradientText)
    //
    // Cover gradient sits behind a blur and demands stronger contrast bias
    // than `readableTextOnArtwork`. The dominant tint is clipped from the
    // cover's `dominantColor`; text is again a desaturated tone variant.

    enum CoverGradient {

        // Dominant-tint clamp.
        static let dominantSaturationScale: CGFloat = 0.92
        static let dominantSaturationLo: CGFloat = 0.10
        static let dominantSaturationHi: CGFloat = 0.62
        static let dominantLightnessLo: CGFloat = 0.22
        static let dominantLightnessHi: CGFloat = 0.78

        // Text-over-blurred-cover (stronger contrast bias than the
        // ReadableText counterpart).
        static let darkTextSatLo: CGFloat = 0.18
        static let darkTextSatHi: CGFloat = 0.36
        static let darkTextLightness: CGFloat = 0.16
        static let lightTextSatLo: CGFloat = 0.06
        static let lightTextSatHi: CGFloat = 0.20
        static let lightTextLightness: CGFloat = 0.94
    }

    // MARK: - Fullscreen lyric base
    //
    // Switches between using the dominant cover hue and the best text-source
    // hue for the fullscreen lyric base colour. Inactive base always uses
    // the average (more stable on covers with small but vivid highlights).

    enum FullscreenLyric {
        static let usesDominantColorfulnessMin: CGFloat = 0.20
        static let usesDominantHueConfidenceMin: CGFloat = 0.20
    }

    // MARK: - Window lyric inactive alpha

    enum WindowLyric {
        static let inactiveAlpha: CGFloat = 0.35
    }

    // MARK: - isEffectivelyMonochrome (ArtworkColorAnalysis)
    //
    // The five OR-branches that decide whether the cover is treated as
    // monochrome by the palette factory and LED resolver. R4 J.2.c / K.2
    // calls out that these branches need to be re-orthogonalised into
    // "Ultra Dark" (low lightness) vs "Near Monochrome" (low colour
    // confidence) in Phase 2 — branch 4 in particular couples lightness
    // and saturation into one gate. For Phase 1 we just give every
    // threshold a name; the logic stays identical.

    enum EffectiveMonochrome {

        // Branch 1: strict mono.
        static let strictColorfulness: CGFloat = 0.04
        static let strictAvgSaturation: CGFloat = 0.10

        // Branch 2: most monochrome covers.
        static let branch2Colorfulness: CGFloat = 0.10
        static let branch2AvgSaturation: CGFloat = 0.16
        static let branch2HighSatAreaShare: CGFloat = 0.12

        // Branch 3: subtler version of branch 2 (slightly lower avg sat
        // but accepts a touch more colourfulness).
        static let branch3AvgSaturation: CGFloat = 0.105
        static let branch3Colorfulness: CGFloat = 0.14
        static let branch3HighSatAreaShare: CGFloat = 0.16

        // Branch 4: extreme tone (very dark or very bright) + low sat.
        // Phase 2 should decouple the lightness factor from this branch
        // and move it under "Ultra Dark".
        static let extremeToneLightnessLo: CGFloat = 0.18
        static let extremeToneLightnessHi: CGFloat = 0.86
        static let branch4AvgSaturation: CGFloat = 0.18
        static let branch4Colorfulness: CGFloat = 0.16

        // Branch 5: dominant-bucket fallback.
        static let branch5DominantSaturation: CGFloat = 0.18
        static let branch5Colorfulness: CGFloat = 0.16
        static let branch5AvgSaturation: CGFloat = 0.18

        // `usesDarkForeground` boundary (the same `avgHslL` cut-off as
        // textPalette uses for its dark/light foreground decision).
        static let usesDarkForegroundAvgHslL: CGFloat = 0.58
    }
}
