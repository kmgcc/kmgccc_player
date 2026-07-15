//
//  FullscreenMiniPlayerForegroundStrategy.swift
//  myPlayer2
//
//  Single foreground resolver for fullscreen bottom controls.
//

import AppKit
import SwiftUI

nonisolated enum FullscreenMiniPlayerBlendStyle: Equatable, Sendable {
    case normal
    case screen

    var blendMode: BlendMode {
        switch self {
        case .normal: .normal
        case .screen: .screen
        }
    }
}

nonisolated struct FullscreenMiniPlayerForegroundProfile: Equatable {
    enum Role: String {
        case appleFixedLight
        case coverBlurLightForeground
        case coverBlurDarkForeground
        case artisticDayDarkForeground
        case artisticNightLightForeground
        case chromeLightForeground
        case chromeDarkForeground
    }

    let role: Role
    let primary: NSColor
    let secondary: NSColor
    let disabled: NSColor
    let pillTint: NSColor
    let blendStyle: FullscreenMiniPlayerBlendStyle
    let enforceBrightProgressForeground: Bool
    let spectrumUsesDarkForeground: Bool

    var iconBlendMode: BlendMode { blendStyle.blendMode }
    var useScreenBlend: Bool { blendStyle == .screen }
}

/// Unified text/icon palette for fullscreen overlay cards such as the queue
/// and Quick Panel. These surfaces intentionally use only two polarities:
/// near-white ink or one dark artwork-tinted ink, with hierarchy supplied by
/// alpha so every nested control stays visually coherent.
nonisolated struct FullscreenOverlayForegroundProfile: Equatable {
    let primary: NSColor
    let isDarkForeground: Bool

    var secondary: NSColor { primary.withAlphaComponent(0.76) }
    var tertiary: NSColor { primary.withAlphaComponent(0.58) }
    var disabled: NSColor { primary.withAlphaComponent(0.38) }
}

