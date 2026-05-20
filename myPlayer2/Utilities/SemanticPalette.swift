//
//  SemanticPalette.swift
//  myPlayer2
//
//  Per-role colours derived from a single ArtworkColorAnalysis. UI surfaces
//  read these instead of running their own extraction. Phase 2 wires up the
//  factory with placeholder behaviour that exactly mirrors today's output;
//  later phases harden each role.
//

import AppKit
import SwiftUI

struct SemanticPalette: Equatable, Sendable {
    let scheme: ColorScheme
    let analysis: ArtworkColorAnalysis

    let globalAccent: NSColor
    let uiAccentOnDark: NSColor
    let uiAccentOnLight: NSColor

    let ambientSurface: NSColor
    let artBackgroundPrimary: NSColor
    let artBackgroundSecondary: NSColor

    let readableTextOnArtwork: NSColor
    let secondaryTextOnArtwork: NSColor

    let windowLyricActive: NSColor
    let windowLyricInactive: NSColor

    let fullscreenLyricBase: NSColor
    let fullscreenLyricInactiveBase: NSColor

    let coverGradientDominant: NSColor
    let coverGradientText: NSColor

    /// Phase 4 — unified "compress UI on top of artwork" semantic. Owned
    /// by the palette so HomeHero / Library header / Fullscreen MiniPlayer
    /// / Cover Gradient Blur overlays can share one near-mono-aware
    /// foreground decision instead of each reinventing usesDarkForeground.
    let readabilityProfile: ArtworkReadabilityProfile

    /// Phase 4 — control colour for the fullscreen mini player on chrome
    /// surfaces (default liquid-glass pill). When the mini player sits
    /// directly on artwork (Cover Gradient Blur "clear" material), the
    /// view consumes `readabilityProfile.foregroundPrimary` instead. The
    /// palette is OKLCH-lifted and crushes near-mono hue so the controls
    /// never read as faint pastels under grey covers.
    let miniPlayerControl: MiniPlayerControlPalette
}

/// "Compress UI on top of artwork" readability decision. One profile
/// per artwork — consumed by HomeHero overlay text, Fullscreen MiniPlayer
/// (when surface is artwork), and any future surface that draws over a
/// cover or its blur. The profile bakes in near-mono neutralisation so
/// downstream views never see a tinted output on a grey artwork.
///
/// Phase 4 invariant: when `analysis.isNearMonochrome == true`, every
/// foreground colour exposed here has OKLCH chroma ≤
/// `ColorSystemTokens.ReadabilityProfile.nearMonoChromaCeiling`.
/// `ColorSystemSelfCheck.checkReadabilityProfileNearMonoNeutral`
/// asserts this with a small numerical slack.
struct ArtworkReadabilityProfile: Equatable, Sendable {
    /// True when the artwork is bright enough that dark text is more
    /// readable than light text. Passes through `analysis.usesDarkForeground`;
    /// callers that need a stricter gate (e.g. blurred-cover surfaces)
    /// must layer their own check on top.
    let usesDarkForeground: Bool

    /// Mirrors `analysis.isNearMonochrome`. Surfaced here so consumers
    /// can react without coupling to ArtworkColorAnalysis directly.
    let isNearMonochrome: Bool

    /// Primary foreground for text and icons on artwork. Already
    /// near-mono-neutralised; alpha 1.0.
    let foregroundPrimary: NSColor

    /// Secondary foreground (artist row, captions, time labels). Same
    /// hue/L as primary, alpha `ReadabilityProfile.secondaryAlpha`.
    let foregroundSecondary: NSColor

    /// Tertiary foreground (small metadata, separators). Same hue/L,
    /// alpha `ReadabilityProfile.tertiaryAlpha`.
    let foregroundTertiary: NSColor

    /// Quaternary foreground (faint separators, watermarks). Same hue/L,
    /// alpha `ReadabilityProfile.quaternaryAlpha`.
    let foregroundQuaternary: NSColor

    /// Icon-tier foreground. Same as primary today; named distinctly so
    /// later phases can dial in a different chroma cap for SF Symbol
    /// rendering without touching text consumers.
    let iconForeground: NSColor
}

