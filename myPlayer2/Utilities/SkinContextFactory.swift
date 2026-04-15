//
//  SkinContextFactory.swift
//  myPlayer2
//
//  Shared helpers for building skin context and LED capability checks.
//

import AppKit
import SwiftUI

enum SkinContextFactory {
    static func makeContext(
        track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?,
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        ledMeterProvider: LEDMeterServiceProvider,
        accentColor: Color,
        colorScheme: ColorScheme,
        reduceMotion: Bool,
        reduceTransparency: Bool,
        windowSize: CGSize,
        contentBounds: CGRect,
        fullscreenScale: CGFloat = 1.0,
        lyricsVisible: Bool
    ) -> SkinContext {
        let trackMeta: SkinContext.TrackMetadata? = track.map {
            SkinContext.TrackMetadata(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: $0.artworkData,
                artworkImage: artworkSnapshot?.fullImage
            )
        }

        let playback = SkinContext.PlaybackState(
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            progress: duration > 0 ? currentTime / duration : 0
        )

        let theme = SkinContext.ThemeTokens(
            accentColor: accentColor,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            glassIntensity: AppSettings.shared.liquidGlassIntensity,
            backgroundBlur: AppSettings.shared.nowPlayingBackgroundBlur,
            backgroundBrightness: AppSettings.shared.nowPlayingBackgroundBrightness,
            backgroundSaturation: AppSettings.shared.nowPlayingBackgroundSaturation,
            meshAmplitude: AppSettings.shared.nowPlayingMeshAmplitude,
            meshFlowSpeed: AppSettings.shared.nowPlayingMeshFlowSpeed,
            meshSharpness: AppSettings.shared.nowPlayingMeshSharpness,
            meshSoftness: AppSettings.shared.nowPlayingMeshSoftness,
            meshColorBoost: AppSettings.shared.nowPlayingMeshColorBoost,
            meshContrast: AppSettings.shared.nowPlayingMeshContrast,
            meshBassImpact: AppSettings.shared.nowPlayingMeshBassImpact,
            artworkAccentColor: artworkSnapshot?.accentColor.map { Color(nsColor: $0) },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkRichPalette: artworkSnapshot?.richPalette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            kickToBrightnessMix: AppSettings.shared.bgKickToBrightnessMix,
            kickDisplaceAmount: AppSettings.shared.bgKickDisplaceAmount,
            kickScaleAmount: AppSettings.shared.bgKickScaleAmount
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            audio: ledMeterProvider.getOrCreate().audioMetrics,
            led: ledMeterProvider.getOrCreate().metrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: fullscreenScale,
            lyricsVisible: lyricsVisible
        )
    }

    static func isLedEnabled(skinID: String, isFullscreen: Bool) -> Bool {
        if isFullscreen {
            switch skinID {
            case "coverLed", "rotatingCover":
                return true
            case "kmgccc.cassette":
                return false
            default:
                return false
            }
        }

        switch skinID {
        case "coverLed":
            return UserDefaults.standard.string(forKey: "skin.classicLED.visualizerMode") == "led"
        case "kmgccc.cassette":
            return UserDefaults.standard.string(forKey: "skin.kmgcccCassette.visualizerMode") == "led"
        default:
            return false
        }
    }
}
