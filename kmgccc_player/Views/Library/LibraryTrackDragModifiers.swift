import AppKit
import MotionKit
import SwiftUI

/// Where a drop target paints its hover fill.
enum LibraryTrackDropHighlight {
    /// Behind the content, for rows and cards.
    case underlay
    /// Over the content, for glass surfaces that would hide an underlay.
    case overlay
}

extension View {
    func libraryTrackDrag(
        isEnabled: Bool = true,
        title: String,
        onSessionChanged: ((Bool) -> Void)? = nil,
        onSinkDropCompleted: (() -> Void)? = nil,
        previewContent: AnyView? = nil,
        previewHeight: CGFloat? = nil,
        payload: @escaping () -> LibraryTrackDragPayload
    ) -> some View {
        modifier(LibraryTrackDragModifier(
            isEnabled: isEnabled, onSessionChanged: onSessionChanged,
            onSinkDropCompleted: onSinkDropCompleted,
            previewContent: previewContent, previewHeight: previewHeight, payload: payload
        ))
    }

    func libraryTrackDropTarget(
        _ target: LibraryTrackDropTarget,
        cornerRadius: CGFloat = 7,
        highlight: LibraryTrackDropHighlight = .underlay,
        sinkAnchor: LibraryTrackDropSinkAnchor? = nil
    ) -> some View {
        modifier(LibraryTrackDropModifier(
            target: target, cornerRadius: cornerRadius, highlight: highlight,
            sinkAnchor: sinkAnchor ?? LibraryTrackDropModifier.defaultSinkAnchor(for: target)
        ))
    }

    func libraryTrackDropGroup(isExpanded: Binding<Bool>, notice: String) -> some View {
        modifier(LibraryTrackDropGroupModifier(isExpanded: isExpanded, notice: notice))
    }
}

/// Rows hand their cards to the window, which tracks the mouse itself. The
/// gesture here only claims the drag so the row's tap does not fire on release.
private struct LibraryTrackDragModifier: ViewModifier {
    let isEnabled: Bool
    let onSessionChanged: ((Bool) -> Void)?
    let onSinkDropCompleted: (() -> Void)?
    let previewContent: AnyView?
    let previewHeight: CGFloat?
    let payload: () -> LibraryTrackDragPayload
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(LibraryTrackDragSourceAnchor(makeStart: makeStart))
                .highPriorityGesture(DragGesture(minimumDistance: 4))
        } else {
            content
        }
    }

    private func makeStart() -> LibraryTrackDragStart? {
        let payload = payload()
        let tracks = libraryVM.tracks(forDragPayload: payload)
        guard !tracks.isEmpty else { return nil }
        let cardHeight = previewHeight ?? Constants.Layout.TrackRow.height
        // The row's own card describes a single-track drag exactly; a
        // selection is drawn from the dragged tracks in list order.
        let cards: [AnyView]
        if let previewContent, tracks.count == 1 {
            cards = [themed(previewContent)]
        } else {
            cards = tracks.prefix(LibraryTrackDragPileView.maxVisibleCards).map { themed(AnyView(rowCard($0))) }
        }
        let policy = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        return LibraryTrackDragStart(
            payload: payload,
            cards: cards,
            count: tracks.count,
            cardHeight: cardHeight,
            accentColor: themeStore.accentColor,
            backgroundColor: themeStore.backgroundColor,
            colorScheme: colorScheme,
            motion: LibraryTrackDragMotion(
                control: policy.animation(for: motionTokens[.control]),
                settle: policy.animation(for: motionTokens[.gestureSettle]),
                settleDuration: policy.visualCompletionDelay(for: motionTokens[.gestureSettle])
            ),
            onSessionChanged: onSessionChanged,
            onSinkDropCompleted: { _ in onSinkDropCompleted?() }
        )
    }

    private func rowCard(_ track: Track) -> some View {
        TrackRowView(
            model: Self.rowModel(track), isPlaying: false, isSelected: true,
            enableSecondaryInteractions: false, onTap: { _ in },
            rowPrimaryColor: themeStore.appForegroundPalette.primaryColor,
            rowSecondaryColor: themeStore.appForegroundPalette.secondaryColor,
            rowTertiaryColor: themeStore.appForegroundPalette.tertiaryColor,
            artworkTintMode: settings.artworkTintMode
        ) { EmptyView() }
    }

    /// The window overlay is its own hosting view and inherits nothing.
    private func themed(_ card: AnyView) -> AnyView {
        AnyView(card
            .environment(cacheServices)
            .environment(settings)
            .environmentObject(themeStore)
            .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
            .tint(themeStore.accentColor)
            .accentColor(themeStore.accentColor)
            .environment(\.colorScheme, colorScheme)
            .environment(\.motionTokens, motionTokens)
            .environment(\.motionPolicy, configuredMotionPolicy))
    }

    private static func rowModel(_ track: Track) -> TrackRowModel {
        let artworkURL = track.existingArtworkURL()
        let artworkData = artworkURL == nil ? track.artworkData : nil
        let seconds = track.duration.isFinite ? Int(max(0, track.duration)) : 0
        return TrackRowModel(
            id: track.id, title: track.title, artist: track.artist,
            lyricSnippetLine: nil, lyricSnippetStartTime: nil, lyricHighlightRanges: [],
            durationText: String(format: "%d:%02d", seconds / 60, seconds % 60),
            artworkData: artworkData, artworkFileURL: artworkURL,
            artworkIdentity: PlaylistArtworkPipeline.rowSourceIdentity(
                trackID: track.id, artworkData: artworkData, artworkFileURL: artworkURL
            ), isMissing: track.availability == .missing
        )
    }
}

