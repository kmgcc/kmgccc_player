//
//  NowPlayingHostView.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Host View
//  Hosts skins (background + artwork/overlay) while keeping lyrics outside skins.
//

import AppKit
import SwiftUI

@MainActor
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
    @State private var artworkSnapshot: ArtworkAssetSnapshot?

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
            if isLedEnabledForCurrentSkin() {
                ledMeter.start()
            } else {
                ledMeter.stop()
            }
        }
        .onAppear {
            if isLedEnabledForCurrentSkin() {
                ledMeter.start()
            }
        }
        .onDisappear {
            ledMeter.stop()
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
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
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: $0.artworkData,
                artworkImage: artworkSnapshot?.fullImage
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
            audio: ledMeter.audioMetrics,
            led: ledMeter.metrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: 1.0,
            lyricsVisible: false  // Normal mode handles lyrics separately
        )
    }
    
    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)"
    }
    
    private func loadArtworkSnapshot() async {
        guard let track = playerVM.currentTrack, let artworkData = track.artworkData, !artworkData.isEmpty
        else {
            artworkSnapshot = nil
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshot(trackID: track.id, artworkData: artworkData)
        guard !Task.isCancelled else { return }
        artworkSnapshot = snapshot
    }

    private func isLedEnabledForCurrentSkin() -> Bool {
        let skinID = settings.selectedNowPlayingSkinID
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
