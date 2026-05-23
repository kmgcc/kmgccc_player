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

    /// Phase 4.5 — tinted-neutral foreground palette for ordinary App
    /// UI (sidebar text, library lists, settings labels, Home captions).
    /// Each role is derived from `globalAccent` hue at very low OKLCH
    /// chroma, crushing to achromatic on near-mono artwork. Replaces
    /// SwiftUI `.primary` / `.secondary` / `.tertiary` in non-artwork
    /// surfaces during Phase 4.5 first-batch migration.
    let appForeground: AppForegroundPalette

    /// Phase 5 — centralized lyric colour decisions. Swift owns the
    /// artwork-driven hue / lightness / near-mono policy; the Web layer
    /// only receives concrete colours and keeps rendering mechanics
    /// (opacity, blend mode, masks, shadows).
    let lyrics: LyricsColorPalette
}

enum LyricsCoverBlurBlendProfile: String, Equatable, Sendable {
    case lighter
    case darker

    var paletteScheme: ColorScheme {
        switch self {
        case .lighter:
            return .dark
        case .darker:
            return .light
        }
    }
}

struct LyricsSurfaceColorSet: Equatable, Sendable {
    let mainActive: NSColor
    let mainInactive: NSColor
    let lineTimingMainInactive: NSColor
    let subActive: NSColor
    let subInactive: NSColor
    let lineTimingSubInactive: NSColor
}

struct LyricsColorPalette: Equatable, Sendable {
    let windowActive: NSColor
    let windowInactive: NSColor
    let fullscreenBase: NSColor
    let fullscreenInactiveBase: NSColor
    let fullscreen: LyricsSurfaceColorSet
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

/// Tinted-neutral foreground palette for ordinary App UI — sidebar
/// navigation, library lists, settings labels, Home section captions,
/// and empty-state copy. NOT for use over artwork; that is the domain
/// of `ArtworkReadabilityProfile`.
///
/// Each role sits at a fixed OKLCH lightness target tuned for dark and
/// light colour schemes. Chroma is extremely low (≤0.012) and scales
/// with the current artwork's colorfulness — so the foreground reads as
/// normal grey/white/black at a glance yet carries a barely-perceptible
/// theme tint on close inspection.
///
/// Phase 4.5 invariant: when `analysis.isNearMonochrome == true`, all
/// roles have OKLCH chroma = 0 (fully achromatic). When artwork is
/// colourful, primary chroma ≤
/// `ColorSystemTokens.AppForeground.chromaCeiling`.
struct AppForegroundPalette: Equatable, Sendable {
    /// Strongest foreground — main titles, primary list text, prominent
    /// icons. OKLCH L≈0.96 dark / L≈0.14 light.
    let primary: NSColor

    /// Second-tier foreground — artist rows, secondary metadata,
    /// captions. OKLCH L≈0.78 dark / L≈0.30 light.
    let secondary: NSColor

    /// Third-tier foreground — timestamps, hints, small metadata.
    /// OKLCH L≈0.59 dark / L≈0.48 light.
    let tertiary: NSColor

    /// Fourth-tier foreground — faint hints, placeholder text.
    /// OKLCH L≈0.44 dark / L≈0.60 light.
    let quaternary: NSColor

