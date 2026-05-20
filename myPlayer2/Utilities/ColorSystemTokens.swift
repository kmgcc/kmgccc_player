//
//  ColorSystemTokens.swift
//  myPlayer2
//
//  Central registry for colour-decision thresholds, clamps, ceilings, and
//  fixed targets used by the palette / theme system. Phase 1 lifted magic
//  numbers from `SemanticPaletteFactory` (and the `isEffectivelyMonochrome`
//  gate that drives it) into named constants. Phase 2 splits the old
//  `EffectiveMonochrome` gate into two orthogonal axes — `UltraDark`
//  (lightness only) and `NearMonochromeProfile` (chromatic confidence only) —
//  and adds tokens for the new structured outputs (`SalientHighlight`,
//  `DisplayPalette`).
//
//  Naming reflects semantic intent (`Accent.darkMinLByHueViolet`,
//  `NearMonochromeProfile.strictColorfulness`) so future phases can swap
//  the underlying expression — e.g., OKLCH equivalents — without touching
//  call sites.
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
    // Drives the accent on covers where `isNearMonochrome == true`.
    // Output is a desaturated tone, hue chosen from the average (if any
    // hue is usable) or a fixed neutral hue otherwise. This is the
    // "anti-fake-color" path — it must not be relied on for ultra-dark
    // protection (which is now a separate orthogonal axis).

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

    // MARK: - UltraDark profile (Phase 2)
    //
    // Tone / Darkness axis — describes "the cover is so dark we should
    // respect its night feel" independently of whether it has usable hue.
    // Phase 2 introduces this as a standalone bool on ArtworkColorAnalysis
    // so future phases can:
    //   - relax the `darkMinL` accent floor on (UltraDark=T, NearMono=F)
    //     covers (deep violet, dark teal, midnight red);
    //   - keep `nearMonochromeAccent` strictly chromatic.
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

    // MARK: - NearMonochromeProfile (Phase 2 — replaces EffectiveMonochrome)
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
    }

    // MARK: - usesDarkForeground gate
    //
    // The `avgHslL` cut-off used by `ArtworkColorAnalysis` for choosing
    // whether text-over-cover should default to dark ink or light ink.
    // Identical to the old `EffectiveMonochrome.usesDarkForegroundAvgHslL`
    // value — Phase 2 just gives it its own namespace so the orthogonal
    // axes don't pretend to own it.

    enum ReadabilityForeground {
        static let usesDarkAvgHslL: CGFloat = 0.58
    }

    // MARK: - SalientHighlight (Phase 2)
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
        static let satBonus: CGFloat = 0.50
        static let hueDedupGap: CGFloat = 0.05
        static let rgbDedupGap: CGFloat = 0.14
        static let maxCount: Int = 4
    }

    // MARK: - DisplayPalette (Phase 2)
    //
    // Quality-controlled merge of topPalette + salientHighlightPalette +
    // a curated slice of richPalette. Intended for downstream UI surfaces
    // (Home Shapes, BKArt, Spectrum) to consume in Phase 3 — Phase 2 only
    // *produces* it; no UI surface reads it yet.
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

    // MARK: - ReadabilityProfile (Phase 4)
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

    // MARK: - MiniPlayerControl (Phase 4)
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

    // MARK: - EffectiveMonochrome (Phase 1 — deprecated namespace)
    //
    // Phase 2 splits these branches into `UltraDark` (lightness) and
    // `NearMonochromeProfile` (chromatic). The old namespace is retained
    // only so external references (debug log strings, future grep
    // archeology) still resolve — every NUMERIC threshold has been moved.
    //
    // No production code path reads from this namespace anymore.

    @available(*, deprecated, message: "Phase 2: use UltraDark or NearMonochromeProfile.")
    enum EffectiveMonochrome {
        static let strictColorfulness: CGFloat = NearMonochromeProfile.strictColorfulness
        static let strictAvgSaturation: CGFloat = NearMonochromeProfile.strictAvgSaturation
        static let usesDarkForegroundAvgHslL: CGFloat = ReadabilityForeground.usesDarkAvgHslL
    }
}