nonisolated enum FullscreenMiniPlayerForegroundStrategy {
    private static let appleStyleSkinID = "appleStyle"
    private static let coverGradientBlurSkinID = "fullscreen.coverGradientBlur"

    static func resolve(
        palette: SemanticPalette,
        localArtworkPolarity: ArtworkForegroundPolarity?,
        hasArtworkThemeColor: Bool,
        skinID: String,
        colorScheme: ColorScheme,
        materialStyle: LiquidGlassPillMaterialStyle,
        fullscreenArtBackgroundEnabled: Bool
    ) -> FullscreenMiniPlayerForegroundProfile {
        if skinID == appleStyleSkinID {
            return lightProfile(
                role: .appleFixedLight,
                palette: palette,
                enforceBrightProgressForeground: true
            )
        }

        if skinID == coverGradientBlurSkinID,
           isClearOrNormalMaterial(materialStyle),
           hasArtworkThemeColor {
            // Local rendered-region polarity wins when the Cover Blur
            // background map has been scored; otherwise fall back to the
            // optimized global strict gate. The colours always come from the
            // explicit candidate variants so colour, blend, spectrum and
            // progress flags stay in lockstep with the one resolved polarity -
            // never the old "dark colour + light blend" mixed profile.
            let polarity = localArtworkPolarity
                ?? (palette.analysis.usesDarkForeground
                    ? .darkOnLightBackground
                    : .lightOnDarkBackground)
            if polarity == .darkOnLightBackground {
                return darkOnArtworkProfile(
                    role: .coverBlurDarkForeground,
                    palette: palette,
                    spectrumUsesDarkForeground: true
                )
            }
            return coverBlurLightProfile(
                role: .coverBlurLightForeground,
                palette: palette,
                enforceBrightProgressForeground: true
            )
        }

        // B. Classic, Rotate Cover, KMGCCC Cassette skins
        if skinID == "coverLed" || skinID == "rotatingCover" || skinID == "kmgccc.cassette" {
            if colorScheme == .light {
                return darkOnBrightChromeProfile(
                    role: .chromeDarkForeground,
                    palette: palette
                )
            } else {
                return lightProfile(
                    role: .chromeLightForeground,
                    palette: palette,
                    enforceBrightProgressForeground: true
                )
            }
        }

        if fullscreenArtBackgroundEnabled {
            if colorScheme == .light {
                return darkOnBrightChromeProfile(
                    role: .artisticDayDarkForeground,
                    palette: palette
                )
            }
            return lightProfile(
                role: .artisticNightLightForeground,
                palette: palette,
                enforceBrightProgressForeground: true
            )
        }

        return lightProfile(
            role: .chromeLightForeground,
            palette: palette,
            enforceBrightProgressForeground: true
        )
    }

    /// The two real Cover Blur candidate profiles (dark / light), used by the
    /// local contrast engine to score the exact colours that will be rendered
    /// before `resolve` picks one. `FullscreenPlayerView` extracts each
    /// profile's `primary` and feeds them to `RenderedBackdropReadability`.
    static func artworkCandidateProfiles(
        palette: SemanticPalette
    ) -> (dark: FullscreenMiniPlayerForegroundProfile, light: FullscreenMiniPlayerForegroundProfile) {
        (
            dark: darkOnArtworkProfile(
                role: .coverBlurDarkForeground,
                palette: palette,
                spectrumUsesDarkForeground: true
            ),
            light: coverBlurLightProfile(
                role: .coverBlurLightForeground,
                palette: palette,
                enforceBrightProgressForeground: true
            )
        )
    }

    /// Queue and Quick Panel share one two-polarity rule. Cover Blur consumes
    /// the local decision for each card's real screen rectangle; Apple Style is
    /// always light; every other skin follows the app appearance.
    static func resolveOverlaySurface(
        palette: SemanticPalette,
        localArtworkPolarity: ArtworkForegroundPolarity?,
        skinID: String,
        colorScheme: ColorScheme
    ) -> FullscreenOverlayForegroundProfile {
        if skinID == coverGradientBlurSkinID {
            let polarity = localArtworkPolarity
                ?? (palette.analysis.usesDarkForeground
                    ? .darkOnLightBackground
                    : .lightOnDarkBackground)
            return overlaySurfaceProfile(palette: palette, polarity: polarity)
        }
        if skinID == appleStyleSkinID {
            return overlaySurfaceProfile(palette: palette, polarity: .lightOnDarkBackground)
        }
        return overlaySurfaceProfile(
            palette: palette,
            polarity: colorScheme == .light ? .darkOnLightBackground : .lightOnDarkBackground
        )
    }

    static func overlayCandidateProfiles(
        palette: SemanticPalette
    ) -> (dark: FullscreenOverlayForegroundProfile, light: FullscreenOverlayForegroundProfile) {
        (
            dark: overlaySurfaceProfile(palette: palette, polarity: .darkOnLightBackground),
            light: overlaySurfaceProfile(palette: palette, polarity: .lightOnDarkBackground)
        )
    }

    private static func isClearOrNormalMaterial(_ materialStyle: LiquidGlassPillMaterialStyle) -> Bool {
        switch materialStyle {
        case .clear, .normal:
            return true
        case .regular:
            return false
        }
    }

    private static func lightProfile(
        role: FullscreenMiniPlayerForegroundProfile.Role,
        palette: SemanticPalette,
        enforceBrightProgressForeground: Bool
    ) -> FullscreenMiniPlayerForegroundProfile {
        let primary = palette.miniPlayerControl.primary
        return FullscreenMiniPlayerForegroundProfile(
            role: role,
            primary: primary,
            secondary: primary.withAlphaComponent(0.78),
            disabled: primary.withAlphaComponent(0.45),
            pillTint: primary,
            blendStyle: .screen,
            enforceBrightProgressForeground: enforceBrightProgressForeground,
            spectrumUsesDarkForeground: false
        )
    }

    private static func coverBlurLightProfile(
        role: FullscreenMiniPlayerForegroundProfile.Role,
        palette: SemanticPalette,
        enforceBrightProgressForeground: Bool
    ) -> FullscreenMiniPlayerForegroundProfile {
        // Light variant comes from the Cover Gradient text candidates (its
        // target L / chroma cap differ from direct-on-artwork text), so the
        // rendered colour and the scored colour are identical.
        let primary = palette.coverGradientTextCandidates.lightOnDarkBackground
        return FullscreenMiniPlayerForegroundProfile(
            role: role,
            primary: primary,
            secondary: primary.withAlphaComponent(0.78),
            disabled: primary.withAlphaComponent(0.45),
            pillTint: primary,
            blendStyle: .screen,
            enforceBrightProgressForeground: enforceBrightProgressForeground,
            spectrumUsesDarkForeground: false
        )
    }

    private static func darkOnArtworkProfile(
        role: FullscreenMiniPlayerForegroundProfile.Role,
        palette: SemanticPalette,
        spectrumUsesDarkForeground: Bool
    ) -> FullscreenMiniPlayerForegroundProfile {
        // Dark variant comes from the readability candidates so a local
        // polarity override renders the same dark colour that was scored.
        let darkVariant = palette.readabilityCandidates.darkOnLightBackground
        let primary = darkVariant.foregroundPrimary
        return FullscreenMiniPlayerForegroundProfile(
            role: role,
            primary: primary,
            secondary: darkVariant.foregroundSecondary,
            disabled: primary.withAlphaComponent(0.45),
            pillTint: primary,
            blendStyle: .normal,
            enforceBrightProgressForeground: false,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground
        )
    }

    private static func darkOnBrightChromeProfile(
        role: FullscreenMiniPlayerForegroundProfile.Role,
        palette: SemanticPalette
    ) -> FullscreenMiniPlayerForegroundProfile {
        let primary = palette.appForeground.primary
        return FullscreenMiniPlayerForegroundProfile(
            role: role,
            primary: primary,
            secondary: palette.appForeground.secondary,
            disabled: palette.appForeground.disabled,
            pillTint: primary,
            blendStyle: .normal,
            enforceBrightProgressForeground: false,
            spectrumUsesDarkForeground: false
        )
    }

    private static func overlaySurfaceProfile(
        palette: SemanticPalette,
        polarity: ArtworkForegroundPolarity
    ) -> FullscreenOverlayForegroundProfile {
        switch polarity {
        case .darkOnLightBackground:
            return FullscreenOverlayForegroundProfile(
                primary: palette.readabilityCandidates.darkOnLightBackground.foregroundPrimary,
                isDarkForeground: true
            )
        case .lightOnDarkBackground:
            return FullscreenOverlayForegroundProfile(
                primary: NSColor.white,
                isDarkForeground: false
            )
        }
    }
}