    /// Disabled state — always achromatic regardless of artwork
    /// (chroma = 0). OKLCH L≈0.36 dark / L≈0.65 light.
    let disabled: NSColor
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
        let appFg = appForeground(
            analysis: analysis,
            globalAccent: globalAccent,
            isDark: isDark
        )
        let lyrics = lyricsPalette(
            analysis: analysis,
            scheme: scheme,
            isFullscreenUltraDark: false
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
            windowLyricActive: lyrics.windowActive,
            windowLyricInactive: lyrics.windowInactive,
            fullscreenLyricBase: lyrics.fullscreenBase,
            fullscreenLyricInactiveBase: lyrics.fullscreenInactiveBase,
            coverGradientDominant: coverGradientDominant(analysis: analysis, isDark: isDark),
            coverGradientText: coverGradientText(analysis: analysis),
            readabilityProfile: readability,
            miniPlayerControl: control,
            appForeground: appFg,
            lyrics: lyrics
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
        let hasNoTrustedHue = analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate
        let primary: NSColor
        if hasNoTrustedHue {
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

    /// Phase 4.5 — tinted-neutral foreground palette for ordinary App UI.
    ///
    /// Hue is taken from `globalAccent` in OKLCH; chroma scales linearly
    /// with artwork `colorfulness` up to `colorfulnessSaturationPoint`
    /// then caps at the per-tier limit. On `isNearMonochrome` artwork the
    /// chroma collapses to 0 so all tiers are perceptually achromatic —
    /// preventing any visible tint on grey/black/white covers.
    nonisolated fileprivate static func appForeground(
        analysis: ArtworkColorAnalysis,
        globalAccent: NSColor,
        isDark: Bool
    ) -> AppForegroundPalette {
        let T = ColorSystemTokens.AppForeground.self
        let hue = OKColor.nsColorToOKLCH(globalAccent)?.h ?? 0.0

        // Chroma scale: 0 only when no trustworthy hue survived analysis;
        // muted-but-real color stays on the chromatic ramp.
        let hasNoTrustedHue = analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate
        let chromaScale: CGFloat = hasNoTrustedHue ? 0 :
            Swift.min(analysis.colorfulness / T.colorfulnessSaturationPoint, 1.0)

        // Dark-mode hue-aware reduction. Cool/violet hues produce a visually
        // heavier or unnatural tint at the same chroma as warm hues because
        // human vision adapts to warm neutral in dark UI contexts. Apply a
        // moderate reduction factor so the temperature impression is kept but
        // the colour impression is suppressed.
        let hueChromaFactor: CGFloat
        if isDark {
            switch hue {
            case T.darkHueCoolRangeLo..<T.darkHueCoolRangeHi:
                hueChromaFactor = T.darkHueCoolScaleFactor
            case T.darkHueVioletRangeLo..<T.darkHueVioletRangeHi:
                hueChromaFactor = T.darkHueVioletScaleFactor
            default:
                hueChromaFactor = 1.0
            }
        } else {
            hueChromaFactor = 1.0
        }

        let ceiling = isDark ? T.chromaCeiling : T.lightChromaCeiling

        func make(targetL: CGFloat, chromaCap: CGFloat) -> NSColor {
            let c = Swift.min(chromaScale * chromaCap * hueChromaFactor, ceiling)
            return OKColor.okLCHToNSColor(OKColor.OKLCH(l: targetL, c: c, h: hue), alpha: 1.0)
        }

        if isDark {
            return AppForegroundPalette(
                primary:    make(targetL: T.darkPrimaryL,    chromaCap: T.primaryChromaCap),
                secondary:  make(targetL: T.darkSecondaryL,  chromaCap: T.secondaryChromaCap),
                tertiary:   make(targetL: T.darkTertiaryL,   chromaCap: T.tertiaryChromaCap),
                quaternary: make(targetL: T.darkQuaternaryL, chromaCap: T.quaternaryChromaCap),
                disabled:   make(targetL: T.darkDisabledL,   chromaCap: T.disabledChromaCap)
            )
        } else {
            return AppForegroundPalette(
                primary:    make(targetL: T.lightPrimaryL,    chromaCap: T.lightPrimaryChromaCap),
                secondary:  make(targetL: T.lightSecondaryL,  chromaCap: T.lightSecondaryChromaCap),
                tertiary:   make(targetL: T.lightTertiaryL,   chromaCap: T.lightTertiaryChromaCap),
                quaternary: make(targetL: T.lightQuaternaryL, chromaCap: T.lightQuaternaryChromaCap),
                disabled:   make(targetL: T.lightDisabledL,   chromaCap: T.disabledChromaCap)
            )
        }
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
        guard analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate else { return color }
        guard let lch = OKColor.nsColorToOKLCH(color) else { return color }
        let crushed = OKColor.OKLCH(
            l: lch.l,
            c: Swift.min(lch.c, ColorSystemTokens.ReadabilityProfile.nearMonoChromaCeiling),
            h: lch.h
        )
        return OKColor.okLCHToNSColor(crushed, alpha: color.alphaComponent)
    }

    // MARK: - Phase 5 lyric colour palette

    nonisolated static func lyricsPalette(
        analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        isFullscreenUltraDark: Bool
    ) -> LyricsColorPalette {
        let isDark = scheme == .dark
        let windowActive = windowLyricActive(analysis: analysis, isDark: isDark)
        let windowInactive = windowLyricInactive(analysis: analysis, isDark: isDark)
        let fullscreenBase = fullscreenLyricBase(analysis: analysis)
        let fullscreenInactiveBase = fullscreenLyricInactiveBase(analysis: analysis)
        let fullscreen = fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: scheme,
            highlightBaseColor: fullscreenBase,
            inactiveBaseColor: fullscreenInactiveBase,
            isUltraDark: isFullscreenUltraDark
        )
        return LyricsColorPalette(
            windowActive: windowActive,
            windowInactive: windowInactive,
            fullscreenBase: fullscreenBase,
            fullscreenInactiveBase: fullscreenInactiveBase,
            fullscreen: fullscreen
        )
    }

    nonisolated static func fullscreenLyricsColorSet(
        analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        highlightBaseColor: NSColor,
        inactiveBaseColor: NSColor,
        isUltraDark: Bool,
        usesArtisticBackground: Bool = false
    ) -> LyricsSurfaceColorSet {
        if usesArtisticBackground,
           let artistic = artisticFullscreenLyricsColorSet(
                analysis: analysis,
                highlightBaseColor: highlightBaseColor,
                inactiveBaseColor: inactiveBaseColor,
                isUltraDark: isUltraDark,
                scheme: scheme
           ) {
            return artistic
        }

        let T = ColorSystemTokens.Lyrics.self
        let highlightHSL = ColorMath.hsl(of: highlightBaseColor)
        let inactiveHSL = ColorMath.hsl(of: inactiveBaseColor)
        let isDark = scheme == .dark
        let inactiveDarkModeShift: CGFloat = isDark ? T.fullscreenInactiveDarkModeShift : 0
        let inactiveUltraDarkShift: CGFloat = isUltraDark
            ? (isDark ? T.fullscreenInactiveUltraDarkShiftDark : T.fullscreenInactiveUltraDarkShiftLight)
            : 0
        let totalInactiveShift = inactiveDarkModeShift + inactiveUltraDarkShift
        let activeLightnessShift: CGFloat = isUltraDark
            ? (isDark ? T.fullscreenActiveUltraDarkShiftDark : T.fullscreenActiveUltraDarkShiftLight)
            : (isDark ? T.fullscreenActiveDarkModeShift : 0)
        let inactiveSaturationScale: CGFloat = isUltraDark
            ? (isDark ? T.fullscreenInactiveUltraDarkSaturationScaleDark : T.fullscreenInactiveUltraDarkSaturationScaleLight)
            : (isDark ? T.fullscreenInactiveSaturationScaleDark : T.fullscreenInactiveSaturationScaleLight)
        let inactiveSaturationBias: CGFloat = isDark
            ? T.fullscreenInactiveSaturationBiasDark
            : T.fullscreenInactiveSaturationBiasLight
        let tunedSaturation = ColorMath.clamp(
            highlightHSL.s * T.fullscreenActiveSaturationScale + T.fullscreenActiveSaturationBias,
            T.fullscreenSaturationFloor,
            T.fullscreenSaturationCeiling
        )
        let baseLightness = ColorMath.clamp(
            max(
                inactiveHSL.l - T.fullscreenInactiveLightnessTrim - totalInactiveShift,
                T.fullscreenMinimumBaseLightness - totalInactiveShift * T.fullscreenMinimumBaseShiftScale
            ),
            max(T.fullscreenBaseLightnessFloor, T.fullscreenMinimumBaseLightness - totalInactiveShift),
            max(T.fullscreenBaseLightnessFallbackCeiling, T.fullscreenMaximumBaseLightness - totalInactiveShift * T.fullscreenMaximumBaseShiftScale)
        )
        let subActiveLightness = ColorMath.clamp(
            max(
                highlightHSL.l + T.fullscreenSubActiveLightnessLift - activeLightnessShift * T.fullscreenSubActiveShiftScale,
                baseLightness + T.fullscreenSubActiveMinimumGap
            ),
            max(T.fullscreenSubActiveFloor, T.fullscreenMinimumSubActiveLightness - T.fullscreenSubActiveOffset - activeLightnessShift * T.fullscreenSubActiveMinimumShiftScale),
            max(T.fullscreenSubActiveFallbackCeiling, T.fullscreenMaximumSubActiveLightness - T.fullscreenSubActiveOffset - activeLightnessShift * T.fullscreenSubActiveMaximumShiftScale)
        )
        let activeLightness = ColorMath.clamp(
            max(
                highlightHSL.l + T.fullscreenActiveLightnessLift - activeLightnessShift * T.fullscreenActiveShiftScale,
                subActiveLightness + T.fullscreenActiveMinimumGap
            ),
            max(T.fullscreenActiveFloor, T.fullscreenMinimumMainActiveLightness - activeLightnessShift * T.fullscreenActiveMinimumShiftScale),
            max(T.fullscreenActiveFallbackCeiling, T.fullscreenMaximumMainActiveLightness - activeLightnessShift * T.fullscreenActiveMaximumShiftScale)
        )
        let mainInactiveColor = ColorMath.color(
            h: inactiveHSL.h,
            s: ColorMath.clamp(inactiveHSL.s * inactiveSaturationScale + inactiveSaturationBias, 0, 1),
            l: baseLightness
        )
        let lineTimingMainInactiveColor = ColorMath.color(
            h: inactiveHSL.h,
            s: ColorMath.clamp(
                inactiveHSL.s * max(T.fullscreenLineTimingSaturationScaleFloor, inactiveSaturationScale - T.fullscreenLineTimingSaturationScaleTrim)
                    + max(T.fullscreenLineTimingSaturationBiasFloor, inactiveSaturationBias - T.fullscreenLineTimingSaturationBiasTrim),
                0,
                1
            ),
            l: baseLightness
        )
        let subActiveColor = ColorMath.color(
            h: highlightHSL.h,
            s: ColorMath.clamp(tunedSaturation * T.fullscreenSubActiveSaturationScale, 0, 1),
            l: subActiveLightness
        )
        let subInactiveColor = ColorMath.color(
            h: inactiveHSL.h,
            s: ColorMath.clamp(
                inactiveHSL.s * max(T.fullscreenSubInactiveSaturationScaleFloor, inactiveSaturationScale - T.fullscreenSubInactiveSaturationScaleTrim)
                    + max(T.fullscreenSubInactiveSaturationBiasFloor, inactiveSaturationBias - T.fullscreenSubInactiveSaturationBiasTrim),
                0,
                1
            ),
            l: baseLightness
        )
        let lineTimingSubInactiveColor = ColorMath.color(
            h: inactiveHSL.h,
            s: ColorMath.clamp(
                inactiveHSL.s * max(T.fullscreenLineTimingSubSaturationScaleFloor, inactiveSaturationScale - T.fullscreenLineTimingSubSaturationScaleTrim)
                    + max(T.fullscreenLineTimingSubSaturationBiasFloor, inactiveSaturationBias - T.fullscreenLineTimingSubSaturationBiasTrim),
                0,
                1
            ),
            l: baseLightness
        )
        let set = LyricsSurfaceColorSet(
            mainActive: ColorMath.color(
                h: highlightHSL.h,
                s: ColorMath.clamp(tunedSaturation * T.fullscreenMainActiveSaturationScale + T.fullscreenMainActiveSaturationBias, 0, 1),
                l: activeLightness
            ),
            mainInactive: mainInactiveColor,
            lineTimingMainInactive: lineTimingMainInactiveColor,
            subActive: subActiveColor,
            subInactive: subInactiveColor,
            lineTimingSubInactive: lineTimingSubInactiveColor
        )
        return neutraliseLyricsSurfaceIfNearMono(set, analysis: analysis)
    }

    /// Phase 6.1 single-seed artistic fullscreen lyrics ladder.
    ///
    /// All six roles derive from ONE seed (the active highlight). The
    /// inactive parameter carries the average-derived lyrics base used by
    /// the non-artistic fullscreen/window paths; it is only consulted as a
    /// small-highlight fallback before dominant can win.
    ///
    /// Seed selection (Phase 6.1):
    ///   1. nearMono → keep the preferred neutralised seed (no fabrication).
    ///   2. Conservative salient override: if the cover field is uniform
    ///      AND a salient highlight clears chroma + hue-gap thresholds,
    ///      use the salient as the seed. This is the "黑底 + 黄色重点 → 黄"
    ///      path; it must NOT fire on ordinary multi-colour artwork.
    ///   3. Default: area-dominant color (`analysis.dominantColor`) when
    ///      its chroma clears `lyricsDominantSeedMinChroma`.
    ///   4. Fall through to `topPalette.first` then `bestTextSourceColor`
    ///      only when the dominant is too desaturated to anchor a hue.
    ///
    /// The chromatically-trusted seed (`.c >= lyricsSeedChromaPreferred`)
    /// bypasses the post-hoc `neutraliseLyricsSurfaceIfNearMono` — that
    /// double-clamp was the v2 grey-wash bug on `.neutralFallback`.
    nonisolated private static func artisticFullscreenLyricsColorSet(
        analysis: ArtworkColorAnalysis,
        highlightBaseColor: NSColor,
        inactiveBaseColor: NSColor,
        isUltraDark: Bool,
        scheme: ColorScheme
    ) -> LyricsSurfaceColorSet? {
        guard let seed = artisticLyricsSingleSeed(
            preferred: highlightBaseColor,
            averageBaseColor: inactiveBaseColor,
            analysis: analysis
        ) else {
            return nil
        }

        func color(_ role: PerceptualToneLadder.LyricsRole) -> NSColor {
            let effectiveUltraDark = scheme == .dark && (isUltraDark || analysis.isUltraDark)
            let effectiveNearMono = analysis.isNearMonochrome
                && !analysis.hasTrustedHueCandidate
            let tone = PerceptualToneLadder.artisticLyricsTone(
                base: seed,
                role: role,
                isUltraDark: effectiveUltraDark,
                isNearMonochrome: effectiveNearMono,
                scheme: scheme
            )
            return OKColor.okLCHToNSColor(tone, alpha: 1.0)
        }

        let set = LyricsSurfaceColorSet(
            mainActive: color(.mainActive),
            mainInactive: color(.mainInactive),
            lineTimingMainInactive: color(.lineTimingMainInactive),
            subActive: color(.subActive),
            subInactive: color(.subInactive),
            lineTimingSubInactive: color(.lineTimingSubInactive)
        )
        if seed.c >= ColorSystemTokens.ToneLadder.lyricsSeedChromaPreferred {
            return set
        }
        if analysis.hasTrustedHueCandidate {
            return set
        }
        return neutraliseLyricsSurfaceIfNearMono(set, analysis: analysis)
    }

    /// Phase 6.3 seed selection. Public for SelfCheck regression coverage.
    nonisolated static func artisticLyricsSingleSeed(
        preferred: NSColor,
        averageBaseColor: NSColor? = nil,
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH? {
        let T = ColorSystemTokens.ToneLadder.self

        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            guard let preferredLCH = OKColor.nsColorToOKLCH(preferred) else { return nil }
            let fallbackChromaCap = T.lyricsChromaShoulderCeiling
                + T.lyricsChromaShoulderSoftness
            return OKColor.OKLCH(
                l: preferredLCH.l,
                c: Swift.min(preferredLCH.c, fallbackChromaCap),
                h: preferredLCH.h
            )
        }

        // Step 2 — subjective salient override. Dominant is still the default;
        // a highlight only wins when it looks like an intentional focal mark.
        if let salient = pickSalientLyricSeed(analysis: analysis) {
            return salient
        }

        // Step 3 — reuse the analyser's display palette ordering before
        // falling back to area-dominant. This preserves the existing
        // window / cover-blur "black field + tiny yellow mark reads yellow"
        // behaviour without letting ordinary multi-colour artwork jump to
        // arbitrary small regions.
        if let displayHighlight = pickDisplayHighlightLyricSeed(analysis: analysis) {
            return displayHighlight
        }
        if let averageSeed = averageDerivedLyricSeed(
            averageBaseColor: averageBaseColor,
            analysis: analysis
        ) {
            return averageSeed
        }

        // Step 4 — area-dominant first.
        if let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor),
           dominantLCH.c >= T.lyricsDominantSeedMinChroma {
            return dominantLCH
        }

        // Step 5 — fall through. Prefer the chromatically-strongest candidate
        // from {topPalette.first, bestTextSourceColor, preferred}; this is the
        // safety net for covers whose dominant bucket is genuinely grey.
        var candidates: [NSColor] = []
        if let top = analysis.topPalette.first { candidates.append(top) }
        candidates.append(analysis.bestTextSourceColor)
        candidates.append(preferred)
        var best: OKColor.OKLCH?
        for candidate in candidates {
            guard let lch = OKColor.nsColorToOKLCH(candidate) else { continue }
            if best == nil { best = lch }
            if lch.c >= T.lyricsSeedChromaPreferred { return lch }
            if let current = best, lch.c > current.c + 0.010 { best = lch }
        }
        return best
    }