private struct LibraryTrackDropGroupModifier: ViewModifier {
    @Binding var isExpanded: Bool
    let notice: String
    @Environment(UIStateViewModel.self) private var uiState
    @State private var isTargeted = false
    @State private var expansionTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(LibraryTrackDropAnchor(target: nil, setTargeted: { isTargeted = $0 }) { _ in
                uiState.showSidebarNotice(notice, style: .warning)
                return false
            })
            .onChange(of: isTargeted) { _, targeted in
                expansionTask?.cancel()
                expansionTask = nil
                guard targeted, !isExpanded else { return }
                expansionTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    isExpanded = true
                }
            }
            .onDisappear {
                expansionTask?.cancel()
                expansionTask = nil
            }
    }
}

private struct LibraryTrackDropModifier: ViewModifier {
    let target: LibraryTrackDropTarget
    let cornerRadius: CGFloat
    let highlight: LibraryTrackDropHighlight
    let sinkAnchor: LibraryTrackDropSinkAnchor
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    /// Sidebar playlist rows lead with their artwork; cards take the centre.
    static func defaultSinkAnchor(for target: LibraryTrackDropTarget) -> LibraryTrackDropSinkAnchor {
        if case .playlist = target { return .leading(inset: 21) }
        return .center
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if highlight == .underlay {
                    shape
                        .fill(themeStore.accentColor.opacity(isTargeted ? underlayOpacity : 0))
                        .allowsHitTesting(false)
                        .motionAnimation(.control, value: isTargeted)
                }
            }
            .overlay {
                if highlight == .overlay {
                    shape
                        .fill(themeStore.accentColor.opacity(isTargeted ? overlayOpacity : 0))
                        .allowsHitTesting(false)
                        .motionAnimation(.control, value: isTargeted)
                }
            }
            .background(LibraryTrackDropAnchor(
                target: target,
                sinkAnchor: sinkAnchor,
                cornerRadius: cornerRadius,
                setTargeted: { isTargeted = $0 }
            ) { payload in
                await LibraryTrackDropActions.perform(
                    payload, target: target, libraryVM: libraryVM,
                    playbackCoordinator: playbackCoordinator, uiState: uiState
                )
            })
    }

    private var underlayOpacity: Double { colorScheme == .dark ? 0.34 : 0.26 }
    private var overlayOpacity: Double { colorScheme == .dark ? 0.24 : 0.18 }
}

@MainActor
enum LibraryTrackDropActions {
    static func perform(
        _ payload: LibraryTrackDragPayload,
        target: LibraryTrackDropTarget,
        libraryVM: LibraryViewModel,
        playbackCoordinator: PlaybackCoordinator,
        uiState: UIStateViewModel
    ) async -> Bool {
        if target == .playNow {
            let tracks = libraryVM.tracks(forDragPayload: payload)
            guard playbackCoordinator.playDroppedTracks(tracks) > 0 else {
                uiState.showSidebarNotice("没有可播放的歌曲", style: .warning)
                return false
            }
            return true
        }
        guard let result = await libraryVM.applyTrackDrop(payload, to: target) else {
            uiState.showSidebarNotice("未能完成拖放操作", style: .warning)
            return false
        }
        if result.failedCount > 0 {
            uiState.showSidebarNotice("\(result.failedCount) 首歌曲未能保存", style: .warning)
            return false
        }
        if case .playlist = target {
            uiState.showSidebarNotice(result.changedCount > 0
                ? "已添加 \(result.changedCount) 首歌曲" : "歌曲已在播放列表中")
        } else {
            uiState.showSidebarNotice(result.changedCount > 0
                ? "已更新 \(result.changedCount) 首歌曲" : "歌曲归属未变")
        }
        return true
    }
}
