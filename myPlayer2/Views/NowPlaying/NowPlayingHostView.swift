//
//  NowPlayingHostView.swift
//  myPlayer2
//
//  TrueMusic - Now Playing Host View
//  Hosts skins (background + artwork/overlay) while keeping lyrics outside skins.
//

import SwiftUI

struct NowPlayingHostView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LEDMeterService.self) private var ledMeter
    @Environment(AppSettings.self) private var settings
    @Environment(SkinManager.self) private var skinManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var skinRevision = 0
    var body: some View {
        let selectedSkinID = settings.selectedNowPlayingSkinID
        let selectedSkin = skinManager.skin(for: selectedSkinID)

        GeometryReader { proxy in
            let windowSize = proxy.size
            let contentWidth = max(
                0, windowSize.width - (uiState.lyricsVisible ? uiState.lyricsWidth : 0))
            let contentHeight = max(0, windowSize.height - Constants.Layout.miniPlayerHeight - 12)
            let contentBounds = CGRect(
                origin: .zero, size: CGSize(width: contentWidth, height: contentHeight))
            let context = makeContext(windowSize: windowSize, contentBounds: contentBounds)

            ZStack(alignment: .topLeading) {
                if settings.nowPlayingArtBackgroundEnabled {
                    // BKArt is rendered at window level; keep this layer transparent.
                    Color.clear
                } else {
                    selectedSkin.makeBackground(context: context)
                }

                ZStack {
                    selectedSkin.makeArtwork(context: context)
                    if let overlay = selectedSkin.makeOverlay(context: context) {
                        overlay
                    }
                }
                .frame(width: contentBounds.width, height: contentBounds.height)
                .clipped()
            }
            .id("nowPlayingSkin_\(selectedSkinID)_\(skinRevision)")
            .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: selectedSkinID) { _, _ in
            skinRevision &+= 1
        }
    }

    private func makeContext(windowSize: CGSize, contentBounds: CGRect) -> SkinContext {
        let track = playerVM.currentTrack

        let trackMeta: SkinContext.TrackMetadata? = track.map {
            SkinContext.TrackMetadata(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                artworkData: $0.artworkData,
                artworkImage: $0.artworkData.flatMap(NSImage.init(data:))
            )
        }

        let playback = SkinContext.PlaybackState(
            isPlaying: playerVM.isPlaying,
            currentTime: playerVM.currentTime,
            duration: playerVM.duration,
            progress: playerVM.duration > 0 ? playerVM.currentTime / playerVM.duration : 0
        )

        let theme = SkinContext.ThemeTokens(
            accentColor: themeStore.accentColor,
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
            artworkAccentColor: resolveArtworkAccent(for: track),
            kickToBrightnessMix: AppSettings.shared.bgKickToBrightnessMix,
            kickDisplaceAmount: AppSettings.shared.bgKickDisplaceAmount,
            kickScaleAmount: AppSettings.shared.bgKickScaleAmount
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            audio: ledMeter.audioMetrics,
            led: ledMeter.metrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: contentBounds
        )
    }

    private func resolveArtworkAccent(for track: Track?) -> Color? {
        guard let artwork = track?.artworkData else { return nil }
        guard let accent = ArtworkColorExtractor.uiAccentColor(from: artwork) else { return nil }
        return Color(nsColor: normalizedArtworkAccent(accent))
    }

    private func normalizedArtworkAccent(_ color: NSColor) -> NSColor {
        guard colorScheme == .dark else { return color }
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: saturation,
            brightness: max(brightness, ThemeStore.darkModeMinimumThemeBrightness),
            alpha: alpha
        )
    }
}