    /// Phase 6.3 — subjective focus score for the salient-vs-dominant
    /// decision. Returns 0..1; salient wins when score >= threshold.
    ///
    /// This models the human read of "mostly one field, one strong accent"
    /// rather than treating total high-saturation area as the accent size.
    nonisolated private static func focusScore(
        salient: OKColor.OKLCH,
        salientAreaShare: CGFloat,
        dominant: OKColor.OKLCH,
        analysis: ArtworkColorAnalysis
    ) -> CGFloat {
        let T = ColorSystemTokens.ToneLadder.self

        guard salientAreaShare >= T.lyricsSeedFocusNoiseAreaShareFloor else {
            return 0
        }
        guard salientAreaShare <= T.lyricsSeedFocusDesignAreaShareHardCeiling else {
            return 0
        }

        let salientLab = OKColor.okLCHToOKLab(salient)
        let dominantLab = OKColor.okLCHToOKLab(dominant)
        let labDistance = sqrt(
            pow(salientLab.l - dominantLab.l, 2)
            + pow(salientLab.a - dominantLab.a, 2)
            + pow(salientLab.b - dominantLab.b, 2)
        )
        let perceptualDistance = ColorMath.clamp(labDistance / 0.34, 0, 1)
        let dC = abs(salient.c - dominant.c) / 0.20
        let dL = abs(salient.l - dominant.l) / 0.50
        let dominantHasUsableHue =
            dominant.c >= ColorSystemTokens.NearMonochromeProfile.trustedHueChromaFloor
        let dH: CGFloat
        if dominantHasUsableHue {
            dH = circularHueDistance(salient.h, dominant.h) / 0.50
        } else {
            // Achromatic dominant — hue distance is meaningless. Treat as
            // max contrast so dC + dL carry the decision.
            dH = 1.0
        }
        let visualContrast = ColorMath.clamp(
            perceptualDistance * 0.34
          + dC * T.lyricsSeedFocusChromaContrastWeight
          + dL * T.lyricsSeedFocusLightnessContrastWeight
          + dH * T.lyricsSeedFocusHueDistanceWeight,
            0, 1)

        let salience = ColorMath.clamp(
            salient.c / T.lyricsSeedFocusSalientChromaSaturationPoint, 0, 1)

        let dominantWeight = ColorMath.clamp(
            analysis.dominantHueConfidence / T.lyricsSeedFocusUniformityDominantConfidenceTarget,
            0, 1)

        let largestAccentArea = max(analysis.largestHighSaturationAreaShare, salientAreaShare)
        let competingHighSatArea = max(0, analysis.highSaturationAreaShare - largestAccentArea)
        let lowCompetingArea = 1 - ColorMath.clamp(
            competingHighSatArea / T.lyricsSeedFocusUniformityColorfulnessTarget, 0, 1)
        let fieldUniformity = ColorMath.clamp(
            dominantWeight * 0.62 + lowCompetingArea * 0.38,
            0, 1
        )

        let designFocus: CGFloat
        if salientAreaShare <= T.lyricsSeedFocusDesignAreaShareCeiling {
            designFocus = 1
        } else {
            let span = max(
                0.001,
                T.lyricsSeedFocusDesignAreaShareHardCeiling
                    - T.lyricsSeedFocusDesignAreaShareCeiling
            )
            let t = ColorMath.clamp(
                (salientAreaShare - T.lyricsSeedFocusDesignAreaShareCeiling) / span,
                0,
                1
            )
            designFocus = 1 - pow(t, 0.70)
        }

        var score =
            visualContrast * 0.42
            + salience * 0.22
            + fieldUniformity * 0.24
            + designFocus * 0.12
        score *= designFocus

        // Competing salient penalty.
        if hasCompetingSalients(analysis: analysis) {
            score -= T.lyricsSeedFocusCompetingPenalty
        }

        return ColorMath.clamp(score, 0, 1)
    }

