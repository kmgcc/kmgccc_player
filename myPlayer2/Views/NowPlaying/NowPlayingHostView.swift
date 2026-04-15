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

    var body: some View {
        let selectedSkinID = settings.selectedNowPlayingSkinID
        let selectedSkin = skinManager.skin(for: selectedSkinID)

        GeometryReader { proxy in
            let contentHeight = max(0, proxy.size.height - Constants.Layout.miniPlayerHeight - 12)
            let contentBounds = CGRect(
                origin: .zero, size: CGSize(width: mainContentWidth, height: contentHeight))
            let context = makeContext(windowSize: proxy.size, contentBounds: contentBounds)

            ZStack(alignment: .topLeading) {
                if settings.nowPlayingArtBackgroundEnabled {
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
                trackID == playerVM.currentTrack?.id
            else { return }
            Task {
                await loadArtworkSnapshot()
            }
        }
    }

    private func makeContext(windowSize: CGSize, contentBounds: CGRect) -> SkinContext {
        SkinContextFactory.makeContext(
            track: playerVM.currentTrack,
            artworkSnapshot: artworkSnapshot,
            isPlaying: playerVM.isPlaying,
            currentTime: playerVM.currentTime,
            duration: playerVM.duration,
            ledMeterProvider: ledMeterProvider,
            accentColor: themeStore.accentColor,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: 1.0,
            lyricsVisible: false  // Normal mode handles lyrics separately
        )
    }
    
    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)-px:\(preferredArtworkFullImageMaxPixel)"
    }
    
    private func loadArtworkSnapshot() async {
        guard let track = playerVM.currentTrack, let artworkData = track.artworkData, !artworkData.isEmpty
        else {
            artworkSnapshot = nil
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: track.id,
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
        SkinContextFactory.isLedEnabled(
            skinID: settings.selectedNowPlayingSkinID,
            isFullscreen: false
        )
    }
}
