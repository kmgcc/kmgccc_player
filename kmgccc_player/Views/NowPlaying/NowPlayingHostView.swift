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
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(AppSettings.self) private var settings
    @Environment(SkinManager.self) private var skinManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var skinRevision = 0
    /// Last fully decoded artwork committed to the skin layer.
    /// Track metadata may advance before artwork finishes decoding; keep this
    /// snapshot stable so skins never render placeholder/empty intermediate art.
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
            AudioVisualizationPreferences.shared.synchronizeLegacyState(for: newValue, scope: .window)
            skinRevision &+= 1
            if oldValue == "kmgccc.cassette", newValue != oldValue {
                Task {
                    await CassetteArtworkCache.shared.removeAll()
                }
            }
            if !isLedEnabledForCurrentSkin() {
                ledMeterProvider.releaseNowPlayingResources()
            }
        }
        .onAppear {
            AudioVisualizationPreferences.shared.synchronizeLegacyState(for: selectedSkinID, scope: .window)
            TelemetryService.shared.setWindowNowPlayingVisible(true)
        }
        .onDisappear {
            TelemetryService.shared.setWindowNowPlayingVisible(false)
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
        let displayArtworkTrackID = presentation.artworkDisplayTrackID
            ?? presentation.displayTrackID
            ?? Self.externalArtworkTrackID
        let renderingArtworkData = currentRenderingArtworkData

        let trackMeta: SkinContext.TrackMetadata? = presentation.hasTrack
            ? SkinContext.TrackMetadata(
                id: displayArtworkTrackID,
                title: presentation.title,
                artist: presentation.artist,
                album: presentation.album ?? "",
                duration: presentation.duration,
                // Source the checksum from the SAME committed snapshot as the
                // image. `presentation.artworkData` advances the instant the
                // track switches, but `artworkSnapshot` is held until the new
                // full image decodes — keying skins off the presentation hash
                // while the image is still the previous one makes them render
                // the old cover under the new key and stick there. Snapshot-
                // synced checksum keeps key and image atomic across the switch.
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: renderingArtworkData,
                artworkImage: artworkSnapshot?.fullImage,
                displayedArtworkID: artworkSnapshot?.trackID
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
            artworkAccentColor: artworkSnapshot?.accentColor.map {
                ColorRenderingAdapter.makeSwiftUIColor($0)
            },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkRichPalette: artworkSnapshot?.richPalette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            artBackgroundIsUltraDark: artBackgroundIsUltraDark,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground,
            cassetteTint: themeStore.semanticPalette.cassetteTint,
            kickToBrightnessMix: AppSettings.shared.bgKickToBrightnessMix,
            kickDisplaceAmount: AppSettings.shared.bgKickDisplaceAmount,
            kickScaleAmount: AppSettings.shared.bgKickScaleAmount
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            // Live visualizer views subscribe to LED/audio frames directly. The
            // parent skin context stays stable so routine audio frames do not
            // rebuild the whole Now Playing skin hierarchy.
            audio: .zero,
            led: LEDMeterMetrics.zero(count: AppSettings.shared.ledCount),
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
        // The local-track artwork source shortcut is only valid for local
        // playback, where the track IS the source of truth. For external playback
        // (even when a local match exists) the provider resolves the artwork into
        // `presentation.artworkData` / `artworkDisplayTrackID`; loading from the
        // local track's own source here would disagree with that resolution and
        // get rejected by the `snapshot.trackID == expectedTrackID` guard below.
        if presentation.source == .local,
           let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            return "local-\(source.sourceKey)-px:\(preferredArtworkFullImageMaxPixel)"
        }
        if ArtworkRenderingFallback.shouldUse(
            for: presentation.artworkData,
            isArtworkLoading: presentation.isArtworkLoading
        ) {
            let fallbackTrackID = currentFallbackArtworkTrackID
            let identity = presentation.artworkIdentity
                ?? presentation.externalStableKey
                ?? presentation.localTrack?.id.uuidString
                ?? presentation.displayTrackID?.uuidString
                ?? "unknown"
            return "\(identity)-\(ArtworkRenderingFallback.identity(for: fallbackTrackID))-px:\(preferredArtworkFullImageMaxPixel)"
        }
        let identity = presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.localTrack?.id.uuidString
            ?? "unknown"
        return "\(identity)-\(ArtworkDataFingerprint.sampledString(for: presentation.artworkData))-px:\(preferredArtworkFullImageMaxPixel)"
    }

    private var currentFallbackArtworkTrackID: UUID {
        let presentation = playbackCoordinator.presentation
        return presentation.artworkDisplayTrackID
            ?? presentation.displayTrackID
            ?? presentation.localTrack?.id
            ?? Self.externalArtworkTrackID
    }

    private var currentRenderingArtworkData: Data? {
        let presentation = playbackCoordinator.presentation
        if let artworkData = presentation.artworkData, !artworkData.isEmpty {
            return artworkData
        }
        let fallbackTrackID = currentFallbackArtworkTrackID
        guard artworkSnapshot?.artworkChecksum == ArtworkRenderingFallback.checksum(for: fallbackTrackID) else {
            return nil
        }
        return ArtworkRenderingFallback.data(for: fallbackTrackID)
    }
    
    private func loadArtworkSnapshot() async {
        let presentation = playbackCoordinator.presentation
        let expectedTaskKey = currentArtworkTaskKey
        guard presentation.hasTrack else {
            return
        }
        let expectedTrackID = presentation.artworkDisplayTrackID
            ?? presentation.displayTrackID
            ?? presentation.localTrack?.id
            ?? Self.externalArtworkTrackID

        let snapshot: ArtworkAssetSnapshot?
        if presentation.source == .local,
           let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            snapshot = await cacheServices.trackArtworkCache.snapshot(
                for: source,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else if let artworkData = presentation.artworkData, !artworkData.isEmpty {
            snapshot = await ArtworkAssetStore.shared.snapshot(
                trackID: expectedTrackID,
                artworkData: artworkData,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else if ArtworkRenderingFallback.shouldUse(
            for: presentation.artworkData,
            isArtworkLoading: presentation.isArtworkLoading
        ) {
            snapshot = await ArtworkAssetStore.shared.renderingFallbackSnapshot(
                trackID: expectedTrackID,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else {
            return
        }
        guard !Task.isCancelled else { return }
        guard currentArtworkTaskKey == expectedTaskKey else { return }
        guard currentDisplayArtworkTrackID == expectedTrackID else { return }
        guard let snapshot, snapshot.trackID == expectedTrackID, Self.isValidDisplayArtworkSnapshot(snapshot) else {
            if !presentation.isArtworkLoading {
                artworkSnapshot = nil
            }
            return
        }
        artworkSnapshot = snapshot
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_400
    }

    private var currentDisplayArtworkTrackID: UUID {
        let presentation = playbackCoordinator.presentation
        return presentation.artworkDisplayTrackID
            ?? presentation.displayTrackID
            ?? presentation.localTrack?.id
            ?? Self.externalArtworkTrackID
    }

    private static func isValidDisplayArtworkSnapshot(_ snapshot: ArtworkAssetSnapshot?) -> Bool {
        guard let image = snapshot?.fullImage else { return false }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return image.size.width > 1 && image.size.height > 1
        }
        return cgImage.width > 1 && cgImage.height > 1
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