    nonisolated private static func hasCompetingSalients(
        analysis: ArtworkColorAnalysis
    ) -> Bool {
        let lchs = analysis.salientHighlightPalette
            .compactMap { OKColor.nsColorToOKLCH($0) }
            .filter { $0.c >= 0.06 }
        guard lchs.count >= 2 else { return false }
        let primary = lchs[0]
        for other in lchs.dropFirst() {
            let hueGap = circularHueDistance(primary.h, other.h)
            if hueGap >= 0.10 && other.c >= primary.c * 0.75 {
                return true
            }
        }
        return false
    }

    /// Phase 6.3 — focus-score gate. Returns a salient seed only when its
    /// score clears `lyricsSeedFocusScoreThreshold`. Dominant remains the
    /// default; salient only wins on designed-focal covers.
    nonisolated private static func pickSalientLyricSeed(
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH? {
        let T = ColorSystemTokens.ToneLadder.self
        guard let salientColor = analysis.salientHighlightPalette.first,
              let salientLCH = OKColor.nsColorToOKLCH(salientColor) else {
            return nil
        }
        guard salientLCH.c >= T.lyricsSalientSeedMinChroma else { return nil }
        guard let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor) else {
            return nil
        }
        let salientAreaShare = analysis.salientHighlightAreaShares.first
            ?? analysis.largestHighSaturationAreaShare
        let score = focusScore(
            salient: salientLCH,
            salientAreaShare: salientAreaShare,
            dominant: dominantLCH,
            analysis: analysis
        )
        guard score >= T.lyricsSeedFocusScoreThreshold else { return nil }
        return salientLCH
    }