/// Control palette for the fullscreen mini player when the surface is
/// chrome (default liquid-glass pill). Sourced from `globalAccent` via
/// OKLCH lifting; on near-mono covers it collapses to a perceptually
/// achromatic warm white so transport controls do not appear faintly
/// tinted on grey artwork.
///
/// Phase 4 invariant: when `analysis.isNearMonochrome == true`, `primary`
/// has OKLCH chroma ≤ `ColorSystemTokens.MiniPlayerControl.nearMonoChromaAssertion`.
struct MiniPlayerControlPalette: Equatable, Sendable {
    /// Primary control colour for icons, transport buttons, and the
    /// playback-mode capsule on chrome surfaces. Alpha 1.0; views apply
    /// their own opacity stack.
    let primary: NSColor

    /// Secondary control colour for unselected segmented buttons,
    /// disabled-but-hinting transport controls. Same source as
    /// `primary` with reduced alpha.
    let secondary: NSColor

    /// Progress bar fill source (the view multiplies by its own opacity).
    let progressFill: NSColor

    /// Progress bar track source.
    let progressTrack: NSColor
}

enum SemanticPaletteFactory {
    static func make(
        from analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        userFallbackAccent: NSColor,
        useArtworkTint: Bool
    ) -> SemanticPalette {
        let isDark = scheme == .dark
        let globalAccent: NSColor
        if useArtworkTint {
            globalAccent = optimizedAccent(for: scheme, analysis: analysis)
        } else {
            globalAccent = isDark
                ? ColorMath.clampLightness(
                    userFallbackAccent,
                    lo: ColorSystemTokens.FallbackAccent.darkMinL,
                    hi: ColorSystemTokens.FallbackAccent.darkMaxL
                )
                : ColorMath.clampLightness(
                    userFallbackAccent,
                    lo: ColorSystemTokens.FallbackAccent.lightMinL,
                    hi: ColorSystemTokens.FallbackAccent.lightMaxL
                )
            // Debug: log resolved accent RGB so we can confirm the runtime colour.
            let inC = ColorMath.hsl(of: userFallbackAccent)
            let outC = ColorMath.hsl(of: globalAccent)
            let outNS = globalAccent.usingColorSpace(.deviceRGB) ?? globalAccent
            let r8 = Int((outNS.redComponent * 255).rounded())
            let g8 = Int((outNS.greenComponent * 255).rounded())
            let b8 = Int((outNS.blueComponent * 255).rounded())
            Log.debug(
                "Palette fallback accent: \(isDark ? "dark" : "light") "
                + "in hsl(\(f3(inC.h)),\(f3(inC.s)),\(f3(inC.l))) "
                + "→ rgb(\(r8),\(g8),\(b8)) hsl(\(f3(outC.h)),\(f3(outC.s)),\(f3(outC.l)))",
                category: .theme
            )
        }

        let readability = readabilityProfile(analysis: analysis)
        let control = miniPlayerControl(
            analysis: analysis,
            globalAccent: globalAccent
        )

        return SemanticPalette(
            scheme: scheme,
            analysis: analysis,
            globalAccent: globalAccent,
            uiAccentOnDark: optimizedAccent(for: .dark, analysis: analysis),
            uiAccentOnLight: optimizedAccent(for: .light, analysis: analysis),
            ambientSurface: ambientSurface(analysis: analysis, isDark: isDark),
            artBackgroundPrimary: artBackgroundPrimary(analysis: analysis, isDark: isDark),
            artBackgroundSecondary: artBackgroundSecondary(analysis: analysis, isDark: isDark),
            readableTextOnArtwork: readability.foregroundPrimary,
            secondaryTextOnArtwork: readability.foregroundSecondary,
            windowLyricActive: windowLyricActive(analysis: analysis, isDark: isDark),
            windowLyricInactive: windowLyricInactive(analysis: analysis, isDark: isDark),
            fullscreenLyricBase: fullscreenLyricBase(analysis: analysis),
            fullscreenLyricInactiveBase: fullscreenLyricInactiveBase(analysis: analysis),
            coverGradientDominant: coverGradientDominant(analysis: analysis, isDark: isDark),
            coverGradientText: coverGradientText(analysis: analysis),
            readabilityProfile: readability,
            miniPlayerControl: control
        )
    }

