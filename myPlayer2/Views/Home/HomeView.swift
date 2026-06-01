//
//  HomeView.swift
//  myPlayer2
//
//  Home page root container.
//
//  Mounted by `HomeFullWindowRoot` inside the AppKit window's full-window
//  Home host (a sibling layer between the art background and the split
//  view). Reads `HomeWindowLayoutState.shared` to decide which sections
//  align inside the center column (Hero / Playlists / Insights / footer)
//  and which extend to full window width (album / artist carousels).
//

import AppKit
import SwiftUI

struct HomeView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Environment(HomeViewModel.self) private var homeVM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var didPassStartupGate = false
    @State private var startupFallbackExpired = false
    @State private var layout = HomeWindowLayoutState.shared
    /// Stored as a plain `let` to a singleton — NEVER `@StateObject` or
    /// `@ObservedObject`. The motion state's `scrollOffsetY` publishes on
    /// every scroll frame, so observing it from this view's body would make
    /// every scroll tick invalidate Hero / Playlists / Artists / Albums /
    /// Insights and tank scroll smoothness. Only the AppKit ambient layer
    /// reacts to scroll motion; SwiftUI bodies stay decoupled.
    private let ambientMotion = HomeAmbientMotionState.shared

    var body: some View {
        Group {
            if shouldShowStartupLoading {
                startupLoadingView
            } else if libraryVM.allTracks.isEmpty {
                emptyLibraryView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            let token = FirstUseHitchDiagnostics.begin(
                "HomeView.onAppear",
                detail: "tracks=\(libraryVM.allTracks.count), state=\(libraryVM.state)"
            )
            FirstUseHitchDiagnostics.end(token)
        }
        .task(id: startupPreparationToken) {
            let token = FirstUseHitchDiagnostics.begin(
                "HomeView.task",
                detail: "tracks=\(libraryVM.allTracks.count), state=\(libraryVM.state)"
            )
            defer { FirstUseHitchDiagnostics.end(token) }

            await prepareStartupGate()
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            homeVM.refreshChangedSections(from: libraryVM)
            if !didPassStartupGate {
                Task { await prepareStartupGate() }
            }
        }
        .onChange(of: libraryVM.trackUpdateEvent) { _, event in
            guard let event else { return }
            homeVM.applyTrackUpdates(from: libraryVM, trackIDs: [event.trackID])
        }
        .onChange(of: libraryVM.artistSortKey) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.albumSortKey) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            homeVM.refreshArtistAlbumSort(from: libraryVM)
        }
        .onChange(of: libraryVM.state) { old, new in
            if new == .loaded {
                Task { await prepareStartupGate(resetEntranceAnimation: old == .loading) }
            }
        }
    }

    private var shouldShowStartupLoading: Bool {
        guard !startupFallbackExpired else { return false }
        guard !didPassStartupGate else { return false }
        guard !libraryVM.loadingPhase.isFailed else { return false }

        if libraryVM.state == .loading || libraryVM.loadingPhase.isLoading {
            return true
        }
        return !libraryVM.allTracks.isEmpty && !homeVM.hasPreparedContent
    }

    private var startupPreparationToken: String {
        let stateToken = libraryVM.state == .loading ? "loading" : "loaded"
        let phaseToken: String
        if libraryVM.loadingPhase.isLoading {
            phaseToken = "loading"
        } else if libraryVM.loadingPhase.isFailed {
            phaseToken = "failed"
        } else {
            phaseToken = "settled"
        }
        return "\(stateToken)|\(phaseToken)|tracks:\(libraryVM.allTracks.count)|refresh:\(libraryVM.refreshTrigger)"
    }

    private func prepareStartupGate(resetEntranceAnimation: Bool = false) async {
        if libraryVM.state == .loading, !didPassStartupGate {
            homeVM.invalidatePreparedContentForStartupGate()
        }

        if libraryVM.state == .loaded || libraryVM.loadingPhase.isFailed {
            if !libraryVM.allTracks.isEmpty {
                homeVM.refresh(from: libraryVM)
            }

            if libraryVM.allTracks.isEmpty || homeVM.hasPreparedContent || libraryVM.loadingPhase.isFailed {
                revealStartupContent(resetEntranceAnimation: resetEntranceAnimation)
                return
            }
        }

        guard shouldShowStartupLoading else { return }

        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled, shouldShowStartupLoading else { return }

        if libraryVM.state == .loaded, !libraryVM.allTracks.isEmpty, !homeVM.hasPreparedContent {
            homeVM.refresh(from: libraryVM)
        }

        startupFallbackExpired = true
        revealStartupContent(resetEntranceAnimation: true)
    }

    private func revealStartupContent(resetEntranceAnimation: Bool) {
        if resetEntranceAnimation {
            hasAppeared = false
        }
        didPassStartupGate = true

        guard !hasAppeared else { return }
        if reduceMotion {
            hasAppeared = true
            return
        }

        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            hasAppeared = true
        }
    }

    private var startupLoadingView: some View {
        let snap = layout.discreteSnapshot
        let leftInset = snap.hasValidLayout ? CGFloat(snap.leftInset) : 0
        let rightInset = snap.hasValidLayout ? CGFloat(snap.rightInset) : 0

        return HStack(spacing: 0) {
            Color.clear
                .frame(width: leftInset)

            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 56)
                .padding(.bottom, startupLoadingBottomInset)

            Color.clear
                .frame(width: rightInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }

    private var startupLoadingBottomInset: CGFloat {
        let miniPlayerHeight = layout.miniPlayerFrameInWindow.height
        return miniPlayerHeight > 1 ? miniPlayerHeight + 36 : 120
    }

    private var scrollContent: some View {
        // Read only the discrete layout snapshot. This intentionally avoids
        // touching `layout.geometry` so sub-pixel resize / divider-drag ticks
        // do NOT invalidate this body. The continuous geometry pipe is read
        // directly from AppKit by `HomeAmbientRootView` via a Combine
        // publisher on `HomeWindowLayoutState`.
        let snap = layout.discreteSnapshot
        let mode = HomeLayoutMode.from(snap.mode)
        let hPad = mode.horizontalPadding
        let leftInset = CGFloat(snap.leftInset)
        let rightInset = CGFloat(snap.rightInset)
        let centerLeftPad = leftInset + hPad
        let centerRightPad = rightInset + hPad
        // Layout mode follows the center column width so card sizes match
        // the visible center area, not the full window width. Mode is
        // computed from the raw geometry inside `HomeWindowLayoutState` so
        // tier thresholds (560/720/980) are evaluated against pixel-precise
        // input rather than the 16pt-bucketed centerW used for layout.
        let centerW = CGFloat(snap.contentWidthBucket) * 16
        let contentWidth = max(200, centerW - hPad * 2)

        return ZStack(alignment: .topLeading) {
            if snap.hasValidLayout {
                if !HomeDebugFlags.disableAmbient {
                    HomeAmbientShapesBackground(
                        sourceColor: themeStore.semanticPalette.ambientSurface,
                        sourceAnalysis: themeStore.semanticPalette.analysis,
                        colorScheme: colorScheme,
                        reduceMotion: reduceMotion
                    )
                }

                homeScrollView(
                    mode: mode,
                    contentWidth: contentWidth,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)
                .animation(.easeOut(duration: 0.4), value: hasAppeared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func homeScrollView(
        mode: HomeLayoutMode,
        contentWidth: CGFloat,
        centerLeftPad: CGFloat,
        centerRightPad: CGFloat
    ) -> some View {
        // Pre-resolve theme values once at this level so child sections
        // receive them as plain `let` parameters and don't need their own
        // `@EnvironmentObject ThemeStore` subscriptions. ThemeStore is an
        // `ObservableObject` with coarse `objectWillChange`, so every
        // direct subscriber re-evaluates on any of its ~15 `@Published`
        // properties. HomeView already subscribes, so reading the accent
        // here is free and lets `HomeInsightsSection` / `HomeRankRow` /
        // `HomeListeningHeatmapView` opt out of the store entirely.
        let accentColor = themeStore.accentColor
        let appFgPrimary   = Color(nsColor: themeStore.appForegroundPalette.primary)
        let appFgSecondary = Color(nsColor: themeStore.appForegroundPalette.secondary)
        let appFgTertiary  = Color(nsColor: themeStore.appForegroundPalette.tertiary)

        return ScrollView(.vertical, showsIndicators: true) {
            // `LazyVStack` defers body evaluation and layout for sections
            // that haven't intersected the scroll viewport yet — typically
            // Insights, footer, and (in narrow modes) part of the Albums
            // rail at first paint. Rails / hero / playlist grids already
            // use `.frame(maxWidth: .infinity)` internally, so under-glass
            // full-window extension and rail widths are preserved.
            LazyVStack(spacing: mode.sectionSpacing) {
                ForEach(settings.homeSectionOrder) { section in
                    homeSection(
                        section,
                        mode: mode,
                        contentWidth: contentWidth,
                        centerLeftPad: centerLeftPad,
                        centerRightPad: centerRightPad,
                        accentColor: accentColor,
                        titleColor: appFgPrimary,
                        subtitleColor: appFgSecondary,
                        tertiaryColor: appFgTertiary
                    )
                }

                footer
                    .padding(.leading, centerLeftPad)
                    .padding(.trailing, centerRightPad)

                // Bottom safe space so the Mini Player doesn't cover footer text.
                Color.clear.frame(height: 120)
            }
            // Top safe-area inset so the Hero card clears the unified
            // titlebar/toolbar at the initial scroll position. The
            // window uses `.fullSizeContentView`, so the toolbar
            // occupies the top ~52pt of the content area; 56pt gives
            // the Hero a comfortable cushion below it.
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // SwiftUI-native scroll offset observation. Replaces the previous
        // AppKit `enclosingScrollView` probe, which on Home was hosted via
        // `.background(...)` outside the inner NSScrollView and therefore
        // never resolved. The action runs on the main actor and is the
        // single feed point for `HomeAmbientMotionState.shared`, which the
        // AppKit ambient layer subscribes to via Combine.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, newValue in
            ambientMotion.setScrollOffset(newValue)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func homeSection(
        _ section: HomeSection,
        mode: HomeLayoutMode,
        contentWidth: CGFloat,
        centerLeftPad: CGFloat,
        centerRightPad: CGFloat,
        accentColor: Color,
        titleColor: Color,
        subtitleColor: Color,
        tertiaryColor: Color
    ) -> some View {
        switch section {
        case .featured:
            if !HomeDebugFlags.disableHero, let heroTrack = homeVM.heroTrack {
                VStack(alignment: .leading, spacing: 14) {
                    Text(section.title)
                        .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                        .foregroundStyle(titleColor)

                    HomeHeroView(
                        track: heroTrack,
                        containerWidth: contentWidth,
                        mode: mode,
                        onSwitchTrack: {
                            homeVM.switchHeroTrack(from: libraryVM)
                        }
                    )
                }
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
            }

        case .artists:
            if !HomeDebugFlags.disableArtists, !homeVM.artists.isEmpty {
                HomeArtistsSection(
                    artists: homeVM.artists,
                    mode: mode,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad,
                    titleColor: titleColor,
                    subtitleColor: subtitleColor
                )
            }

        case .albums:
            if !HomeDebugFlags.disableAlbums, !homeVM.albums.isEmpty {
                HomeAlbumsSection(
                    albums: homeVM.albums,
                    mode: mode,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad,
                    titleColor: titleColor,
                    subtitleColor: subtitleColor
                )
            }

        case .playlists:
            if !HomeDebugFlags.disablePlaylists, !homeVM.playlists.isEmpty {
                HomePlaylistsSection(
                    playlists: homeVM.playlists,
                    mode: mode,
                    titleColor: titleColor,
                    subtitleColor: subtitleColor
                )
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
            }

        case .listeningFootprint:
            if !HomeDebugFlags.disableInsights {
                HomeInsightsSection(
                    homeVM: homeVM,
                    mode: mode,
                    containerWidth: contentWidth,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad,
                    accentColor: accentColor,
                    titleColor: titleColor,
                    subtitleColor: subtitleColor,
                    tertiaryColor: tertiaryColor
                )
            }
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
            Text("你的音乐库是空的")
                .font(.title3)
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
            Text("导入一些音乐来开始吧")
                .font(.callout)
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.tertiary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("\u{201C}Where words fail, music speaks.\u{201D}")
                .font(.system(size: 20, weight: .ultraLight))
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
            Text("\u{8A00}\u{6240}\u{4E0D}\u{53CA}\u{5904}\u{FF0C}\u{7B19}\u{7BAB}\u{76F8}\u{7EE7}\u{3002}")
                .font(.system(.callout, weight: .ultraLight))
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.tertiary))
            Text("— Hans Christian Andersen")
                .font(.system(.caption2, weight: .ultraLight))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.quaternary))
                .padding(.top, 4)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
    }
}


// MARK: - Layout Mode

enum HomeLayoutMode: Hashable {
    case wide      // >= 980
    case medium    // 720..<980
    case compact   // 560..<720
    case narrow    // < 560

    static func mode(for width: CGFloat) -> HomeLayoutMode {
        if width >= 980 { return .wide }
        if width >= 720 { return .medium }
        if width >= 560 { return .compact }
        return .narrow
    }

    static func from(_ bucket: HomeWindowLayoutState.DiscreteSnapshot.ModeBucket) -> HomeLayoutMode {
        switch bucket {
        case .wide:    return .wide
        case .medium:  return .medium
        case .compact: return .compact
        case .narrow:  return .narrow
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .wide:    return 40
        case .medium:  return 32
        case .compact: return 24
        case .narrow:  return 18
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .wide: return 36
        case .medium: return 32
        case .compact: return 26
        case .narrow: return 22
        }
    }

    var sectionTitleFontSize: CGFloat {
        switch self {
        case .wide: return 26
        case .medium: return 24
        case .compact: return 22
        case .narrow: return 21
        }
    }

    // Per-mode pixel sizes for Home Artist / Album rail thumbnails. Each
    // bucket is ≥ cardSize × 2 (covers @2× Retina without scaling artifacts)
    // and 16-px aligned so cache keys land on a stable, finite set — total
    // of 8 derivative variants across both rails regardless of window size.
    var homeArtistRailPixelSide: Int {
        switch self {
        case .wide:    return 288   // circleSize 136 × 2 → 272, rounded to 288
        case .medium:  return 256   // circleSize 120 × 2 → 240, rounded to 256
        case .compact: return 224   // circleSize 104 × 2 → 208, rounded to 224
        case .narrow:  return 192   // circleSize  90 × 2 → 180, rounded to 192
        }
    }

    var homeAlbumRailPixelSide: Int {
        switch self {
        case .wide:    return 336   // cardSize 164 × 2 → 328, rounded to 336
        case .medium:  return 304   // cardSize 146 × 2 → 292, rounded to 304
        case .compact: return 256   // cardSize 124 × 2 → 248, rounded to 256
        case .narrow:  return 224   // cardSize 110 × 2 → 220, rounded to 224
        }
    }
}
