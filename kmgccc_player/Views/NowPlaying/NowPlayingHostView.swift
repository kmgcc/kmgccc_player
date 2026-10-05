//
//  NowPlayingHostView.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Host View
//  Hosts native author scenes and the existing preset compatibility layout.
//

import AppKit
import MotionKit
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
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var skinSession = SkinSession()
    /// Last fully decoded artwork committed to the skin layer.
    /// Track metadata may advance before artwork finishes decoding; keep this
    /// snapshot stable so skins never render placeholder/empty intermediate art.
    @State private var artworkSnapshot: ArtworkAssetSnapshot?

    let mainContentWidth: CGFloat
    var artBackgroundIsUltraDark: Bool = false
    private static let externalArtworkTrackID = UUID(uuidString: "9D7D2E53-8CC0-4E65-8B19-7D9E772E6D43")!

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    var body: some View {
        let selectedSkinID = settings.selectedNowPlayingSkinID
        let selectedSkin = skinManager.skin(for: selectedSkinID)

        GeometryReader { proxy in
            let hasScene = selectedSkin.scene != nil
            let contentHeight = hasScene ? proxy.size.height : max(0, proxy.size.height - Constants.Layout.miniPlayerHeight - 12)
            let contentBounds = CGRect(origin: .zero, size: CGSize(width: mainContentWidth, height: contentHeight))
            let context = makeContext(windowSize: proxy.size, contentBounds: contentBounds)
            if let scene = selectedSkin.scene {
                SkinSceneHost(
                    skin: selectedSkin, scene: scene, context: context, session: skinSession,
                    viewport: .init(size: proxy.size, surface: .window, fullscreenHost: .none),
                    onRestore: { settings.selectedNowPlayingSkinID = SkinRegistry.defaultSkinID }
                )
                .id(skinSession.identity(for: selectedSkinID))
            } else {
                ZStack(alignment: .topLeading) {
                    if selectedSkin.descriptor.presentation.windowBackgroundPlacement == .parent || settings.nowPlayingArtBackgroundEnabled {
                        Color.clear
                    } else {
                        selectedSkin.makeBackground(context: context)
                    }
                    ZStack {
                        selectedSkin.makeArtwork(context: context)
                        if let overlay = selectedSkin.makeOverlay(context: context) { overlay }
                    }
                    .frame(width: contentBounds.width, height: contentBounds.height, alignment: .center)
                }
                .id("nowPlayingSkin_\(skinSession.identity(for: selectedSkinID))")
                .frame(width: mainContentWidth, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onChange(of: skinManager.skin(for: selectedSkinID).scene != nil, initial: true) { _, hasScene in
            AppKitMainSplitWindowController.setSkinSceneActive(hasScene)
        }
        .onChange(of: selectedSkinID) { oldValue, newValue in
            AudioVisualizationPreferences.shared.synchronizeLegacyState(for: newValue, scope: .window)
            skinSession.activate(newValue, revision: skinManager.catalog.revision(for: newValue))
            if !isLedEnabledForCurrentSkin() {
                ledMeterProvider.releaseNowPlayingResources()
            }
            skinSession.perform {
                await CacheManager.purgePresentationMemoryCaches(
                    reason: "now-playing-skin-changed-\(oldValue)-to-\(newValue)",
                    cacheServices: cacheServices
                )
            }
        }
        .onChange(of: skinManager.catalog.revision(for: selectedSkinID)) { _, revision in
            skinSession.activate(selectedSkinID, revision: revision)
        }
        .onAppear {
            skinSession.activate(selectedSkinID, revision: skinManager.catalog.revision(for: selectedSkinID))
            AudioVisualizationPreferences.shared.synchronizeLegacyState(for: selectedSkinID, scope: .window)
            TelemetryService.shared.setWindowNowPlayingVisible(true)
        }
        .onDisappear {
            AppKitMainSplitWindowController.setSkinSceneActive(false)
            skinSession.deactivate()
            TelemetryService.shared.setWindowNowPlayingVisible(false)
            ledMeterProvider.releaseNowPlayingResources()
            artworkSnapshot = nil
            if !FullscreenWindowManager.shared.isWindowedFullscreenActive {
                skinSession.perform {
                    await CacheManager.purgePresentationMemoryCaches(
                        reason: "now-playing-disappear",
                        cacheServices: cacheServices
                    )
                }
            }
        }
        .task(id: "\(currentArtworkTaskKey)_\(skinSession.generation)") {
            await loadArtworkSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            guard
                let trackID = notification.userInfo?["trackID"] as? UUID,
                trackID == playbackCoordinator.stablePresentation.localTrack?.id
            else { return }
            skinSession.perform {
                await loadArtworkSnapshot()
            }
        }
    }

    private func makeContext(windowSize: CGSize, contentBounds: CGRect) -> SkinContext {
        let presentation = playbackCoordinator.stablePresentation
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
                artworkFileURL: presentation.source == .local
                    && presentation.artworkData?.isEmpty != false
                    ? presentation.localTrack?.existingArtworkURL()
                    : nil,
                artworkImage: artworkSnapshot?.fullImage,
                displayedArtworkID: artworkSnapshot?.trackID
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: presentation.isPlaying
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
            artworkAccentColor: artworkSnapshot?.accentColor.map {
                ColorRenderingAdapter.makeSwiftUIColor($0)
            },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            artBackgroundIsUltraDark: artBackgroundIsUltraDark,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            theme: theme,
            motionTokens: motionTokens,
            motionPolicy: motionPolicy,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: 1.0,
            lyricsVisible: false,  // Normal mode handles lyrics separately
            presentationMode: .nowPlaying,
            fullscreenHostMode: .none
        )
    }
    
    private var currentArtworkTaskKey: String {
        let presentation = playbackCoordinator.stablePresentation
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
        let presentation = playbackCoordinator.stablePresentation
        return presentation.artworkDisplayTrackID
            ?? presentation.displayTrackID
            ?? presentation.localTrack?.id
            ?? Self.externalArtworkTrackID
    }

    private var currentRenderingArtworkData: Data? {
        let presentation = playbackCoordinator.stablePresentation
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
        let presentation = playbackCoordinator.stablePresentation
        let expectedTaskKey = currentArtworkTaskKey
        let expectedGeneration = skinSession.generation
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
        guard !Task.isCancelled, skinSession.generation == expectedGeneration else { return }
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
        1_024
    }

    private var currentDisplayArtworkTrackID: UUID {
        let presentation = playbackCoordinator.stablePresentation
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
        AudioVisualizationPreferences.shared.isSkinLEDEnabled(
            for: settings.selectedNowPlayingSkinID, scope: .window
        )
    }
}