    // MARK: - Phase 4 readability + MiniPlayer control

    /// Owner of the "compress UI on top of artwork" readability decision.
    /// Wraps the legacy `readableTextOnArtwork` HSL derivation in an OKLCH
    /// near-mono neutraliser so downstream consumers (HomeHero overlay,
    /// FullscreenMiniPlayer over artwork, future Library header overlay)
    /// never receive a tinted output on a grey artwork.
    nonisolated fileprivate static func readabilityProfile(
        analysis: ArtworkColorAnalysis
    ) -> ArtworkReadabilityProfile {
        let basePrimary = readableTextOnArtwork(analysis: analysis)
        let primary = neutraliseIfNearMono(basePrimary, analysis: analysis)
        let secondary = primary.withAlphaComponent(
            ColorSystemTokens.ReadabilityProfile.secondaryAlpha
        )
        let tertiary = primary.withAlphaComponent(
            ColorSystemTokens.ReadabilityProfile.tertiaryAlpha
        )
        let quaternary = primary.withAlphaComponent(
            ColorSystemTokens.ReadabilityProfile.quaternaryAlpha
        )
        return ArtworkReadabilityProfile(
            usesDarkForeground: analysis.usesDarkForeground,
            isNearMonochrome: analysis.isNearMonochrome,
            foregroundPrimary: primary,
            foregroundSecondary: secondary,
            foregroundTertiary: tertiary,
            foregroundQuaternary: quaternary,
            iconForeground: primary
        )
    }

    /// Owner of the mini-player control colour on chrome surfaces. The
    /// view layer chooses between this and `readabilityProfile.foregroundPrimary`
    /// based on whether its surface is the artwork itself.
    ///
    /// On near-mono artworks the colour collapses to a perceptually
    /// achromatic warm white (OKLCH L≈0.94, C=0). This is the explicit
    /// Phase 4 fix for the "淡蓝/淡黄" leak users saw on grey covers —
    /// the legacy `resolveControlAccentColor` lifted HSL saturation to
    /// ≥0.88, which amplified the near-mono accent's residual hue into a
    /// visible pastel.
    nonisolated fileprivate static func miniPlayerControl(
        analysis: ArtworkColorAnalysis,
        globalAccent: NSColor
    ) -> MiniPlayerControlPalette {
        let primary: NSColor
        if analysis.isNearMonochrome {
            primary = neutralAchromaticControl()
        } else {
            primary = liftedAccentControl(globalAccent)
        }
        let secondary = primary.withAlphaComponent(
            ColorSystemTokens.ReadabilityProfile.secondaryAlpha
        )
        let progressFill = primary
        let progressTrack = primary.withAlphaComponent(
            ColorSystemTokens.ReadabilityProfile.tertiaryAlpha
        )
        return MiniPlayerControlPalette(
            primary: primary,
            secondary: secondary,
            progressFill: progressFill,
            progressTrack: progressTrack
        )
    }

