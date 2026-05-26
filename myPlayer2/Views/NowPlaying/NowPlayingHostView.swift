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

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(AppSettings.self) private var settings
    @Environment(SkinManager.self) private var skinManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var skinRevision = 0
    @State private var artworkSnapshot: ArtworkAssetSnapshot?

    let mainContentWidth: CGFloat
    var artBackgroundIsUltraDark: Bool = false
    private static let externalArtworkTrackID = UUID(uuidString: "9D7D2E53-8CC0-4E65-8B19-7D9E772E6D43")!

    var body: some View {
        let selectedSkinID = settings.selectedNowPlayingSkinID
        let selectedSkin = skinManager.skin(for: selectedSkinID)

        GeometryReader { proxy in
            let contentHeight = max(0, proxy.size.height - Constants.Layout.miniPlayerHeight - 12)
            let contentBounds = CGRect(
                origin: .zero, size: CGSize(width: mainContentWidth, height: contentHeight))
            let context = makeContext(windowSize: proxy.size, contentBounds: contentBounds)

            ZStack(alignment: .topLeading) {
                if selectedSkinID == AppleStyleSkin.skinID
                    || (settings.nowPlayingArtBackgroundEnabled && selectedSkinID != AppleStyleSkin.skinID) {
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
                .frame(width: contentBounds.width, height: contentBounds.height, alignment: .center)

            }
            .id("nowPlayingSkin_\(selectedSkinID)_\(skinRevision)")
            .frame(width: mainContentWidth, height: proxy.size.height, alignment: .topLeading)
        }
        .onChange(of: selectedSkinID) { oldValue, newValue in
            skinRevision &+= 1
            if oldValue == "kmgccc.cassette", newValue != oldValue {
                Task {
                    await CassetteArtworkCache.shared.removeAll()
                }
            }
            if isLedEnabledForCurrentSkin() {
                ledMeterProvider.getOrCreate().start()
            } else {
                ledMeterProvider.releaseNowPlayingResources()
            }
        }
        .onAppear {
            if isLedEnabledForCurrentSkin() {
                ledMeterProvider.getOrCreate().start()
            }
        }
        .onDisappear {
            ledMeterProvider.releaseNowPlayingResources()
            artworkSnapshot = nil
            Task {
                await ArtworkAssetStore.shared.purgeHydratedImages()
                await CassetteArtworkCache.shared.removeAll()
            }
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            guard
                let trackID = notification.userInfo?["trackID"] as? UUID,
                trackID == playbackCoordinator.presentation.localTrack?.id
            else { return }
            Task {
                await loadArtworkSnapshot()
            }
        }
    }

    private func makeContext(windowSize: CGSize, contentBounds: CGRect) -> SkinContext {
        let presentation = playbackCoordinator.presentation

        let trackMeta: SkinContext.TrackMetadata? = presentation.hasTrack
            ? SkinContext.TrackMetadata(
                id: presentation.artworkDisplayTrackID
                    ?? presentation.displayTrackID
                    ?? Self.externalArtworkTrackID,
                title: presentation.title,
                artist: presentation.artist,
                album: presentation.album ?? "",
                duration: presentation.duration,
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: presentation.artworkData,
                artworkImage: artworkSnapshot?.fullImage
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: presentation.isPlaying,
            currentTime: presentation.currentTime,
            duration: presentation.duration,
            progress: presentation.progress
        )

        let analysis = themeStore.semanticPalette.analysis
        let primary: [NSColor]
        if !analysis.displayPalette.isEmpty {
            primary = analysis.displayPalette
        } else if !analysis.topPalette.isEmpty {
            primary = analysis.topPalette
        } else {
            primary = [
                themeStore.semanticPalette.artBackgroundPrimary,
                themeStore.semanticPalette.artBackgroundSecondary,
            ]
        }
        let chosen = Array(primary.prefix(2))
        let spectrumArtworkColors = SpectrumColorResolver.prepareSpectrumColors(chosen, analysis: analysis)
        let spectrumUsesDarkForeground = analysis.usesDarkForeground

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
            artBackgroundIsUltraDark: artBackgroundIsUltraDark,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground,
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
            fullscreenScale: 1.0,
            lyricsVisible: false,  // Normal mode handles lyrics separately
            presentationMode: .nowPlaying,
            fullscreenHostMode: .none
        )
    }
    
    private var currentArtworkTaskKey: String {
        let presentation = playbackCoordinator.presentation
        guard presentation.hasTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: presentation.artworkData)
        let identity = presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.localTrack?.id.uuidString
            ?? "unknown"
        return "\(identity)-\(checksum)-px:\(preferredArtworkFullImageMaxPixel)"
    }
    
    private func loadArtworkSnapshot() async {
        let presentation = playbackCoordinator.presentation
        guard
            let artworkData = presentation.artworkData,
            !artworkData.isEmpty
        else {
            artworkSnapshot = nil
            return
        }
        let trackID = presentation.localTrack?.id ?? Self.externalArtworkTrackID
        
        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: presentation.artworkDisplayTrackID ?? presentation.displayTrackID ?? trackID,
            artworkData: artworkData,
            fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
        )
        guard !Task.isCancelled else { return }
        artworkSnapshot = snapshot
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_400
    }

    private func isLedEnabledForCurrentSkin() -> Bool {
        let skinID = settings.selectedNowPlayingSkinID
        switch skinID {
        case "coverLed":
            return UserDefaults.standard.string(forKey: "skin.classicLED.visualizerMode") == "led"
        case AppleStyleSkin.skinID:
            return UserDefaults.standard.string(forKey: "skin.appleStyle.visualizerMode") == "led"
        case "rotatingCover":
            return UserDefaults.standard.string(forKey: "skin.rotatingCover.visualizerMode") == "led"
        case "kmgccc.cassette":
            return UserDefaults.standard.string(forKey: "skin.kmgcccCassette.visualizerMode") == "led"
        default:
            return false
        }
    }
}