extension FullscreenMiniPlayerForegroundProfile {
    var primaryColor: Color { ColorRenderingAdapter.makeSwiftUIColor(primary) }
    var secondaryColor: Color { ColorRenderingAdapter.makeSwiftUIColor(secondary) }
    var disabledColor: Color { ColorRenderingAdapter.makeSwiftUIColor(disabled) }
    var pillTintColor: Color { ColorRenderingAdapter.makeSwiftUIColor(pillTint) }

    var isDarkForeground: Bool {
        switch role {
        case .coverBlurDarkForeground, .artisticDayDarkForeground, .chromeDarkForeground:
            return true
        case .appleFixedLight, .coverBlurLightForeground, .artisticNightLightForeground, .chromeLightForeground:
            return false
        }
    }
}

extension FullscreenOverlayForegroundProfile {
    var primaryColor: Color { ColorRenderingAdapter.makeSwiftUIColor(primary).opacity(0.96) }
    var secondaryColor: Color { ColorRenderingAdapter.makeSwiftUIColor(secondary) }
    var tertiaryColor: Color { ColorRenderingAdapter.makeSwiftUIColor(tertiary) }
    var disabledColor: Color { ColorRenderingAdapter.makeSwiftUIColor(disabled) }

    var colorScheme: ColorScheme {
        isDarkForeground ? .light : .dark
    }
}