    /// OKLCH-lift the resolved accent into the mini-player chrome band.
    /// On covers with usable hue this preserves the artwork's character
    /// while ensuring the control reads bright on the darkened liquid-
    /// glass pill (the mini player's chrome surface is darkened in both
    /// colour schemes, hence the consistent L≥0.88 target).
    nonisolated fileprivate static func liftedAccentControl(_ color: NSColor) -> NSColor {
        guard let lch = OKColor.nsColorToOKLCH(color) else {
            return NSColor(deviceRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        }
        let lifted = OKColor.OKLCH(
            l: ColorMath.clamp(
                Swift.max(lch.l, ColorSystemTokens.MiniPlayerControl.liftedMinL),
                ColorSystemTokens.MiniPlayerControl.liftedMinL,
                ColorSystemTokens.MiniPlayerControl.liftedMaxL
            ),
            c: Swift.min(lch.c, ColorSystemTokens.MiniPlayerControl.liftedChromaCap),
            h: lch.h
        )
        return OKColor.okLCHToNSColor(lifted, alpha: 1)
    }

    /// Perceptually achromatic warm white. Used as the near-mono fallback
    /// for the mini-player control colour. OKLCH(L=0.94, C=0) renders as
    /// a clean off-white that carries no hue regardless of which neutral
    /// the OKLCH→sRGB conversion lands on.
    nonisolated fileprivate static func neutralAchromaticControl() -> NSColor {
        let lch = OKColor.OKLCH(
            l: ColorSystemTokens.MiniPlayerControl.neutralL,
            c: 0,
            h: 0
        )
        return OKColor.okLCHToNSColor(lch, alpha: 1)
    }

    /// Crush OKLCH chroma below the perceptual threshold when the cover
    /// is near-monochrome. Hue/L are preserved; only chroma collapses so
    /// the foreground shifts from "off-white with faint hue" to "honest
    /// off-white". Identity outside the near-mono regime.
    nonisolated private static func neutraliseIfNearMono(
        _ color: NSColor,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        guard analysis.isNearMonochrome else { return color }
        guard let lch = OKColor.nsColorToOKLCH(color) else { return color }
        let crushed = OKColor.OKLCH(
            l: lch.l,
            c: Swift.min(lch.c, ColorSystemTokens.ReadabilityProfile.nearMonoChromaCeiling),
            h: lch.h
        )
        return OKColor.okLCHToNSColor(crushed, alpha: color.alphaComponent)
    }

    // MARK: - Role derivations (Phase 2 placeholders)

    fileprivate static func optimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        // The branch below is the "anti-fake-color" path — covers without a
        // trustworthy hue (greyscale, near-white sleeves, dim duo-tones).
        // It is NOT an ultra-dark protector: dark-but-colourful covers such
        // as deep violet / midnight teal now correctly fall through to
        // optimizedAccent and keep their hue (Phase 2 K.2).
        if analysis.isNearMonochrome {
            return nearMonochromeAccent(for: scheme, analysis: analysis)
        }

        let raw = analysis.dominantColor
        let comp = ColorMath.hsl(of: raw)
        var h = comp.h, s = comp.s, l = comp.l

        // Hue guard: covers whose average hue sits in the warm-yellow / beige /
        // ochre band must not produce a red or pink accent — small brown spots
        // can drift the dominant bucket past the band, so snap back to avgHue.
        let avg = analysis.avgHue
        let isWarmAvg = avg >= ColorSystemTokens.Accent.warmGuardHueLo
            && avg <= ColorSystemTokens.Accent.warmGuardHueHi
        let isWarmConfident = analysis.dominantHueConfidence
            >= ColorSystemTokens.Accent.warmGuardHueConfidenceMin
        if isWarmAvg && isWarmConfident {
            let inWarmBand = (h >= ColorSystemTokens.Accent.warmBandHueLo
                              && h <= ColorSystemTokens.Accent.warmBandHueHi)
            let drifted = ColorMath.circularHueDistance(h, avg)
                > ColorSystemTokens.Accent.warmGuardDriftThreshold
            if !inWarmBand || drifted {
                h = avg
            }
        }

        // Hue-aware minimum lightness on dark surfaces. Yellow/orange already glow
        // at lower L; blue/violet/red need higher L to remain readable.
        let darkMinL: CGFloat = {
            switch h {
            case 0.10..<0.18: return ColorSystemTokens.Accent.darkMinLByHueYellowOrange
            case 0.18..<0.42: return ColorSystemTokens.Accent.darkMinLByHueGreen
            case 0.42..<0.72: return ColorSystemTokens.Accent.darkMinLByHueCyanBlue
            case 0.72..<0.85: return ColorSystemTokens.Accent.darkMinLByHueViolet
            default:           return ColorSystemTokens.Accent.darkMinLByHueDefault
            }
        }()
        let darkMaxL: CGFloat = ColorSystemTokens.Accent.darkLightnessCeiling

        if scheme == .dark {
            s = ColorMath.clamp(
                max(s * ColorSystemTokens.Accent.darkSaturationLift,
                    ColorSystemTokens.Accent.darkSaturationFloor),
                ColorSystemTokens.Accent.darkSaturationFloor,
                ColorSystemTokens.Accent.darkSaturationCeiling
            )
            l = ColorMath.clamp(max(l, darkMinL), darkMinL, darkMaxL)
        } else {
            // Light mode: hue-aware saturation ceiling. Cheap/garish hues
            // (medical green, magenta, industrial blue) cap lower; warm yellow
            // / orange can stay richer. Use a soft shoulder so colours just
            // above the ceiling compress smoothly instead of clipping.
            let lightSatCeiling: CGFloat = {
                switch h {
                case 0.83..<1.00, 0.00..<0.03:
                    return ColorSystemTokens.Accent.lightSatCeilingPinkMagenta
                case 0.72..<0.83:
                    return ColorSystemTokens.Accent.lightSatCeilingPurpleViolet
                case 0.30..<0.50:
                    return ColorSystemTokens.Accent.lightSatCeilingMedicalGreen
                case 0.50..<0.65:
                    return ColorSystemTokens.Accent.lightSatCeilingIndustrialBlue
                case 0.65..<0.72:
                    return ColorSystemTokens.Accent.lightSatCeilingDeepBlue
                case 0.03..<0.10:
                    return ColorSystemTokens.Accent.lightSatCeilingWarmRedOrange
                case 0.10..<0.20:
                    return ColorSystemTokens.Accent.lightSatCeilingYellowAmber
                case 0.20..<0.30:
                    return ColorSystemTokens.Accent.lightSatCeilingChartreuse
                default:
                    return ColorSystemTokens.Accent.lightSatCeilingDefault
                }
            }()
            let raised = max(
                s * ColorSystemTokens.Accent.lightSaturationLift,
                ColorSystemTokens.Accent.lightSaturationFloor
            )
            let softened = ColorMath.softShoulder(
                raised,
                ceiling: lightSatCeiling,
                softness: ColorSystemTokens.Accent.lightSatShoulderSoftness
            )
            s = ColorMath.clamp(
                softened,
                ColorSystemTokens.Accent.lightSaturationFloor,
                ColorSystemTokens.Accent.lightSaturationOuterCeiling
            )
            l = ColorMath.clamp(
                min(l * ColorSystemTokens.Accent.lightLightnessScale,
                    ColorSystemTokens.Accent.lightLightnessCeiling),
                ColorSystemTokens.Accent.lightLightnessFloor,
                ColorSystemTokens.Accent.lightLightnessCeiling
            )
        }

        // Saturation safety net for low-colour covers — the dominant bucket on a
        // grey/black/white cover with a few pink/red noise pixels will *look*
        // saturated; cap it so the noise can't paint the accent neon.
        if analysis.isMonochrome {
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.strictMonoSatCapDark
                : ColorSystemTokens.Accent.strictMonoSatCapLight)
        } else if analysis.colorfulness < ColorSystemTokens.Accent.nearMonoColorfulnessThreshold
                  || analysis.avgSaturation < ColorSystemTokens.Accent.nearMonoAvgSaturationThreshold {
            // Near-monochrome but not strict mono: low-sat photo, off-white
            // sleeve with a small logo, dim duo-tone, etc.
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.nearMonoSatCapDark
                : ColorSystemTokens.Accent.nearMonoSatCapLight)
        } else if analysis.dominantHueConfidence
                    < ColorSystemTokens.Accent.lowConfidenceHueConfidenceThreshold {
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.lowConfidenceSatCapDark
                : ColorSystemTokens.Accent.lowConfidenceSatCapLight)
        }

        return ColorMath.color(h: h, s: s, l: l)
    }

    /// Anti-fake-color accent path. Triggered when `analysis.isNearMonochrome`
    /// is true — the cover does not carry a hue we trust. Output is a heavily
    /// desaturated tone, hue chosen from the average (if any tiny tint exists)
    /// or a fixed neutral hue otherwise. Phase 2 explicitly removed
    /// "ultra-dark protection" from this path's responsibility; that is now
    /// `isUltraDark`'s job (consumed by future Phase 3+ branches).
    fileprivate static func nearMonochromeAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        let average = ColorMath.hsl(of: analysis.averageColor)
        let hasUsableAverageHue =
            average.s >= ColorSystemTokens.NearMonochrome.avgHueUsableSaturation
            && analysis.avgSaturation >= ColorSystemTokens.NearMonochrome.avgHueUsableAvgSaturation
        let neutralHue: CGFloat
        if hasUsableAverageHue {
            neutralHue = average.h
        } else if analysis.avgHslLightness
                    < ColorSystemTokens.NearMonochrome.neutralHueChoiceLightnessThreshold {
            neutralHue = ColorSystemTokens.NearMonochrome.neutralCoolHue
        } else {
            neutralHue = ColorSystemTokens.NearMonochrome.neutralWarmHue
        }

        let strictMono =
            analysis.isMonochrome
            || analysis.colorfulness < ColorSystemTokens.NearMonochrome.strictMonoColorfulness
            || analysis.avgSaturation < ColorSystemTokens.NearMonochrome.strictMonoAvgSaturation
            || analysis.largestHighSaturationAreaShare
                < ColorSystemTokens.NearMonochrome.strictMonoHighSatAreaShare
        let saturationCeiling: CGFloat = strictMono
            ? (scheme == .dark
                ? ColorSystemTokens.NearMonochrome.strictMonoSatCapDark
                : ColorSystemTokens.NearMonochrome.strictMonoSatCapLight)
            : (scheme == .dark
                ? ColorSystemTokens.NearMonochrome.nearMonoSatCapDark
                : ColorSystemTokens.NearMonochrome.nearMonoSatCapLight)
        let saturationFloor: CGFloat = scheme == .dark
            ? ColorSystemTokens.NearMonochrome.saturationFloorDark
            : ColorSystemTokens.NearMonochrome.saturationFloorLight
        let saturation = ColorMath.clamp(
            min(average.s * ColorSystemTokens.NearMonochrome.saturationScale, saturationCeiling),
            saturationFloor,
            saturationCeiling
        )

        let lightness: CGFloat
        if scheme == .dark {
            let toneLift = ColorMath.clamp(
                (ColorSystemTokens.NearMonochrome.darkLiftPivot - analysis.avgHslLightness)
                    / ColorSystemTokens.NearMonochrome.darkLiftRange,
                0, 1
            )
            lightness = ColorMath.clamp(
                ColorSystemTokens.NearMonochrome.darkBaseLightness
                    + toneLift * ColorSystemTokens.NearMonochrome.darkLiftMax,
                ColorSystemTokens.NearMonochrome.darkBaseLightness,
                ColorSystemTokens.NearMonochrome.darkCeilingLightness
            )
        } else {
            let toneDrop = ColorMath.clamp(
                (analysis.avgHslLightness - ColorSystemTokens.NearMonochrome.lightDropPivot)
                    / ColorSystemTokens.NearMonochrome.lightDropRange,
                0, 1
            )
            lightness = ColorMath.clamp(
                ColorSystemTokens.NearMonochrome.lightBaseLightness
                    - toneDrop * ColorSystemTokens.NearMonochrome.lightDropMax,
                ColorSystemTokens.NearMonochrome.lightFloorLightness,
                ColorSystemTokens.NearMonochrome.lightCeilingLightness
            )
        }

        return ColorMath.color(h: neutralHue, s: saturation, l: lightness)
    }

    fileprivate static func ambientSurface(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.averageColor
    }

    fileprivate static func artBackgroundPrimary(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.topPalette.first ?? analysis.dominantColor
    }

    fileprivate static func artBackgroundSecondary(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.topPalette.dropFirst().first ?? analysis.dominantColor
    }

    nonisolated fileprivate static func readableTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
        if analysis.usesDarkForeground {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s + ColorSystemTokens.ReadableText.darkForegroundSaturationLift,
                    ColorSystemTokens.ReadableText.darkForegroundSatLo,
                    ColorSystemTokens.ReadableText.darkForegroundSatHi
                ),
                l: ColorSystemTokens.ReadableText.darkForegroundLightness
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.ReadableText.lightForegroundSatLo,
                    ColorSystemTokens.ReadableText.lightForegroundSatHi
                ),
                l: ColorSystemTokens.ReadableText.lightForegroundLightness
            )
        }
    }

    fileprivate static func secondaryTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor.withAlphaComponent(
            ColorSystemTokens.ReadableText.secondaryAlpha
        )
    }

    fileprivate static func windowLyricActive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        ArtworkColorExtractor.adjustedAccent(from: analysis.averageColor, isDarkMode: isDark)
    }

    fileprivate static func windowLyricInactive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        windowLyricActive(analysis: analysis, isDark: isDark)
            .withAlphaComponent(ColorSystemTokens.WindowLyric.inactiveAlpha)
    }

    fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // High colorfulness + clear hue dominance → use the dominant cover hue.
        // Otherwise fall back to the best text source colour (already mid-tone, hue-rich).
        if analysis.colorfulness >= ColorSystemTokens.FullscreenLyric.usesDominantColorfulnessMin
           && analysis.dominantHueConfidence
                >= ColorSystemTokens.FullscreenLyric.usesDominantHueConfidenceMin {
            return analysis.dominantColor
        }
        return analysis.bestTextSourceColor
    }

    fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // Inactive uses the average colour — more stable than dominantColor on
        // covers with strong but small high-saturation regions.
        analysis.averageColor
    }

    fileprivate static func coverGradientDominant(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        // Drive cover-overlay tint from dominant hue. Keep moderate saturation
        // and never push past the cover's own brightness band.
        let hsl = ColorMath.hsl(of: analysis.dominantColor)
        let s = ColorMath.clamp(
            hsl.s * ColorSystemTokens.CoverGradient.dominantSaturationScale,
            ColorSystemTokens.CoverGradient.dominantSaturationLo,
            ColorSystemTokens.CoverGradient.dominantSaturationHi
        )
        let l = ColorMath.clamp(
            hsl.l,
            ColorSystemTokens.CoverGradient.dominantLightnessLo,
            ColorSystemTokens.CoverGradient.dominantLightnessHi
        )
        return ColorMath.color(h: hsl.h, s: s, l: l)
    }

    fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
        // Stronger contrast bias than readableTextOnArtwork — used over a blurred
        // cover, not a solid surface.
        let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
        if analysis.usesDarkForeground {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.CoverGradient.darkTextSatLo,
                    ColorSystemTokens.CoverGradient.darkTextSatHi
                ),
                l: ColorSystemTokens.CoverGradient.darkTextLightness
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.CoverGradient.lightTextSatLo,
                    ColorSystemTokens.CoverGradient.lightTextSatHi
                ),
                l: ColorSystemTokens.CoverGradient.lightTextLightness
            )
        }
    }
}

/// Format a CGFloat to 3 decimal places for debug logging.
private func f3(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}

#if DEBUG
/// Debug-only bridge that exposes the Phase 4 nonisolated factory helpers
/// to `ColorSystemSelfCheck` without requiring a full palette construction.
/// Pattern mirrors `SpectrumPaletteSelfCheck` from Phase 3.
nonisolated enum SemanticPaletteSelfCheck {
    nonisolated static func readabilityProfile(
        _ analysis: ArtworkColorAnalysis
    ) -> ArtworkReadabilityProfile {
        SemanticPaletteFactory.readabilityProfile(analysis: analysis)
    }

    nonisolated static func neutralAchromaticControl() -> NSColor {
        SemanticPaletteFactory.neutralAchromaticControl()
    }

    nonisolated static func liftedAccentControl(_ color: NSColor) -> NSColor {
        SemanticPaletteFactory.liftedAccentControl(color)
    }
}
#endif
