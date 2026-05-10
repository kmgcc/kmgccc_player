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
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Environment(HomeViewModel.self) private var homeVM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var layout = HomeWindowLayoutState.shared
    @StateObject private var ambientMotion = HomeAmbientMotionState()

    var body: some View {
        Group {
            if libraryVM.state == .loading {
                if let snapshot = homeVM.cachedStartupSnapshot {
                    cachedStartupContent(snapshot)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if libraryVM.allTracks.isEmpty {
                emptyLibraryView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await homeVM.loadCachedStartupSnapshot()
            if !libraryVM.allTracks.isEmpty {
                homeVM.refresh(from: libraryVM)
            }
            try? await Task.sleep(for: .milliseconds(50))
            hasAppeared = true
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            homeVM.refreshChangedSections(from: libraryVM)
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
                homeVM.refresh(from: libraryVM)
                if old == .loading {
                    hasAppeared = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        hasAppeared = true
                    }
                }
            }
        }
    }

    private func cachedStartupContent(_ snapshot: HomeStartupSnapshot) -> some View {
        let snap = layout.discreteSnapshot
        let mode: HomeLayoutMode = snap.hasValidLayout
            ? HomeLayoutMode.from(snap.mode)
            : .wide
        let hPad = mode.horizontalPadding
        let leftPad = (snap.hasValidLayout ? CGFloat(snap.leftInset) : 0) + hPad
        let rightPad = (snap.hasValidLayout ? CGFloat(snap.rightInset) : 0) + hPad

        return ZStack(alignment: .topLeading) {
            Color(nsColor: HomeAmbientShapesBackground.ambientBaseColorForStaticCache(colorScheme: colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: mode.sectionSpacing) {
                    cachedHero(snapshot.hero, snapshot: snapshot, mode: mode)
                    cachedSummary(snapshot)
                    cachedStrip(title: "播放列表", items: snapshot.playlists.map { "\($0.name) · \($0.trackCount) 首" })
                    cachedStrip(title: "艺人", items: snapshot.artists.map { "\($0.name) · \($0.albumCount) 张专辑" })
                    cachedStrip(title: "专辑", items: snapshot.albums.map { "\($0.title) · \($0.artist)" })
                    cachedRanking(snapshot.preferenceRanking)
                    Color.clear.frame(height: 120)
                }
                .padding(.top, 56)
                .padding(.bottom, 24)
                .padding(.leading, leftPad)
                .padding(.trailing, rightPad)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: hasAppeared)
    }

    private func cachedHero(
        _ hero: HomeStartupSnapshot.TrackSummary?,
        snapshot: HomeStartupSnapshot,
        mode: HomeLayoutMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Home")
                .font(.system(size: mode == .wide ? 34 : 28, weight: .semibold))
            if let hero {
                Text(hero.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text([hero.artist, hero.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("正在载入音乐库，先显示上次主页快照 · \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeUnifiedGlassCard(cornerRadius: 18, colorScheme: colorScheme, isFloating: true)
    }

    private func cachedSummary(_ snapshot: HomeStartupSnapshot) -> some View {
        HStack(spacing: 14) {
            cachedStat(label: "总歌曲", value: "\(snapshot.totalTrackCount)", unit: "首")
            cachedStat(label: "本周播放", value: cachedFormattedNumber(snapshot.weeklyPlayCount), unit: "次")
            let duration = cachedFormattedDurationParts(snapshot.weeklyListeningSeconds)
            cachedStat(label: "本周时长", value: duration.value, unit: duration.unit)
            cachedStat(
                label: "本周常听",
                value: snapshot.weeklyFavoriteArtistName ?? "—",
                unit: snapshot.weeklyFavoriteArtistPlayCount > 0 ? "\(snapshot.weeklyFavoriteArtistPlayCount) 次" : ""
            )
        }
    }

    private func cachedStat(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .homeUnifiedGlassCard(cornerRadius: 16, colorScheme: colorScheme, isFloating: true)
    }

    private func cachedStrip(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(items.prefix(10).enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .frame(width: 154, height: 76, alignment: .topLeading)
                            .padding(14)
                            .homeUnifiedGlassCard(cornerRadius: 16, colorScheme: colorScheme, isFloating: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cachedRanking(_ items: [HomeStartupSnapshot.RankSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("爱听排行")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(item.playCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if index < min(items.count, 8) - 1 {
                        Divider()
                    }
                }
            }
            .padding(14)
            .homeUnifiedGlassCard(cornerRadius: 18, colorScheme: colorScheme, isFloating: true)
        }
    }

    private func cachedFormattedNumber(_ n: Int) -> String {
        n.formatted(.number)
    }

    private func cachedFormattedDurationParts(_ seconds: Double) -> (value: String, unit: String) {
        if seconds < 3600 {
            return (String(max(0, Int((seconds / 60).rounded()))), "分钟")
        }
        return (String(Int((seconds / 3600).rounded())), "小时")
    }

    private var scrollContent: some View {
        // Read only the discrete layout snapshot. This intentionally avoids
        // touching `layout.geometry` so sub-pixel resize / divider-drag ticks
        // do NOT invalidate this body. The continuous geometry pipe is read
        // directly from AppKit by `HomeAmbientRootView` via a Combine
        // publisher on `HomeWindowLayoutState`.
        let snap = layout.discreteSnapshot
        guard snap.hasValidLayout else {
            return AnyView(
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        let centerW = CGFloat(snap.contentWidthBucket) * 16
        // Layout mode follows the center column width so card sizes match
        // the visible center area, not the full window width. Mode is
        // computed from the raw geometry inside `HomeWindowLayoutState` so
        // tier thresholds (560/720/980) are evaluated against pixel-precise
        // input rather than the 16pt-bucketed centerW used for layout.
        let mode = HomeLayoutMode.from(snap.mode)
        let hPad = mode.horizontalPadding
        let leftInset = CGFloat(snap.leftInset)
        let rightInset = CGFloat(snap.rightInset)
        let centerLeftPad = leftInset + hPad
        let centerRightPad = rightInset + hPad
        let contentWidth = max(200, centerW - hPad * 2)

        return AnyView(
            ZStack(alignment: .topLeading) {
                HomeAmbientShapesBackground(
                    motion: ambientMotion,
                    sourceColor: themeStore.semanticPalette.ambientSurface,
                    sourceAnalysis: themeStore.semanticPalette.analysis,
                    colorScheme: colorScheme,
                    reduceMotion: reduceMotion
                )

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }

    private func homeScrollView(
        mode: HomeLayoutMode,
        contentWidth: CGFloat,
        centerLeftPad: CGFloat,
        centerRightPad: CGFloat
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: mode.sectionSpacing) {
                if let heroTrack = homeVM.heroTrack {
                    HomeHeroView(
                        track: heroTrack,
                        containerWidth: contentWidth,
                        mode: mode,
                        onSwitchTrack: {
                            homeVM.switchHeroTrack(from: libraryVM)
                        }
                    )
                        .padding(.leading, centerLeftPad)
                        .padding(.trailing, centerRightPad)
                }

                if !homeVM.playlists.isEmpty {
                    HomePlaylistsSection(playlists: homeVM.playlists, mode: mode)
                        .padding(.leading, centerLeftPad)
                        .padding(.trailing, centerRightPad)
                }

                if !homeVM.artists.isEmpty {
                    HomeArtistsSection(
                        artists: homeVM.artists,
                        mode: mode,
                        centerLeftPad: centerLeftPad,
                        centerRightPad: centerRightPad
                    )
                }

                if !homeVM.albums.isEmpty {
                    HomeAlbumsSection(
                        albums: homeVM.albums,
                        mode: mode,
                        centerLeftPad: centerLeftPad,
                        centerRightPad: centerRightPad
                    )
                }

                HomeInsightsSection(
                    homeVM: homeVM,
                    mode: mode,
                    containerWidth: contentWidth,
                    centerLeftPad: centerLeftPad,
                    centerRightPad: centerRightPad
                )

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
        .background(HomeVerticalScrollOffsetObserver(motion: ambientMotion))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("你的音乐库是空的")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("导入一些音乐来开始吧")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("\u{201C}Where words fail, music speaks.\u{201D}")
                .font(.system(size: 20, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("\u{8A00}\u{6240}\u{4E0D}\u{53CA}\u{5904}\u{FF0C}\u{7B19}\u{7BAB}\u{76F8}\u{7EE7}\u{3002}")
                .font(.system(.callout, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("— Hans Christian Andersen")
                .font(.system(.caption2, weight: .ultraLight))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.quaternary)
                .padding(.top, 4)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
    }
}

private struct HomeVerticalScrollOffsetObserver: NSViewRepresentable {
    let motion: HomeAmbientMotionState

    func makeNSView(context _: Context) -> HomeVerticalScrollOffsetProbeView {
        let view = HomeVerticalScrollOffsetProbeView()
        view.motion = motion
        return view
    }

    func updateNSView(_ nsView: HomeVerticalScrollOffsetProbeView, context _: Context) {
        nsView.motion = motion
        nsView.resolveScrollViewSoon()
    }
}

private final class HomeVerticalScrollOffsetProbeView: NSView {
    weak var motion: HomeAmbientMotionState?

    private weak var observedScrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveScrollViewSoon()
    }

    func resolveScrollViewSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.resolveScrollView()
        }
    }

    private func resolveScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        guard observedScrollView !== scrollView else {
            publishOffset(from: scrollView)
            return
        }

        NotificationCenter.default.removeObserver(self)

        observedScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(observedBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        publishOffset(from: scrollView)
    }

    @objc private func observedBoundsDidChange(_ notification: Notification) {
        guard let scrollView = observedScrollView else { return }
        publishOffset(from: scrollView)
    }

    private func publishOffset(from scrollView: NSScrollView) {
        let offset = max(0, scrollView.contentView.bounds.origin.y)
        motion?.setScrollOffset(offset)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        case .wide: return 22
        case .medium: return 20
        case .compact: return 18
        case .narrow: return 17
        }
    }
}
