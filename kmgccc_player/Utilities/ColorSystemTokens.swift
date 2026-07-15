//
//  ColorSystemTokens.swift
//  myPlayer2
//
//  Central registry for colour-decision thresholds, clamps, ceilings, and
//  fixed targets used by the palette / theme system. The old monochrome gate
//  is represented as two orthogonal axes: `UltraDark` (lightness only) and
//  `NearMonochromeProfile` (chromatic confidence only). Structured palette
//  outputs are covered by `SalientHighlight` and `DisplayPalette`.
//
//  Naming reflects semantic intent (`Accent.darkMinLByHueViolet`,
//  `NearMonochromeProfile.strictColorfulness`) so future refactors can swap
//  the underlying expression without touching call sites.
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
        // levels.
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
    // Drives the accent on covers where no trustworthy hue survives. Output
    // is achromatic; these tokens only control the grey tone's lightness.
    // This is the "anti-fake-color" path — it must not be relied on for
    // ultra-dark protection (which is a separate orthogonal axis).

    enum NearMonochrome {

        // Dark-mode tone-lift: dimmer cover → lift output L slightly. The
        // pivot doubles as the input-ramp range: `(pivot - avgHslL) / pivot`.
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
    // These are the established clamps for the readable text role.

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

    // MARK: - OKLCH readable text on artwork
    //
    // OKLCH replacement for `ReadableText`. OKLCH L replaces HSL lightness
    // (perceptually uniform); OKLCH C replaces HSL saturation (hue-independent
    // chroma control). Per-hue-family caps prevent high-saturation warm/green
    // hues from producing unreadable or fluorescent text.

    enum ReadableTextOKLCH {

        // Dark foreground (text-on-light-cover): L locked near deep charcoal.
        // OKLCH L≈0.20 is perceptually equivalent to HSL L=0.12 for typical
        // mid-chroma text.
        static let darkForegroundL: CGFloat = 0.20

        // Dark foreground chroma clamp.
        static let darkForegroundChromaLo: CGFloat = 0.008
        static let darkForegroundChromaHi: CGFloat = 0.045

        // Per-hue-family dark foreground chroma caps. Warm/orange can carry
        // more chroma without losing readability; cool/violet needs less.
        static let darkChromaCapWarm: CGFloat       = 0.055  // hue 0.04…0.14 (red-orange)
        static let darkChromaCapYellow: CGFloat     = 0.050  // hue 0.14…0.20
        static let darkChromaCapGreen: CGFloat      = 0.038  // hue 0.20…0.42 (incl. yellow-green)
        static let darkChromaCapCool: CGFloat       = 0.042  // hue 0.42…0.72 (cyan-blue)
        static let darkChromaCapViolet: CGFloat     = 0.040  // hue 0.72…0.88
        static let darkChromaCapDefault: CGFloat    = 0.045  // pink/magenta wraparound

        // Light foreground (text-on-dark-cover): L locked near off-white.
        static let lightForegroundL: CGFloat = 0.93

        // Light foreground chroma clamp: narrower than dark because bright
        // high-chroma text on dark backgrounds can appear fluorescent.
        static let lightForegroundChromaLo: CGFloat = 0.004
        static let lightForegroundChromaHi: CGFloat = 0.030

        // Per-hue-family light foreground chroma caps.
        static let lightChromaCapWarm: CGFloat      = 0.035  // hue 0.04…0.14
        static let lightChromaCapYellow: CGFloat    = 0.028  // hue 0.14…0.20
        static let lightChromaCapGreen: CGFloat     = 0.022  // hue 0.20…0.42 (most restrictive)
        static let lightChromaCapCool: CGFloat      = 0.028  // hue 0.42…0.72
        static let lightChromaCapViolet: CGFloat    = 0.026  // hue 0.72…0.88
        static let lightChromaCapDefault: CGFloat   = 0.030

        // Chroma soft-shoulder softness for gentle compression above cap.
        static let chromaShoulderSoftness: CGFloat = 0.012
    }

    // MARK: - OKLCH cover gradient
    //
    // OKLCH replacement for `CoverGradient`. Cover gradient sits behind a blur
    // and demands stronger contrast bias than direct-on-artwork text.

    enum CoverGradientOKLCH {

        // Dominant-tint: OKLCH L/C clamp replaces HSL S/L clamp.
        static let dominantChromaScale: CGFloat = 0.92
        static let dominantChromaLo: CGFloat = 0.010
        static let dominantChromaHi: CGFloat = 0.120
        static let dominantLLo: CGFloat = 0.24
        static let dominantLHi: CGFloat = 0.76

        // Text-over-blurred-cover: stronger contrast bias.
        // Dark foreground (text-on-light gradient).
        static let darkTextL: CGFloat = 0.22
        static let darkTextChromaLo: CGFloat = 0.010
        static let darkTextChromaHi: CGFloat = 0.048

        // Light foreground (text-on-dark gradient).
        static let lightTextL: CGFloat = 0.95
        static let lightTextChromaLo: CGFloat = 0.004
        static let lightTextChromaHi: CGFloat = 0.024

        // Per-hue chroma shoulder softness.
        static let chromaShoulderSoftness: CGFloat = 0.010
    }

    // MARK: - OKLCH fallback accent
    //
    // OKLCH replacement for `FallbackAccent`. Applied to the user's configured
    // fallback accent when `useArtworkTint` is off.

    enum FallbackAccentOKLCH {
        static let darkMinL: CGFloat = 0.72
        static let darkMaxL: CGFloat = 0.86
        static let lightMinL: CGFloat = 0.38
        static let lightMaxL: CGFloat = 0.55
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

    // MARK: - Lyrics
    //
    // Centralized Swift-side lyric colour policy. These values preserve the
    // fullscreen/window tuning and add the near-mono OKLCH chroma ceiling that
    // prevents grey / black / white artwork from acquiring visible pink, blue,
    // or yellow residue in either window or fullscreen lyrics.

    enum Lyrics {
        static let nearMonoChromaCeiling: CGFloat = 0.004
        static let nearMonoChromaAssertion: CGFloat = 0.005

        static let fullscreenMinimumBaseLightness: CGFloat = 0.52
        static let fullscreenMaximumBaseLightness: CGFloat = 0.66
        static let fullscreenMinimumSubActiveLightness: CGFloat = 0.88
        static let fullscreenMaximumSubActiveLightness: CGFloat = 0.94
        static let fullscreenMinimumMainActiveLightness: CGFloat = 0.95
        static let fullscreenMaximumMainActiveLightness: CGFloat = 0.98
        static let fullscreenSaturationFloor: CGFloat = 0.10
        static let fullscreenSaturationCeiling: CGFloat = 0.58

        static let fullscreenInactiveDarkModeShift: CGFloat = 0.08
        static let fullscreenInactiveUltraDarkShiftDark: CGFloat = 0.22
        static let fullscreenInactiveUltraDarkShiftLight: CGFloat = 0.17
        static let fullscreenActiveDarkModeShift: CGFloat = 0.02
        static let fullscreenActiveUltraDarkShiftDark: CGFloat = 0.10
        static let fullscreenActiveUltraDarkShiftLight: CGFloat = 0.06
        static let fullscreenInactiveSaturationScaleDark: CGFloat = 0.42
        static let fullscreenInactiveSaturationScaleLight: CGFloat = 0.48
        static let fullscreenInactiveUltraDarkSaturationScaleDark: CGFloat = 0.34
        static let fullscreenInactiveUltraDarkSaturationScaleLight: CGFloat = 0.40
        static let fullscreenInactiveSaturationBiasDark: CGFloat = 0.015
        static let fullscreenInactiveSaturationBiasLight: CGFloat = 0.020
        static let fullscreenActiveSaturationScale: CGFloat = 0.70
        static let fullscreenActiveSaturationBias: CGFloat = 0.06
        static let fullscreenInactiveLightnessTrim: CGFloat = 0.02
        static let fullscreenMinimumBaseShiftScale: CGFloat = 0.55
        static let fullscreenMaximumBaseShiftScale: CGFloat = 0.95
        static let fullscreenBaseLightnessFloor: CGFloat = 0.24
        static let fullscreenBaseLightnessFallbackCeiling: CGFloat = 0.40
        static let fullscreenSubActiveLightnessLift: CGFloat = 0.04
        static let fullscreenSubActiveShiftScale: CGFloat = 0.75
        static let fullscreenSubActiveMinimumGap: CGFloat = 0.04
        static let fullscreenSubActiveFloor: CGFloat = 0.64
        static let fullscreenSubActiveOffset: CGFloat = 0.08
        static let fullscreenSubActiveMinimumShiftScale: CGFloat = 0.90
        static let fullscreenSubActiveMaximumShiftScale: CGFloat = 0.75
        static let fullscreenSubActiveFallbackCeiling: CGFloat = 0.74
        static let fullscreenActiveLightnessLift: CGFloat = 0.18
        static let fullscreenActiveShiftScale: CGFloat = 0.60
        static let fullscreenActiveMinimumGap: CGFloat = 0.08
        static let fullscreenActiveFloor: CGFloat = 0.84
        static let fullscreenActiveMinimumShiftScale: CGFloat = 0.55
        static let fullscreenActiveMaximumShiftScale: CGFloat = 0.45
        static let fullscreenActiveFallbackCeiling: CGFloat = 0.90
        static let fullscreenLineTimingSaturationScaleFloor: CGFloat = 0.28
        static let fullscreenLineTimingSaturationScaleTrim: CGFloat = 0.03
        static let fullscreenLineTimingSaturationBiasFloor: CGFloat = 0.010
        static let fullscreenLineTimingSaturationBiasTrim: CGFloat = 0.005
        static let fullscreenSubActiveSaturationScale: CGFloat = 0.78
        static let fullscreenSubInactiveSaturationScaleFloor: CGFloat = 0.26
        static let fullscreenSubInactiveSaturationScaleTrim: CGFloat = 0.05
        static let fullscreenSubInactiveSaturationBiasFloor: CGFloat = 0.010
        static let fullscreenSubInactiveSaturationBiasTrim: CGFloat = 0.005
        static let fullscreenLineTimingSubSaturationScaleFloor: CGFloat = 0.24
        static let fullscreenLineTimingSubSaturationScaleTrim: CGFloat = 0.08
        static let fullscreenLineTimingSubSaturationBiasFloor: CGFloat = 0.008
        static let fullscreenLineTimingSubSaturationBiasTrim: CGFloat = 0.008
        static let fullscreenMainActiveSaturationScale: CGFloat = 1.12
        static let fullscreenMainActiveSaturationBias: CGFloat = 0.02

        static let coverBlurLighterVeryDarkThreshold: CGFloat = 0.05
        static let coverBlurLighterBrightThreshold: CGFloat = 0.70
        static let coverBlurLighterBrightInputMin: CGFloat = 0.64
        static let coverBlurLighterMidInputMin: CGFloat = 0.46
        static let coverBlurLighterNeutralInputMin: CGFloat = 0.18
        static let coverBlurLighterBrightActiveLift: CGFloat = 0.01
        static let coverBlurLighterBrightActiveMin: CGFloat = 0.90
        static let coverBlurLighterBrightActiveMax: CGFloat = 0.935
        static let coverBlurLighterBrightSaturationScale: CGFloat = 0.70
        static let coverBlurLighterBrightSaturationBias: CGFloat = 0.04
        static let coverBlurLighterBrightSaturationMin: CGFloat = 0.06
        static let coverBlurLighterBrightSaturationMax: CGFloat = 0.48
        static let coverBlurLighterMidActiveLift: CGFloat = 0.08
        static let coverBlurLighterMidActiveMin: CGFloat = 0.85
        static let coverBlurLighterMidActiveMax: CGFloat = 0.89
        static let coverBlurLighterMidSaturationScale: CGFloat = 0.54
        static let coverBlurLighterMidSaturationBias: CGFloat = 0.04
        static let coverBlurLighterMidSaturationMin: CGFloat = 0.06
        static let coverBlurLighterMidSaturationMax: CGFloat = 0.38
        static let coverBlurLighterNeutralActiveLift: CGFloat = 0.06
        static let coverBlurLighterNeutralActiveMin: CGFloat = 0.80
        static let coverBlurLighterNeutralActiveMax: CGFloat = 0.84
        static let coverBlurLighterNeutralSaturationScale: CGFloat = 0.48
        static let coverBlurLighterNeutralSaturationBias: CGFloat = 0.04
        static let coverBlurLighterNeutralSaturationMin: CGFloat = 0.05
        static let coverBlurLighterNeutralSaturationMax: CGFloat = 0.34
        static let coverBlurLighterDarkActiveLift: CGFloat = 0.38
        static let coverBlurLighterDarkActiveMin: CGFloat = 0.67
        static let coverBlurLighterDarkActiveMax: CGFloat = 0.78
        static let coverBlurLighterDarkSaturationScale: CGFloat = 0.14
        static let coverBlurLighterDarkSaturationBias: CGFloat = 0.06
        static let coverBlurLighterDarkSaturationMin: CGFloat = 0.05
        static let coverBlurLighterDarkSaturationMax: CGFloat = 0.18
        static let coverBlurLighterVeryDarkInactiveBoost: CGFloat = 0.090
        static let coverBlurLighterBrightInactiveTrim: CGFloat = 0.015
        static let coverBlurLighterInactiveSaturationScale: CGFloat = 0.34
        static let coverBlurLighterInactiveSaturationBias: CGFloat = 0.03
        static let coverBlurLighterInactiveSaturationMin: CGFloat = 0.03
        static let coverBlurLighterInactiveSaturationMax: CGFloat = 0.18
        static let coverBlurLighterSubInactiveSaturationScale: CGFloat = 0.28
        static let coverBlurLighterSubInactiveSaturationBias: CGFloat = 0.03
        static let coverBlurLighterSubInactiveSaturationMin: CGFloat = 0.02
        static let coverBlurLighterSubInactiveSaturationMax: CGFloat = 0.14
        static let coverBlurLighterBaseInputScale: CGFloat = 0.08
        static let coverBlurLighterBaseBias: CGFloat = 0.09
        static let coverBlurLighterVeryDarkBaseMin: CGFloat = 0.13
        static let coverBlurLighterBaseMin: CGFloat = 0.08
        static let coverBlurLighterBaseMax: CGFloat = 0.20
        static let coverBlurLighterVeryDarkLineTimingTrim: CGFloat = 0.025
        static let coverBlurLighterLineTimingTrim: CGFloat = 0.04
        static let coverBlurLighterVeryDarkLineTimingMin: CGFloat = 0.10
        static let coverBlurLighterLineTimingMin: CGFloat = 0.05
        static let coverBlurLighterVeryDarkSubActiveLift: CGFloat = 0.035
        static let coverBlurLighterSubActiveLift: CGFloat = 0.045
        static let coverBlurLighterVeryDarkSubActiveMin: CGFloat = 0.15
        static let coverBlurLighterSubActiveMin: CGFloat = 0.13
        static let coverBlurLighterSubActiveMax: CGFloat = 0.24
        static let coverBlurLighterLineTimingSaturationScale: CGFloat = 0.92
        static let coverBlurLighterSubActiveSaturationScale: CGFloat = 0.82
        static let coverBlurLighterSubInactiveLightnessTrim: CGFloat = 0.02
        static let coverBlurLighterLineTimingSubSaturationScale: CGFloat = 0.92
        static let coverBlurLighterLineTimingSubLightnessTrim: CGFloat = 0.01

        static let coverBlurDarkerHighlightSaturationScale: CGFloat = 0.34
        static let coverBlurDarkerHighlightSaturationBias: CGFloat = 0.08
        static let coverBlurDarkerHighlightSaturationMin: CGFloat = 0.05
        static let coverBlurDarkerHighlightSaturationMax: CGFloat = 0.24
        static let coverBlurDarkerInactiveSaturationScale: CGFloat = 0.18
        static let coverBlurDarkerInactiveSaturationBias: CGFloat = 0.02
        static let coverBlurDarkerInactiveSaturationMin: CGFloat = 0.01
        static let coverBlurDarkerInactiveSaturationMax: CGFloat = 0.10
        static let coverBlurDarkerSubInactiveSaturationScale: CGFloat = 0.90
        static let coverBlurDarkerSubInactiveSaturationMin: CGFloat = 0.01
        static let coverBlurDarkerSubInactiveSaturationMax: CGFloat = 0.09
        static let coverBlurDarkerBaseLightnessAnchor: CGFloat = 0.82
        static let coverBlurDarkerBaseLightnessScale: CGFloat = 0.18
        static let coverBlurDarkerBaseLightnessMin: CGFloat = 0.76
        static let coverBlurDarkerBaseLightnessMax: CGFloat = 0.88
        static let coverBlurDarkerLineTimingTrim: CGFloat = 0.05
        static let coverBlurDarkerLineTimingMin: CGFloat = 0.70
        static let coverBlurDarkerLineTimingMax: CGFloat = 0.82
        static let coverBlurDarkerSubActiveTrim: CGFloat = 0.10
        static let coverBlurDarkerSubActiveMin: CGFloat = 0.62
        static let coverBlurDarkerSubActiveMax: CGFloat = 0.76
        static let coverBlurDarkerHighlightLightnessScale: CGFloat = 0.14
        static let coverBlurDarkerHighlightLightnessBias: CGFloat = 0.32
        static let coverBlurDarkerHighlightLightnessMin: CGFloat = 0.34
        static let coverBlurDarkerHighlightLightnessMax: CGFloat = 0.50
        static let coverBlurDarkerLineTimingSaturationScale: CGFloat = 0.90
        static let coverBlurDarkerSubActiveSaturationScale: CGFloat = 0.78
        static let coverBlurDarkerSubInactiveLightnessTrim: CGFloat = 0.02
        static let coverBlurDarkerLineTimingSubSaturationScale: CGFloat = 0.95
        static let coverBlurDarkerLineTimingSubLightnessTrim: CGFloat = 0.01
    }

    // MARK: - ToneLadder
    //
    // Shared OKLCH tone ladder used by surfaces that need perceptual colour
    // steps rather than "same hue + opacity". v2 reframes the ladder around
    // two principles, after the v1 grey-wash regression:
    //
    //   1. Inactive / secondary roles are L variants of the active hue, not
    //      lower-chroma variants. Chroma scales sit near 1.0 for every role
    //      and hue identity must survive end-to-end.
    //   2. The LED ladder lives in the upper L register (so OKLCH brightness
    //      doesn't fight the opacity ramp) and uses a monotonic chroma scale
    //      so level distinction is not produced by opacity alone.
    //
    // nearMono callers force chroma to the neutral ceiling; the hue is
    // numerically present but visually muted.

    enum ToneLadder {
        static let nearMonoChromaCeiling: CGFloat = 0.004
        static let nearMonoChromaAssertion: CGFloat = 0.005

        // LED ladder. v4 keeps the v3 visible L band but makes the level
        // language explicit: lower levels carry stronger style drift and a
        // wider chroma ramp, while peak returns closest to the semantic seed.
        // Light foreground LEDs gain a stronger night glow. Dark foreground
        // LEDs reverse the L ramp so increasing signal reads as progressively
        // darker ink against bright glass instead of a brighter tint. Skin and
        // MiniPlayer keep separate light-mode endpoints because the compact
        // progress surface needs a slightly tighter dark register.
        //
        // v3 widened the L band substantially so the OKLCH
        // lightness delta is visible *after* the opacity ramp (which is
        // the dominant brightness driver). v2's narrow 0.78–0.92 band was
        // visually flat because the perceived lightness difference between
        // levels was dominated by opacity alone. Chroma climbs toward peak;
        // the output boundary may apply only a small final gamut shoulder for
        // high-risk hues at the brighter lightness target.
        static let ledDarkMinL: CGFloat = 0.680
        static let ledDarkPeakL: CGFloat = 0.855
        static let ledUltraDarkPeakL: CGFloat = 0.845
        static let ledLightMinL: CGFloat = 0.610
        static let ledLightPeakL: CGFloat = 0.300
        static let ledMiniPlayerLightMinL: CGFloat = 0.595
        static let ledMiniPlayerLightPeakL: CGFloat = 0.270
        static let ledAppleStyleMinL: CGFloat = 0.820
        static let ledAppleStylePeakL: CGFloat = 0.970
        static let ledLowChromaScale: CGFloat = 0.74
        static let ledPeakChromaScale: CGFloat = 0.96
        static let ledLightLowChromaScale: CGFloat = 0.70
        static let ledLightPeakChromaScale: CGFloat = 0.94
        static let ledShadowDriftScale: CGFloat = 1.85
        static let ledHighlightDriftScale: CGFloat = 0.0
        static let ledNearMonoChromaCap: CGFloat = 0.006
        static let ledColorfulMinimumChroma: CGFloat = 0.062
        static let ledColorfulMinimumChromaAssertion: CGFloat = 0.055
        static let ledPerceptualStepAssertion: CGFloat = 0.055
        static let ledLightnessVisibilityAssertion: CGFloat = 0.180
        static let ledPeakLightnessCeilingAssertion: CGFloat = 0.95
        static let ledStrokeLightnessTrimDark: CGFloat = 0.060
        static let ledStrokeLightnessTrimLight: CGFloat = 0.040
        static let ledStrokeChromaScale: CGFloat = 0.92

        // Artistic fullscreen lyrics. Single-seed ladder: callers MUST pass
        // the same seed for every role; per-role variation is L (primarily),
        // an optional small chroma adjust, and a family-aware hue drift.
        // Outputs are opaque (alpha = 1.0); the Web layer continues to own
        // opacity / blend / masks / shadow.
        //
        // Dark mode: active L is high (`要再调高一点`), sub-active climbs
        // proportionally so the active-line pair stays the most luminous tier,
        // inactive sits lower (`更沉`), and translation / sub-inactive tracks
        // main-inactive within ~0.005 so the proximity assertion (0.020) holds
        // and the user's "translation 与 inactive 同明度" requirement is
        // enforced numerically. Strict descending order is required by
        // `checkToneLadderBasicHierarchy`:
        //   mainActive > subActive > mainInactive > subInactive
        //               > lineTimingMainInactive > lineTimingSubInactive.
        // Night tuning:
        //   * Active line gets a clear high-L, high-C identity.
        //   * Inactive roles stay lower and less saturated on high-C seeds.
        //   * UltraDark inactive trim keeps night covers from floating grey
        //     text above the artwork layer.
        static let lyricsMainActiveL: CGFloat = 0.935
        static let lyricsSubActiveL: CGFloat = 0.875
        // Darkened slightly so the active/inactive contrast reads more clearly
        // over the artistic background. The night moving-circle ceiling
        // (Phase63TierFixture.nightDotB.upper = 0.52) must stay below
        // lyricsMainInactiveL + 0.005, so 0.535 keeps a 0.020 margin.
        static let lyricsMainInactiveL: CGFloat = 0.535
        static let lyricsSubInactiveL: CGFloat = 0.530
        static let lyricsLineTimingMainInactiveL: CGFloat = 0.510
        static let lyricsLineTimingSubInactiveL: CGFloat = 0.490

        static let lyricsUltraDarkActiveTrim: CGFloat = 0.030
        static let lyricsUltraDarkSubActiveTrim: CGFloat = 0.040
        static let lyricsUltraDarkInactiveTrim: CGFloat = 0.125

        // Light mode (artistic background only): lyric inversion. Light-mode
        // artistic backgrounds are lifted into a high-L band (see
        // `BKColorEngine.tierRanges`), so lyrics flip to a dark ladder.
        // `active` lives at the lowest L (most contrast), inactive and
        // translation occupy a mid-low band. Strict ASCENDING order is required
        // in light mode — opposite of dark — so the same hierarchy check
        // parameterises by scheme:
        //   mainActive < subActive < mainInactive < subInactive
        //               < lineTimingMainInactive < lineTimingSubInactive.
        // Translation (subInactive) sits within ~0.005 of main-inactive so
        // the proximity assertion holds in both schemes.
        //
        // The day background is an independent airy light design, so the dark
        // lyric ladder can be lifted away from dead black while staying below
        // the background.
        static let lyricsLightMainActiveL: CGFloat = 0.335
        static let lyricsLightSubActiveL: CGFloat = 0.450
        static let lyricsLightMainInactiveL: CGFloat = 0.650
        static let lyricsLightSubInactiveL: CGFloat = 0.652
        static let lyricsLightLineTimingMainInactiveL: CGFloat = 0.680
        static let lyricsLightLineTimingSubInactiveL: CGFloat = 0.698

        // Chroma soft-shoulder for high-chroma seeds. The older hard cap
        // (~0.110…0.140 by hue) compressed high-C seeds to a fixed value,
        // which the user reported as "高饱和封面歌词刺眼". A soft shoulder
        // smoothly approaches an asymptote of
        // `lyricsChromaShoulderCeiling + lyricsChromaShoulderSoftness`
        // instead of jumping to the cap. Mid-C seeds (< ceiling) are
        // untouched.
        static let lyricsChromaShoulderCeiling: CGFloat = 0.095
        static let lyricsChromaShoulderSoftness: CGFloat = 0.045
        // Light-mode lyrics use a tighter chroma envelope so dark text on
        // light artwork does not glow with residual hue.
        static let lyricsLightChromaShoulderCeiling: CGFloat = 0.072
        static let lyricsLightChromaShoulderSoftness: CGFloat = 0.030

        // Seed selection. Drives `fullscreenLyricBase` /
        // `artisticLyricsSingleSeed`: area-dominant first, salient highlight
        // only as a conservative override.
        static let lyricsDominantSeedMinChroma: CGFloat = 0.025
        static let lyricsSalientSeedMinChroma: CGFloat = 0.090
        static let lyricsSalientSeedMinHueGapFromDominant: CGFloat = 0.08
        // Cover field is "uniform main + small accent" when EITHER the
        // dominant hue commands a large share AND colorfulness elsewhere is
        // low, OR the largest high-saturation region is small (the cover is
        // mostly low-sat with a punch of colour somewhere).
        static let lyricsSalientSeedMaxFieldColorfulness: CGFloat = 0.18
        static let lyricsSalientSeedDominantConfidenceMin: CGFloat = 0.42
        static let lyricsSalientSeedMaxLargestHighSatArea: CGFloat = 0.22

        // MARK: Subjective focus-score seed selector.
        //
        // The selector models "mostly one field, one intentional accent"
        // with perceptual contrast, salient chroma, dominant-field confidence,
        // competing-high-sat area, and a nonlinear area gate. Dominant remains
        // the default; salient only wins when its score clears this threshold.
        static let lyricsSeedFocusScoreThreshold: CGFloat = 0.62
        // Visual-contrast component: salient.c vs. dominant.c (Δchroma)
        // + ΔL + Δhue. Each term contributes additively, then the sum is
        // normalised to [0,1].
        static let lyricsSeedFocusChromaContrastWeight: CGFloat = 0.45
        static let lyricsSeedFocusLightnessContrastWeight: CGFloat = 0.20
        static let lyricsSeedFocusHueDistanceWeight: CGFloat = 0.35
        // Salience component: salient OKLCH chroma alone (0..0.20 → 0..1).
        static let lyricsSeedFocusSalientChromaSaturationPoint: CGFloat = 0.20
        // Field-uniformity component: how much the dominant bucket
        // dominates and how flat the rest of the field is.
        static let lyricsSeedFocusUniformityColorfulnessTarget: CGFloat = 0.20
        static let lyricsSeedFocusUniformityDominantConfidenceTarget: CGFloat = 0.45
        // Design-focus component: small-area-but-high-chroma highlights
        // read as "designed" — the area share itself penalises huge
        // competing regions.
        static let lyricsSeedFocusDesignAreaShareCeiling: CGFloat = 0.18
        static let lyricsSeedFocusDesignAreaShareHardCeiling: CGFloat = 0.30
        // Noise penalty: tiny isolated dots (area share too small) are
        // likely JPEG artifacts.
        static let lyricsSeedFocusNoiseAreaShareFloor: CGFloat = 0.005
        static let lyricsSeedFocusNoisePenalty: CGFloat = 0.30
        // Competing-salients penalty: if salientHighlightPalette has 2+
        // distinct hue families with comparable chroma, the salient is no
        // longer "designed focal" — penalise.
        static let lyricsSeedFocusCompetingPenalty: CGFloat = 0.25

        // High-chroma shoulder trigger.
        //
        // The soft shoulder engages only when the scaled chroma exceeds this
        // trigger, so moderate seeds pass straight through.
        static let lyricsHighChromaShoulderTrigger: CGFloat = 0.085

        // SelfCheck token: day-mode invariant "lyric L < background L".
        // `BKColorEngine.tierRanges` is asserted to produce bg L floor
        // strictly above this. Day-mode active is the deepest lyric L; bg
        // must be at least this many OKLCH L units brighter.
        static let lyricsLightBackgroundLyricGapMin: CGFloat = 0.20

        // Chroma scales cluster around 1.0 so inactive states keep their hue
        // identity. Active dips slightly below 1.0 to absorb the gamut
        // shoulder near white; mid-L roles can mildly exceed 1.0 so they
        // don't read as desaturated.
        //
        // Active stays chromatic, while inactive/translation/line timing use
        // lower chroma scales so saturated covers no longer make inactive text
        // feel hot.
        static let lyricsMainActiveChromaScale: CGFloat = 1.00
        static let lyricsSubActiveChromaScale: CGFloat = 0.96
        static let lyricsMainInactiveChromaScale: CGFloat = 0.90
        static let lyricsLineTimingMainInactiveChromaScale: CGFloat = 0.86
        static let lyricsSubInactiveChromaScale: CGFloat = 0.88
        static let lyricsLineTimingSubInactiveChromaScale: CGFloat = 0.82
        static let lyricsColorfulMinimumChroma: CGFloat = 0.050
        static let lyricsSeedChromaPreferred: CGFloat = 0.045

        // Self-check thresholds.
        // Active↔inactive L gap is asserted as a magnitude (works for both
        // descending dark-mode order and ascending light-mode order).
        static let lyricsActiveInactiveLightnessGapAssertion: CGFloat = 0.22
        static let lyricsSecondaryInactiveLightnessGapAssertion: CGFloat = 0.15
        // Translation MUST sit on the same perceptual L tier as main-inactive
        // (the user's "和 inactive 普通歌词行明度一样" requirement).
        static let lyricsSubInactiveLightnessProximityAssertion: CGFloat = 0.020
        static let lyricsInactiveChromaRatioAssertion: CGFloat = 0.85
        static let lyricsHueIdentityAssertion: CGFloat = 0.025
        // v3: when the seed has visible chroma, the artistic Tone Ladder
        // must produce lyric output whose chroma stays above this floor
        // even when the upstream `analysis.isNearMonochrome` is true. This
        // is the regression guard for the v2 "grey-wash on colourful art"
        // bug — analysis=neutralFallback + colourful seed must NOT come out
        // grey.
        static let lyricsNearMonoSeedTrustChromaAssertion: CGFloat = 0.040
    }

    // MARK: - UltraDark profile
    //
    // Tone / Darkness axis — describes "the cover is so dark we should
    // respect its night feel" independently of whether it has usable hue.
    // Exposed as a standalone bool on ArtworkColorAnalysis so dark covers with
    // usable hue can keep their chromatic identity while still receiving
    // darkness-preserving treatment.
    //
    // Inputs: avgHslLightness, weighted relativeLuminance, brightest-bucket
    // brightness. All thresholds are conservative — we want to capture
    // night-feel covers, not merely "dim" ones. Anything brighter than
    // `cutoffAvgHslL` is treated as normal lightness.

    enum UltraDark {

        // Primary lightness gate: any cover whose `avgHslL` is at or below
        // this falls into the UltraDark regime. Pick a slightly higher
        // value than the old branch-4 `extremeToneLightnessLo` (0.18) so
        // genuine night photos (0.20 ~ 0.22) are also covered.
        static let cutoffAvgHslL: CGFloat = 0.22

        // Secondary luminance gate (WCAG relative luminance, perceptual).
        // A cover that passes the HSL gate but has a WCAG luma above this
        // is excluded from UltraDark — the HSL average overestimates
        // perceived brightness for hues like neon green / cyan.
        static let cutoffWcagLuma: CGFloat = 0.18

        // Optional brightest-bucket sanity check. UltraDark covers should
        // not have a dominant bucket whose HSB brightness exceeds this —
        // a single bright element on an otherwise dark canvas is still a
        // "dark cover" but anything brighter than this rules out the
        // UltraDark branch (it is a normal cover with a black background).
        static let dominantBrightnessCeiling: CGFloat = 0.60
    }

    // MARK: - NearMonochromeProfile
    //
    // Chromatic confidence axis — describes "the cover does not carry a
    // trustworthy hue" independently of lightness. The four branches below
    // are the cleaned-up successors to the old five OR branches:
    //   - Branch 4 (`isExtremeTone && low sat …`) is removed; the extreme-
    //     tone signal now belongs to UltraDark, not here.
    //   - Branches 1/2/3 retain their original chromatic semantics.
    //   - Branch 5 (dominant-bucket low sat fallback) is preserved as the
    //     last-resort gate — a cover whose own dominant hue carries no
    //     saturation is chromatic-untrustworthy regardless of lightness.
    //
    // `isNearMonochrome` is the OR of these four chromatic gates and is
    // exposed on `ArtworkColorAnalysis`. `isEffectivelyMonochrome` is now
    // an alias of `isNearMonochrome` for backwards compatibility with
    // existing consumers (LED resolver, Home shapes, BKArt, theme log).

    enum NearMonochromeProfile {

        // Branch 1 — strict mono (very flat hue distribution + very low
        // average saturation). Same numbers as the old strict-mono gate.
        static let strictColorfulness: CGFloat = 0.04
        static let strictAvgSaturation: CGFloat = 0.10

        // Branch 2 — typical near-mono cover (subtle hue noise on a flat
        // sleeve, low avgSat, no meaningful saturated region).
        static let lowColorfulness: CGFloat = 0.10
        static let lowAvgSaturation: CGFloat = 0.16
        static let lowMaxHighSatAreaShare: CGFloat = 0.12

        // Branch 3 — subtler version of branch 2: lower avg sat with
        // slightly more colourfulness tolerated (compressed/halftoned
        // sleeves often look like this).
        static let subtleAvgSaturation: CGFloat = 0.105
        static let subtleColorfulness: CGFloat = 0.14
        static let subtleMaxHighSatAreaShare: CGFloat = 0.16

        // Branch 4 — dominant-bucket fallback (was branch 5 in the old
        // EffectiveMonochrome enum). Even if the average looks colourful,
        // if the dominant bucket itself has no saturation we cannot trust
        // a hue — that path is still near-monochrome.
        static let dominantBucketSaturation: CGFloat = 0.18
        static let dominantBucketColorfulness: CGFloat = 0.16
        static let dominantBucketAvgSaturation: CGFloat = 0.18

        // Trust threshold. nearMono should NOT trigger merely because the
        // average saturation is low. A cover where the dominant-bucket centroid
        // (or any displayPalette / salient candidate) has OKLCH chroma >= this
        // floor still has a trustworthy hue.
        static let trustedHueChromaFloor: CGFloat = 0.045

        // Muted-but-real hue evidence. Many real covers have a coherent
        // low-chroma palette whose average saturation stays low (paper scans,
        // vintage photos, compressed album art). They should not be nearMono
        // merely because no single candidate reaches the strong floor above.
        // The muted floor only counts with coherence / area support in
        // `ArtworkHueTrust`.
        static let mutedTrustedHueChromaFloor: CGFloat = 0.018
        static let mutedTrustedAvgSaturationFloor: CGFloat = 0.075
        static let mutedTrustedColorfulnessFloor: CGFloat = 0.080
        static let mutedTrustedDominantSaturationFloor: CGFloat = 0.110
        static let mutedTrustedDominantConfidenceFloor: CGFloat = 0.140
        static let mutedTrustedLargestHighSatAreaFloor: CGFloat = 0.035
        static let mutedTrustedCoherentHueGap: CGFloat = 0.100
        static let mutedTrustedSurfaceChromaFloor: CGFloat = 0.022
        // Surface candidates already come from area-aware material clustering.
        // A slightly stronger one may be trusted on its own so an almost-black
        // cover with a small real skin/paper patch does not collapse to BW.
        static let mutedTrustedSurfaceStandaloneChromaFloor: CGFloat = 0.026
        static let mutedTrustedSurfaceAreaFloor: CGFloat = 0.015
    }

    // MARK: - usesDarkForeground gate
    //
    // Foreground-polarity thresholds for artwork-overlaid UI. Production
    // decisions go through `ArtworkForegroundPolarityPolicy.globalPolarity`,
    // which consumes the `eligibility*` / `clearlyBright*` / `pale*` tokens
    // below. The old single `usesDarkAvgHslL` threshold is retained only as
    // the "current" reference column in the readability parity report, so the
    // dark->light flip list stays auditable.

    enum ReadabilityForeground {
        // Legacy single-threshold. Kept for parity reporting only; the
        // production gate is the strict multi-signal policy below.
        static let usesDarkAvgHslL: CGFloat = 0.58

        // Strict global gate (see ArtworkForegroundPolarityPolicy).
        // A cover must clear `eligibilityAvgHslL` before any bright-evidence
        // signal is even considered.
        static let eligibilityAvgHslL: CGFloat = 0.62
        // Any one of these three "clearly bright" signals commits to dark
        // foreground; otherwise a mid-tone cover stays on light foreground.
        static let clearlyBrightAvgHslL: CGFloat = 0.72
        static let clearlyBrightWcagLuma: CGFloat = 0.62
        static let paleBrightnessFloor: CGFloat = 0.86
        static let paleSaturationCeiling: CGFloat = 0.28

        // Local rendered-backdrop contrast engine
        // (RenderedBackdropReadability). These govern the per-surface polarity
        // override for Home Hero and Cover Gradient Blur fullscreen controls.

        // Longest edge the luminance map is downscaled to. ~36k Float cells at
        // 192² is small enough to build on a render thread and never copy per
        // view.
        static let mapMaximumDimension: Int = 192
        // A region covering fewer map pixels than this is too small to score.
        static let minimumRegionSampleCount: Int = 32
        // Robust (p10) contrast a candidate must reach to be considered
        // clearly readable. WCAG AA for body text is 4.5.
        static let minimumRobustContrast: CGFloat = 4.5
        // Below the minimum but above this floor, a candidate can still win if
        // it is the higher scorer - flagged as contrast-assist (DEBUG only).
        static let absoluteContrastFloor: CGFloat = 3.0
        // Dark foreground must beat light by at least this margin to be
        // chosen; an intentional product bias toward light ink.
        static let darkSelectionAdvantage: CGFloat = 0.95
        // Each sampling rectangle is grown outward by this many points before
        // being clamped, so the score covers the text/glass neighbourhood.
        static let regionExpansionPoints: CGFloat = 14
    }

    // MARK: - SalientHighlight
    //
    // Structured output of small-area, high-visual-impact colours — the
    // "accent" colours a designer would point to on a cover even if they
    // do not dominate the area histogram. Computed from the same 48-hue
    // buckets used by `analyzeInternal`, gated by:
    //
    //   - saturation ≥ `minSaturation` — the bucket has real colour, not
    //     a low-chroma tint;
    //   - brightness ≥ `minBrightness` — exclude dim noise. (No upper
    //     bound: a bright saturated colour like FFD60A is exactly the
    //     kind of highlight we want; pure-white blow-outs are already
    //     rejected by `minSaturation`.);
    //   - area share in [`minAreaShare`, `maxAreaShare`] — large enough
    //     to be a real region, small enough to be a *highlight* (a 60%
    //     dominant region is not a highlight, it IS the cover);
    //   - absolute weight ≥ `noiseFloorAbsolute × totalWeight` — guards
    //     against single-pixel sensor noise.
    //
    // After filtering, candidates are scored by `bucket.weight × (1 +
    // sat × satBonus)` and deduplicated by hue.

    enum SalientHighlight {
        static let minSaturation: CGFloat = 0.40
        static let minBrightness: CGFloat = 0.30
        static let minAreaShare: CGFloat = 0.015
        static let maxAreaShare: CGFloat = 0.30
        static let noiseFloorAbsolute: CGFloat = 0.008
        static let tinyNoiseFloorAbsolute: CGFloat = 0.0015
        static let dimAccentMinSaturation: CGFloat = 0.72
        static let dimAccentMinBrightness: CGFloat = 0.16
        static let dimAccentMinAreaShare: CGFloat = 0.010
        static let microAccentMinSaturation: CGFloat = 0.70
        static let microAccentMinBrightness: CGFloat = 0.34
        static let microAccentMinAreaShare: CGFloat = 0.00075
        static let microAccentMinSupportedAreaShare: CGFloat = 0.0010
        static let microAccentMinLargestHighSatAreaShare: CGFloat = 0.006
        static let microAccentMaxAreaShare: CGFloat = 0.040
        static let satBonus: CGFloat = 0.50
        static let hueDedupGap: CGFloat = 0.05
        static let rgbDedupGap: CGFloat = 0.14
        static let maxCount: Int = 4
    }

    // MARK: - DisplayPalette
    //
    // Quality-controlled merge of topPalette + salientHighlightPalette +
    // a curated slice of richPalette. Intended for downstream UI surfaces
    // (Home Shapes, BKArt, Spectrum).
    //
    // Key guarantees:
    //   - On `isNearMonochrome` covers, do NOT fabricate multi-colour. The
    //     palette stays narrow (1-2 honest colours).
    //   - Otherwise, merge sources in order of confidence (top → salient →
    //     rich), keeping each candidate only when sufficiently distinct
    //     from earlier entries (hue gap OR RGB distance).
    //   - Cap at `maxCount` so consumers can size containers up-front.

    enum DisplayPalette {
        static let maxCount: Int = 6
        static let nearMonoMaxCount: Int = 2
        static let hueDistinctGap: CGFloat = 0.05
        static let rgbDistinctGap: CGFloat = 0.14
    }

    // MARK: - ReadabilityProfile
    //
    // Alpha tiers and OKLCH neutralisation thresholds used by the
    // `ArtworkReadabilityProfile` semantic — the unified "compress UI on
    // top of artwork" decision. Replaces ad-hoc `usesDarkForeground` reads
    // and per-view alpha derivations across MiniPlayer / Home Hero /
    // CoverGradient blur consumers.
    //
    // Near-mono neutralisation: when the cover lacks trustworthy hue, the
    // profile clamps OKLCH chroma below the human perceptual threshold so
    // overlaid text and icons read as honest neutral rather than as faint
    // pink / blue / yellow tints.

    enum ReadabilityProfile {
        // Stacked-tier alphas (primary @ 1.0; secondary–quaternary derived).
        static let secondaryAlpha: CGFloat = 0.78
        static let tertiaryAlpha: CGFloat = 0.58
        static let quaternaryAlpha: CGFloat = 0.40

        // Maximum OKLCH chroma retained when `analysis.isNearMonochrome` is
        // true. 0.004 is well below the perceptual threshold (~0.01 in
        // OKLCH); pairs with `nearMonoHueDistanceAssertion` so the
        // self-check can verify hue collapse rather than just chroma.
        static let nearMonoChromaCeiling: CGFloat = 0.004

        // Self-check assertion: near-mono foreground OKLCH chroma must not
        // exceed this. Slightly above the ceiling for numerical slack.
        static let nearMonoChromaAssertion: CGFloat = 0.005
    }

    // MARK: - MiniPlayerControl
    //
    // OKLCH-lifted control palette consumed by `FullscreenMiniPlayerView`
    // when the mini player surface is chrome (default liquid-glass pill).
    // When the surface is the artwork itself (Cover Gradient Blur "clear"
    // material), the view falls through to `ReadabilityProfile.foregroundPrimary`
    // — the artwork-readability profile owns that path.
    //
    // Bands derive empirically from the legacy `resolveControlAccentColor`
    // HSL bounds (min L 0.90, max L 0.98, min S 0.88) re-expressed in
    // OKLCH and gated on `isNearMonochrome`. Near-mono covers force a
    // perceptually-achromatic warm white at L≈0.94 so no residual hue
    // bleeds into icons / progress bar / playback-mode capsule.

    enum MiniPlayerControl {
        // Coloured-accent path bounds (artwork has trustworthy hue).
        static let liftedMinL: CGFloat = 0.88
        static let liftedMaxL: CGFloat = 0.97
        static let liftedChromaCap: CGFloat = 0.12

        // Near-mono path constant (perceptually achromatic warm white).
        static let neutralL: CGFloat = 0.94

        // Self-check assertion: near-mono control OKLCH chroma must not
        // exceed this. Smaller than ReadabilityProfile's value because the
        // control path never goes through the artwork-text-source tint —
        // it starts from globalAccent which already carries the nearMono
        // accent's residual hue, and we want to crush it entirely.
        static let nearMonoChromaAssertion: CGFloat = 0.005
    }

    // MARK: - PlusBlendText
    //
    // Pre-blend source colours for text rendered with SwiftUI's
    // `.plusLighter` / `.plusDarker` modes. These must deliberately avoid the
    // usual near-white / near-black text endpoints: additive blending would
    // clip the former, while subtractive blending would crush the latter.
    // The blend operation supplies the final contrast; the source colour stays
    // inside a neutral middle band and carries only a restrained theme tint.

    enum PlusBlendText {
        // `.plusLighter` adds the source into a dark backdrop, so its source
        // stays below ordinary light text. Secondary text adds less energy.
        static let plusLighterPrimaryL: CGFloat = 0.78
        static let plusLighterSecondaryL: CGFloat = 0.66
        static let plusLighterTertiaryL: CGFloat = 0.58
        static let plusLighterQuaternaryL: CGFloat = 0.52

        // `.plusDarker` subtracts from a light backdrop, so its source must be
        // substantially lighter than ordinary dark ink. Secondary text stays
        // closer to the backdrop and therefore darkens it less.
        static let plusDarkerPrimaryL: CGFloat = 0.42
        static let plusDarkerSecondaryL: CGFloat = 0.57
        static let plusDarkerTertiaryL: CGFloat = 0.66
        static let plusDarkerQuaternaryL: CGFloat = 0.73

        static let primaryAlpha: CGFloat = 1.00
        static let secondaryAlpha: CGFloat = 0.84
        static let tertiaryAlpha: CGFloat = 0.70
        static let quaternaryAlpha: CGFloat = 0.56

        // Plus blending amplifies RGB differences, so keep the pre-blend tint
        // much nearer neutral than ordinary App foreground colours.
        static let chromaCap: CGFloat = 0.030
        static let colorfulnessSaturationPoint: CGFloat = 0.40

        // Self-check bounds documenting the safe pre-blend lightness band.
        static let minimumSourceL: CGFloat = 0.20
        static let maximumSourceL: CGFloat = 0.92
        static let nearMonoChromaAssertion: CGFloat = 0.005
    }

    // MARK: - AppForeground
    //
    // OKLCH tinted-neutral foreground palette for ordinary App UI — sidebar
    // navigation text, library list text, settings labels, Home section
    // captions, empty-state copy. These are NOT for use over artwork; that
    // job belongs to `ArtworkReadabilityProfile`.
    //
    // Design goal: foreground that carries a subtly detectable artwork-derived
    // hue tint while reading as "mostly neutral" text at a glance.
    //
    // Generation: hue taken from `globalAccent` OKLCH hue; chroma scales
    // linearly with artwork `colorfulness` up to `colorfulnessSaturationPoint`,
    // then caps at the per-tier limit, then a hue-aware factor further reduces
    // chroma for cool/violet hues in dark mode (blue-white text reads
    // unnaturally at the same chroma as warm-white text). On `isNearMonochrome`
    // covers the chroma is forced to 0 — all tiers are perceptually achromatic.
    //
    // Recalibration notes (2026-05 v2):
    //   • Secondary/tertiary dark-mode caps tightened — ratio to primary ~0.60
    //     and ~0.37 respectively, so grey-tier text does not appear chromatic.
    //   • Dark-mode cool-hue reduction added: blue/cyan hues get 0.65× factor,
    //     violet hues get 0.75× factor, matching the perceptual difference
    //     between warm and cool neutrals in dark UI contexts.
    //   • Light-mode primary L raised 0.14→0.22 so the tint is visible — at
    //     L=0.14 (near-black) even C=0.100 is imperceptible; dark charcoal
    //     (L=0.22) gives the chroma room to register. Secondary L similarly
    //     raised to 0.38.
    //   • Light-mode secondary/tertiary chroma caps reduced proportionally so
    //     grey text stays clearly subordinate to primary tinted text.

    enum AppForeground {

        // Foreground hierarchy is opacity-driven. Primary stays opaque; the
        // subordinate tiers use a closely related, slightly more chromatic
        // source colour and descend mainly through alpha. Keeping their source
        // lightness near primary avoids muddy grey text on tinted/material
        // surfaces while alpha lets the actual backdrop participate naturally.
        static let darkPrimaryL: CGFloat    = 0.960
        static let darkSecondaryL: CGFloat  = 0.920
        static let darkTertiaryL: CGFloat   = 0.910
        static let darkQuaternaryL: CGFloat = 0.900
        static let darkDisabledL: CGFloat   = 0.860

        // Light-mode source colours remain close to the primary dark ink. The
        // composited result becomes lighter through alpha rather than by
        // manufacturing progressively greyer opaque colours.
        static let lightPrimaryL: CGFloat    = 0.220
        static let lightSecondaryL: CGFloat  = 0.235
        static let lightTertiaryL: CGFloat   = 0.245
        static let lightQuaternaryL: CGFloat = 0.255
        static let lightDisabledL: CGFloat   = 0.300

        // Semantic opacity ladder. These are the primary hierarchy controls;
        // source-L differences above are deliberately small stabilizers only.
        static let primaryAlpha: CGFloat    = 1.00
        static let secondaryAlpha: CGFloat  = 0.78
        static let tertiaryAlpha: CGFloat   = 0.60
        static let quaternaryAlpha: CGFloat = 0.44
        static let disabledAlpha: CGFloat   = 0.36

        // Subordinate source colours are intentionally more chromatic than the
        // old opaque tiers. Their alpha reduces the perceived chroma after
        // compositing, preserving the former restraint without washing them
        // into flat grey on glass/material backgrounds.
        static let primaryChromaCap: CGFloat    = 0.070
        static let secondaryChromaCap: CGFloat  = 0.078
        static let tertiaryChromaCap: CGFloat   = 0.070
        static let quaternaryChromaCap: CGFloat = 0.056
        static let disabledChromaCap: CGFloat   = 0.000

        // Dark-mode hue-aware chroma scale factors.
        // Cool (blue/cyan) and violet hues produce a visually "heavy" or
        // "cold-dirty" tint at the same OKLCH chroma as warm hues, because
        // the eye adapts to warm neutral white in dark UIs. Apply a moderate
        // reduction so the tint reads as temperature rather than colour.
        static let darkHueCoolScaleFactor: CGFloat   = 0.65  // hue 0.40…0.72
        static let darkHueVioletScaleFactor: CGFloat = 0.75  // hue 0.72…0.88
        static let darkHueCoolRangeLo: CGFloat       = 0.40
        static let darkHueCoolRangeHi: CGFloat       = 0.72
        static let darkHueVioletRangeLo: CGFloat     = 0.72
        static let darkHueVioletRangeHi: CGFloat     = 0.88

        // Light-mode subordinate sources receive the same pre-alpha chroma
        // compensation. The final composited colour remains subordinate.
        static let lightPrimaryChromaCap: CGFloat    = 0.095
        static let lightSecondaryChromaCap: CGFloat  = 0.108
        static let lightTertiaryChromaCap: CGFloat   = 0.096
        static let lightQuaternaryChromaCap: CGFloat = 0.078

        // Artwork colorfulness level at which tier caps are fully applied.
        // Below this the chroma scales proportionally (linear ramp).
        static let colorfulnessSaturationPoint: CGFloat = 0.40

        // Absolute safety ceiling applied after per-tier cap (dark mode).
        // Must be ≥ primaryChromaCap; acts as a global backstop only.
        static let chromaCeiling: CGFloat = 0.095

        // Absolute safety ceiling for light-mode tiers.
        // Must be ≥ lightPrimaryChromaCap.
        static let lightChromaCeiling: CGFloat = 0.115

        // Self-check assertions.
        static let nearMonoChromaAssertion: CGFloat      = 0.005  // must be achromatic on nearMono
        static let colorfulChromaAssertion: CGFloat      = 0.090  // dark-mode colorful primary ceiling
        static let lightColorfulChromaAssertion: CGFloat = 0.110  // light-mode colorful primary ceiling
        static let darkPrimaryLAssertion: CGFloat        = 0.90   // dark primary must stay near white
        static let lightPrimaryLAssertion: CGFloat       = 0.26   // light primary L ≥ 0.22

        // Self-check limits for the compensated source colours.
        static let darkSecondaryChromaAssertion: CGFloat = 0.082
        static let subordinateSourceLightnessDeltaAssertion: CGFloat = 0.08
    }

}
