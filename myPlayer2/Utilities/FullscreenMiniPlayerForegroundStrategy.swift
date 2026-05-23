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
           isClearMaterial(materialStyle),
           hasArtworkThemeColor {
            let useDarkForeground = shouldUseDarkArtworkForeground(for: palette.analysis)
            if useDarkForeground {
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

    /// Foreground polarity for controls over blurred artwork.
    ///
    /// Cover Blur must keep the foreground role and blend flags in lockstep
    /// with the shared readability profile. A previous stricter luma gate
    /// could reject borderline bright covers after `analysis.usesDarkForeground`
    /// had already selected a dark text color, producing a mixed profile:
    /// dark primary color with light-foreground screen-blend flags.
    static func shouldUseDarkArtworkForeground(for analysis: ArtworkColorAnalysis) -> Bool {
        analysis.usesDarkForeground
    }

    private static func isClearMaterial(_ materialStyle: LiquidGlassPillMaterialStyle) -> Bool {
        switch materialStyle {
        case .clear:
            return true
        case .regular, .darkGlass:
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
        let primary = palette.coverGradientText
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
        let primary = palette.readabilityProfile.foregroundPrimary
        return FullscreenMiniPlayerForegroundProfile(
            role: role,
            primary: primary,
            secondary: palette.readabilityProfile.foregroundSecondary,
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
