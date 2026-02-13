//
//  LyricsPanelView.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics Panel View
//  Right-side panel hosting AMLL lyrics with player state binding.
//  Uses LyricsWebViewStore singleton for stable WebView lifecycle.
//

import SwiftUI

/// Right-side lyrics panel with AMLL WebView.
/// The WebView is ALWAYS present (controlled via opacity, not conditionally removed).
struct LyricsPanelView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        panelContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassRect(cornerRadius: 0)
            .overlay {
                themeStore.backgroundColor.opacity(0.10)
                    .allowsHitTesting(false)
            }
            .onAppear {
                setupSeekCallback()
                reloadLyricsSurface(
                    reason: "lyrics panel appear",
                    forceWebReload: false,
                    forceLyricsReload: false
                )
            }
            .onChange(of: playerVM.currentTime, handleCurrentTimeChange)
            .onChange(of: playerVM.isPlaying) { _, newValue in
                lyricsVM.setPlaying(newValue)
            }
            .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
            .onChange(of: themeStore.colorScheme) { _, _ in
                // Theme mode switches must immediately re-push AMLL config,
                // so light/dark dedicated font weights take effect without waiting for settings edits.
                lyricsVM.refreshConfigFromSettings()
            }
            // Settings observation moved to modifier to reduce compiler complexity
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM))
    }

    @ViewBuilder
    private var panelContent: some View {
        ZStack {
            // Empty state overlay (shown when no track)
            if playerVM.currentTrack == nil {
                emptyStateView
            }

            // WebView is ALWAYS present, just hidden when no track
            // This prevents SwiftUI from destroying/recreating the representable
            AMLLWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .safeAreaPadding(.top)
                .opacity(playerVM.currentTrack != nil ? 1 : 0)
        }
    }

    // MARK: - Actions

    private func setupSeekCallback() {
        lyricsVM.onSeekRequest = { seconds in
            playerVM.seek(to: seconds)
        }
    }

    private func handleCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        lyricsVM.syncTime(newTime)

        // Detect playback restart (seeking to beginning)
        if oldTime > 1.0, newTime < 0.2 {
            reloadLyricsSurface(reason: "playback restarted", forceLyricsReload: true)
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }
        print(
            "[LyricsPanelView] Track changed: \(oldId?.uuidString.prefix(8) ?? "nil") -> \(newId?.uuidString.prefix(8) ?? "nil")"
        )
        reloadLyricsSurface(reason: "track changed", forceLyricsReload: true)
    }

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false
    ) {
        lyricsVM.ensureAMLLLoaded(
            track: playerVM.currentTrack,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceWebReload: forceWebReload,
            forceLyricsReload: forceLyricsReload
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image("EmptyLyric")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            Text("lyrics.empty_state")
                .font(.subheadline)
                .foregroundStyle(themeStore.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, 12)
    }
}

// MARK: - Preview

#Preview("Lyrics Panel") {
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let lyricsVM = LyricsViewModel()

    HStack(spacing: 0) {
        Color.gray.opacity(0.3)
            .frame(width: 400)

        LyricsPanelView()
            .environment(playerVM)
            .environment(lyricsVM)
            .environmentObject(ThemeStore.shared)
    }
    .frame(width: 800, height: 600)
    .preferredColorScheme(.dark)
}

// MARK: - Settings Observer Modifier

struct LyricsSettingsObserver: ViewModifier {
    var lyricsVM: LyricsViewModel

    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 24.0
    @AppStorage("lyricsFontNameZh") private var lyricsFontNameZh: String = "PingFang SC"
    @AppStorage("lyricsFontNameEn") private var lyricsFontNameEn: String = "SF Pro Text"
    @AppStorage("lyricsTranslationFontName") private var lyricsTranslationFontName: String =
        "SF Pro Text"
    @AppStorage("lyricsFontWeightLight") private var lyricsFontWeightLight: Int = 600
    @AppStorage("lyricsFontWeightDark") private var lyricsFontWeightDark: Int = 600
    @AppStorage("lyricsTranslationFontSize") private var lyricsTranslationFontSize: Double = 18.0
    @AppStorage("lyricsTranslationFontWeightLight") private var lyricsTranslationFontWeightLight:
        Int = 400
    @AppStorage("lyricsTranslationFontWeightDark") private var lyricsTranslationFontWeightDark:
        Int = 400
    @AppStorage("lyricsLeadInMs") private var lyricsLeadInMs: Double = 300

    func body(content: Content) -> some View {
        content
            .onChange(of: lyricsFontSize) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontNameZh) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontNameEn) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsTranslationFontName) { _, _ in lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontWeightLight) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontWeightDark) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsLeadInMs) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsTranslationFontSize) { _, _ in lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightLight) { _, _ in
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightDark) { _, _ in
                lyricsVM.refreshConfigFromSettings()
            }
    }
}
