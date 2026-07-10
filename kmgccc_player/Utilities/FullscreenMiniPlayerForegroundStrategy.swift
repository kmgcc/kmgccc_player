//
//  FullscreenMiniPlayerForegroundStrategy.swift
//  myPlayer2
//
//  Single foreground resolver for fullscreen bottom controls.
//

import AppKit
import SwiftUI

nonisolated struct FullscreenMiniPlayerForegroundProfile {
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
    let iconBlendMode: BlendMode
    let useScreenBlend: Bool
    let enforceBrightProgressForeground: Bool
    let spectrumUsesDarkForeground: Bool
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

    /// Queue text palette, decoupled from the bottom controls' local polarity.
    /// The fullscreen queue is not inside the Mini Player sampling region, so
    /// it must not inherit a local Cover Blur decision. Cover Blur uses the
    /// optimized global gate; other skins keep their fixed behaviour.
    static func resolveQueueUsesBrightText(
        palette: SemanticPalette,
        skinID: String,
        colorScheme: ColorScheme,
        fullscreenArtBackgroundEnabled: Bool
    ) -> Bool {
        if skinID == coverGradientBlurSkinID {
            return !palette.analysis.usesDarkForeground
        }
        if skinID == appleStyleSkinID { return true }
        if skinID == "coverLed" || skinID == "rotatingCover" || skinID == "kmgccc.cassette" {
            return colorScheme == .dark
        }
        if fullscreenArtBackgroundEnabled {
            return colorScheme == .dark
        }
        return true
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
            iconBlendMode: .screen,
            useScreenBlend: true,
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
            iconBlendMode: .screen,
            useScreenBlend: true,
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
            iconBlendMode: .normal,
            useScreenBlend: false,
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
            iconBlendMode: .normal,
            useScreenBlend: false,
            enforceBrightProgressForeground: false,
            spectrumUsesDarkForeground: false
        )
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