    /// DisplayPalette is already the quality-controlled merge of
    /// top.first -> salient -> top tail -> rich. For lyrics we only inspect
    /// entries after the dominant slot, and only on "mostly one field plus a
    /// small high-sat mark" covers.
    nonisolated private static func pickDisplayHighlightLyricSeed(
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH? {
        let T = ColorSystemTokens.ToneLadder.self
        guard analysis.hasTrustedHueCandidate else { return nil }
        guard analysis.displayPalette.count >= 2 else { return nil }
        guard !hasCompetingSalients(analysis: analysis) else { return nil }
        guard analysis.largestHighSaturationAreaShare <= T.lyricsSalientSeedMaxLargestHighSatArea else {
            return nil
        }
        guard let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor) else {
            return nil
        }

        for color in analysis.displayPalette.dropFirst() {
            guard let candidate = OKColor.nsColorToOKLCH(color) else { continue }
            guard candidate.c >= T.lyricsSalientSeedMinChroma else { continue }
            let hueGap = dominantLCH.c >= ColorSystemTokens.NearMonochromeProfile.trustedHueChromaFloor
                ? circularHueDistance(candidate.h, dominantLCH.h)
                : T.lyricsSalientSeedMinHueGapFromDominant
            let chromaGap = candidate.c - dominantLCH.c
            let lightnessGap = candidate.l - dominantLCH.l
            if hueGap >= T.lyricsSalientSeedMinHueGapFromDominant
                || chromaGap >= 0.055
                || lightnessGap >= 0.18 {
                return candidate
            }
        }
        return nil
    }

    /// Average-derived seed mirrors the successful window / Cover Blur hue
    /// source. It only participates when the dominant field itself has no
    /// useful chroma, so background stability remains dominant-owned.
    nonisolated private static func averageDerivedLyricSeed(
        averageBaseColor: NSColor?,
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH? {
        let T = ColorSystemTokens.ToneLadder.self
        guard analysis.hasTrustedHueCandidate else { return nil }
        guard analysis.largestHighSaturationAreaShare <= T.lyricsSalientSeedMaxLargestHighSatArea else {
            return nil
        }
        guard let averageBaseColor,
              let averageLCH = OKColor.nsColorToOKLCH(averageBaseColor),
              let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor) else {
            return nil
        }
        guard dominantLCH.c < T.lyricsDominantSeedMinChroma else { return nil }

        let averageHSL = ColorMath.hsl(of: averageBaseColor)
        let carriesHue = averageHSL.s >= 0.18
            || averageLCH.c >= ColorSystemTokens.NearMonochromeProfile.mutedTrustedHueChromaFloor
        return carriesHue ? averageLCH : nil
    }

    nonisolated private static func circularHueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    nonisolated static func coverBlurLyricsColorSet(
        analysis: ArtworkColorAnalysis,
        themeColor: NSColor,
        profile: LyricsCoverBlurBlendProfile
    ) -> LyricsSurfaceColorSet {
        let T = ColorSystemTokens.Lyrics.self
        let themeHSL = ColorMath.hsl(of: themeColor)
        let set: LyricsSurfaceColorSet

        switch profile {
        case .lighter:
            let inputLightness = themeHSL.l
            let isVeryDarkTheme = inputLightness < T.coverBlurLighterVeryDarkThreshold
            let isVeryBrightButStillLighter = inputLightness > T.coverBlurLighterBrightThreshold
            let activeSaturation: CGFloat
            let activeLightness: CGFloat

            if inputLightness >= T.coverBlurLighterBrightInputMin {
                activeLightness = ColorMath.clamp(
                    max(inputLightness + T.coverBlurLighterBrightActiveLift, T.coverBlurLighterBrightActiveMin),
                    T.coverBlurLighterBrightActiveMin,
                    T.coverBlurLighterBrightActiveMax
                )
                activeSaturation = ColorMath.clamp(
                    themeHSL.s * T.coverBlurLighterBrightSaturationScale + T.coverBlurLighterBrightSaturationBias,
                    T.coverBlurLighterBrightSaturationMin,
                    T.coverBlurLighterBrightSaturationMax
                )
            } else if inputLightness >= T.coverBlurLighterMidInputMin {
                activeLightness = ColorMath.clamp(
                    max(inputLightness + T.coverBlurLighterMidActiveLift, T.coverBlurLighterMidActiveMin),
                    T.coverBlurLighterMidActiveMin,
                    T.coverBlurLighterMidActiveMax
                )
                activeSaturation = ColorMath.clamp(
                    themeHSL.s * T.coverBlurLighterMidSaturationScale + T.coverBlurLighterMidSaturationBias,
                    T.coverBlurLighterMidSaturationMin,
                    T.coverBlurLighterMidSaturationMax
                )
            } else if inputLightness >= T.coverBlurLighterNeutralInputMin {
                activeLightness = ColorMath.clamp(
                    max(inputLightness + T.coverBlurLighterNeutralActiveLift, T.coverBlurLighterNeutralActiveMin),
                    T.coverBlurLighterNeutralActiveMin,
                    T.coverBlurLighterNeutralActiveMax
                )
                activeSaturation = ColorMath.clamp(
                    themeHSL.s * T.coverBlurLighterNeutralSaturationScale + T.coverBlurLighterNeutralSaturationBias,
                    T.coverBlurLighterNeutralSaturationMin,
                    T.coverBlurLighterNeutralSaturationMax
                )
            } else {
                activeLightness = ColorMath.clamp(
                    max(inputLightness + T.coverBlurLighterDarkActiveLift, T.coverBlurLighterDarkActiveMin),
                    T.coverBlurLighterDarkActiveMin,
                    T.coverBlurLighterDarkActiveMax
                )
                activeSaturation = ColorMath.clamp(
                    themeHSL.s * T.coverBlurLighterDarkSaturationScale + T.coverBlurLighterDarkSaturationBias,
                    T.coverBlurLighterDarkSaturationMin,
                    T.coverBlurLighterDarkSaturationMax
                )
            }

            let veryDarkInactiveBoost: CGFloat = isVeryDarkTheme ? T.coverBlurLighterVeryDarkInactiveBoost : 0
            let brightInactiveTrim: CGFloat = isVeryBrightButStillLighter ? T.coverBlurLighterBrightInactiveTrim : 0
            let inactiveSaturation = ColorMath.clamp(
                themeHSL.s * T.coverBlurLighterInactiveSaturationScale + T.coverBlurLighterInactiveSaturationBias,
                T.coverBlurLighterInactiveSaturationMin,
                T.coverBlurLighterInactiveSaturationMax
            )
            let subInactiveSaturation = ColorMath.clamp(
                themeHSL.s * T.coverBlurLighterSubInactiveSaturationScale + T.coverBlurLighterSubInactiveSaturationBias,
                T.coverBlurLighterSubInactiveSaturationMin,
                T.coverBlurLighterSubInactiveSaturationMax
            )
            let baseLightness = ColorMath.clamp(
                inputLightness * T.coverBlurLighterBaseInputScale
                    + T.coverBlurLighterBaseBias
                    + veryDarkInactiveBoost
                    - brightInactiveTrim,
                isVeryDarkTheme ? T.coverBlurLighterVeryDarkBaseMin : T.coverBlurLighterBaseMin,
                T.coverBlurLighterBaseMax
            )
            let lineTimingBaseLightness = ColorMath.clamp(
                baseLightness - (isVeryDarkTheme ? T.coverBlurLighterVeryDarkLineTimingTrim : T.coverBlurLighterLineTimingTrim),
                isVeryDarkTheme ? T.coverBlurLighterVeryDarkLineTimingMin : T.coverBlurLighterLineTimingMin,
                T.coverBlurLighterBaseMax
            )
            let subActiveLightness = ColorMath.clamp(
                baseLightness + (isVeryDarkTheme ? T.coverBlurLighterVeryDarkSubActiveLift : T.coverBlurLighterSubActiveLift),
                isVeryDarkTheme ? T.coverBlurLighterVeryDarkSubActiveMin : T.coverBlurLighterSubActiveMin,
                T.coverBlurLighterSubActiveMax
            )
            set = LyricsSurfaceColorSet(
                mainActive: ColorMath.color(h: themeHSL.h, s: activeSaturation, l: activeLightness),
                mainInactive: ColorMath.color(h: themeHSL.h, s: inactiveSaturation, l: baseLightness),
                lineTimingMainInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(inactiveSaturation * T.coverBlurLighterLineTimingSaturationScale, 0.02, 0.24),
                    l: lineTimingBaseLightness
                ),
                subActive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(activeSaturation * T.coverBlurLighterSubActiveSaturationScale, 0.08, 0.52),
                    l: subActiveLightness
                ),
                subInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: subInactiveSaturation,
                    l: ColorMath.clamp(baseLightness - T.coverBlurLighterSubInactiveLightnessTrim, isVeryDarkTheme ? 0.09 : 0.07, 0.18)
                ),
                lineTimingSubInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(subInactiveSaturation * T.coverBlurLighterLineTimingSubSaturationScale, 0.02, 0.12),
                    l: ColorMath.clamp(lineTimingBaseLightness - T.coverBlurLighterLineTimingSubLightnessTrim, isVeryDarkTheme ? 0.07 : 0.04, 0.14)
                )
            )
        case .darker:
            let highlightSaturation = ColorMath.clamp(
                themeHSL.s * T.coverBlurDarkerHighlightSaturationScale + T.coverBlurDarkerHighlightSaturationBias,
                T.coverBlurDarkerHighlightSaturationMin,
                T.coverBlurDarkerHighlightSaturationMax
            )
            let inactiveSaturation = ColorMath.clamp(
                themeHSL.s * T.coverBlurDarkerInactiveSaturationScale + T.coverBlurDarkerInactiveSaturationBias,
                T.coverBlurDarkerInactiveSaturationMin,
                T.coverBlurDarkerInactiveSaturationMax
            )
            let subInactiveSaturation = ColorMath.clamp(
                inactiveSaturation * T.coverBlurDarkerSubInactiveSaturationScale,
                T.coverBlurDarkerSubInactiveSaturationMin,
                T.coverBlurDarkerSubInactiveSaturationMax
            )
            let baseLightness = ColorMath.clamp(
                T.coverBlurDarkerBaseLightnessAnchor - (1 - themeHSL.l) * T.coverBlurDarkerBaseLightnessScale,
                T.coverBlurDarkerBaseLightnessMin,
                T.coverBlurDarkerBaseLightnessMax
            )
            let lineTimingBaseLightness = ColorMath.clamp(
                baseLightness - T.coverBlurDarkerLineTimingTrim,
                T.coverBlurDarkerLineTimingMin,
                T.coverBlurDarkerLineTimingMax
            )
            let subActiveLightness = ColorMath.clamp(
                baseLightness - T.coverBlurDarkerSubActiveTrim,
                T.coverBlurDarkerSubActiveMin,
                T.coverBlurDarkerSubActiveMax
            )
            let highlightLightness = ColorMath.clamp(
                themeHSL.l * T.coverBlurDarkerHighlightLightnessScale + T.coverBlurDarkerHighlightLightnessBias,
                T.coverBlurDarkerHighlightLightnessMin,
                T.coverBlurDarkerHighlightLightnessMax
            )
            set = LyricsSurfaceColorSet(
                mainActive: ColorMath.color(h: themeHSL.h, s: highlightSaturation, l: highlightLightness),
                mainInactive: ColorMath.color(h: themeHSL.h, s: inactiveSaturation, l: baseLightness),
                lineTimingMainInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(inactiveSaturation * T.coverBlurDarkerLineTimingSaturationScale, 0.06, 0.30),
                    l: lineTimingBaseLightness
                ),
                subActive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(highlightSaturation * T.coverBlurDarkerSubActiveSaturationScale, 0.04, 0.18),
                    l: subActiveLightness
                ),
                subInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: subInactiveSaturation,
                    l: ColorMath.clamp(baseLightness - T.coverBlurDarkerSubInactiveLightnessTrim, 0.74, 0.88)
                ),
                lineTimingSubInactive: ColorMath.color(
                    h: themeHSL.h,
                    s: ColorMath.clamp(subInactiveSaturation * T.coverBlurDarkerLineTimingSubSaturationScale, 0.01, 0.08),
                    l: ColorMath.clamp(lineTimingBaseLightness - T.coverBlurDarkerLineTimingSubLightnessTrim, 0.68, 0.82)
                )
            )
        }

        return neutraliseLyricsSurfaceIfNearMono(set, analysis: analysis)
    }

    nonisolated private static func neutraliseLyricsSurfaceIfNearMono(
        _ set: LyricsSurfaceColorSet,
        analysis: ArtworkColorAnalysis
    ) -> LyricsSurfaceColorSet {
        guard analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate else { return set }
        return LyricsSurfaceColorSet(
            mainActive: neutraliseLyricIfNearMono(set.mainActive, analysis: analysis),
            mainInactive: neutraliseLyricIfNearMono(set.mainInactive, analysis: analysis),
            lineTimingMainInactive: neutraliseLyricIfNearMono(set.lineTimingMainInactive, analysis: analysis),
            subActive: neutraliseLyricIfNearMono(set.subActive, analysis: analysis),
            subInactive: neutraliseLyricIfNearMono(set.subInactive, analysis: analysis),
            lineTimingSubInactive: neutraliseLyricIfNearMono(set.lineTimingSubInactive, analysis: analysis)
        )
    }

    nonisolated private static func neutraliseLyricIfNearMono(
        _ color: NSColor,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        guard analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate else { return color }
        guard let lch = OKColor.nsColorToOKLCH(color) else { return color }
        return OKColor.okLCHToNSColor(
            OKColor.OKLCH(
                l: lch.l,
                c: Swift.min(lch.c, ColorSystemTokens.Lyrics.nearMonoChromaCeiling),
                h: lch.h
            ),
            alpha: color.alphaComponent
        )
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
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
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

    nonisolated fileprivate static func windowLyricActive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        neutraliseLyricIfNearMono(
            ArtworkColorExtractor.adjustedAccent(from: analysis.averageColor, isDarkMode: isDark),
            analysis: analysis
        )
    }

    nonisolated fileprivate static func windowLyricInactive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        windowLyricActive(analysis: analysis, isDark: isDark)
            .withAlphaComponent(ColorSystemTokens.WindowLyric.inactiveAlpha)
    }

    nonisolated fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // Phase 6.3: dominant-first when the dominant centroid carries
        // a trustworthy hue; fall through to topPalette → bestTextSource
        // only when the dominant is genuinely grey.
        let T = ColorSystemTokens.ToneLadder.self
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            return neutraliseLyricIfNearMono(analysis.bestTextSourceColor, analysis: analysis)
        }
        if let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor),
           dominantLCH.c >= T.lyricsDominantSeedMinChroma {
            return analysis.dominantColor
        }
        if let top = analysis.topPalette.first,
           let topLCH = OKColor.nsColorToOKLCH(top),
           topLCH.c >= T.lyricsDominantSeedMinChroma {
            return top
        }
        return analysis.bestTextSourceColor
    }

    nonisolated fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // Inactive uses the average colour — more stable than dominantColor on
        // covers with strong but small high-saturation regions.
        neutraliseLyricIfNearMono(analysis.averageColor, analysis: analysis)
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
/// Debug-only bridge that exposes the Phase 4–4.5 nonisolated factory helpers
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

    nonisolated static func appForeground(
        analysis: ArtworkColorAnalysis,
        globalAccent: NSColor,
        isDark: Bool
    ) -> AppForegroundPalette {
        SemanticPaletteFactory.appForeground(
            analysis: analysis,
            globalAccent: globalAccent,
            isDark: isDark
        )
    }

    nonisolated static func lyricsPalette(
        analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        isFullscreenUltraDark: Bool = false
    ) -> LyricsColorPalette {
        SemanticPaletteFactory.lyricsPalette(
            analysis: analysis,
            scheme: scheme,
            isFullscreenUltraDark: isFullscreenUltraDark
        )
    }

    nonisolated static func fullscreenLyricsColorSet(
        analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        highlightBaseColor: NSColor,
        inactiveBaseColor: NSColor,
        isUltraDark: Bool = false,
        usesArtisticBackground: Bool = false
    ) -> LyricsSurfaceColorSet {
        SemanticPaletteFactory.fullscreenLyricsColorSet(
            analysis: analysis,
            scheme: scheme,
            highlightBaseColor: highlightBaseColor,
            inactiveBaseColor: inactiveBaseColor,
            isUltraDark: isUltraDark,
            usesArtisticBackground: usesArtisticBackground
        )
    }

    nonisolated static func coverBlurLyricsColorSet(
        analysis: ArtworkColorAnalysis,
        themeColor: NSColor,
        profile: LyricsCoverBlurBlendProfile
    ) -> LyricsSurfaceColorSet {
        SemanticPaletteFactory.coverBlurLyricsColorSet(
            analysis: analysis,
            themeColor: themeColor,
            profile: profile
        )
    }

    /// Phase 6.1 — surface the seed-selection decision so regression checks
    /// can verify the dominant-first + conservative-salient gate behaviour
    /// without having to build a full surface set.
    nonisolated static func artisticLyricsSingleSeed(
        preferred: NSColor,
        averageBaseColor: NSColor? = nil,
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH? {
        SemanticPaletteFactory.artisticLyricsSingleSeed(
            preferred: preferred,
            averageBaseColor: averageBaseColor,
            analysis: analysis
        )
    }
}
#endif
