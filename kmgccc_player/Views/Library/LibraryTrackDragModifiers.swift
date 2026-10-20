import AppKit
import MotionKit
import SwiftUI

extension View {
    func libraryTrackDrag(
        isEnabled: Bool = true,
        title: String,
        onSessionChanged: ((Bool) -> Void)? = nil,
        onPlaylistDropCompleted: (() -> Void)? = nil,
        payload: @escaping () -> LibraryTrackDragPayload
    ) -> some View {
        modifier(LibraryTrackDragModifier(
            isEnabled: isEnabled, onSessionChanged: onSessionChanged,
            onPlaylistDropCompleted: onPlaylistDropCompleted, payload: payload
        ))
    }

    func libraryTrackDropTarget(_ target: LibraryTrackDropTarget, cornerRadius: CGFloat = 7) -> some View {
        modifier(LibraryTrackDropModifier(target: target, cornerRadius: cornerRadius))
    }

    func libraryTrackDropGroup(isExpanded: Binding<Bool>, notice: String) -> some View {
        modifier(LibraryTrackDropGroupModifier(isExpanded: isExpanded, notice: notice))
    }
}

private struct LibraryTrackDragModifier: ViewModifier {
    let isEnabled: Bool
    let onSessionChanged: ((Bool) -> Void)?
    let onPlaylistDropCompleted: (() -> Void)?
    let payload: () -> LibraryTrackDragPayload
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @State private var source = LibraryTrackDragSourceReference()
    @State private var session: LibraryTrackDragWindowSession?
    @State private var dragID: UUID?
    @State private var preview: AnyView?
    @State private var previewSize: CGSize = .zero
    @State private var cancelledUntilMouseUp = false
    @GestureState private var isPointerDragging = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(LibraryTrackDragSourceAnchor(reference: source))
                .highPriorityGesture(dragGesture)
                .onChange(of: isPointerDragging) { _, dragging in
                    if !dragging { cancelledUntilMouseUp = false }
                }
                .onDisappear { endSession() }
        } else {
            content
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isPointerDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard !cancelledUntilMouseUp, let view = source.view, let window = view.window else { return }
                if dragID == nil {
                    let payload = payload()
                    let tracks = libraryVM.tracks(forDragPayload: payload)
                    guard !tracks.isEmpty else { return }
                    let models = tracks.prefix(5).map(Self.rowModel)
                    previewSize = CGSize(
                        width: max(480, view.bounds.width),
                        height: Constants.Layout.TrackRow.height + CGFloat(models.count - 1) * 12 + 16
                    )
                    let preview = AnyView(LibraryTrackDragCards(models: models, count: tracks.count)
                        .environment(cacheServices)
                        .environment(settings)
                        .environmentObject(themeStore)
                        .tint(themeStore.accentColor)
                        .environment(\.colorScheme, colorScheme)
                        .environment(\.motionTokens, motionTokens)
                        .environment(\.motionPolicy, configuredMotionPolicy))
                    self.preview = preview
                    let policy = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
                    let session = window.libraryTrackDragSession
                    dragID = session.begin(
                        from: view, payload: payload, content: preview,
                        frame: CGRect(origin: .zero, size: previewSize),
                        animation: policy.animation(for: motionTokens[.gestureSettle]),
                        completionDelay: policy.visualCompletionDelay(for: motionTokens[.gestureSettle]),
                        onCancel: {
                            cancelledUntilMouseUp = true
                            if let dragID { self.session?.returnToSource(dragID) }
                        },
                        onComplete: { target in
                            dragID = nil
                            self.session = nil
                            self.preview = nil
                            onSessionChanged?(false)
                            if let target, case .playlist = target { onPlaylistDropCompleted?() }
                        }
                    )
                    self.session = session
                    if dragID != nil {
                        onSessionChanged?(true)
                    } else {
                        self.session = nil
                        self.preview = nil
                    }
                }
                guard let dragID, let preview else { return }
                session?.update(
                    dragID, from: view, content: preview,
                    frame: CGRect(origin: CGPoint(x: value.translation.width, y: value.translation.height), size: previewSize)
                )
            }
            .onEnded { _ in
                defer { cancelledUntilMouseUp = false }
                guard !cancelledUntilMouseUp, let dragID, let session else { return }
                if !session.finish(dragID) { session.returnToSource(dragID) }
            }
    }

    private func endSession() {
        // A membership refresh can recycle an NSTableView cell while the
        // window is still animating its successful drop. The window owns that
        // final phase; cell teardown must not remove the cards midway.
        if let dragID, session?.isFinishingDrop(dragID) == true { return }
        let wasActive = dragID != nil
        if let dragID { session?.end(dragID) }
        dragID = nil
        session = nil
        preview = nil
        if wasActive { onSessionChanged?(false) }
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

/// Keep the original reorder card's material and row layout for every source.
struct LibraryTrackDragCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    var glassOpacity: Double = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                    .glassEffect(.regular, in: shape)
                    .opacity(glassOpacity)
            )
            .clipShape(shape)
    }
}

private struct LibraryTrackDragCards: View {
    let models: [TrackRowModel]
    let count: Int
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(models.enumerated()), id: \.element.id) { depth, model in
                    TrackRowView(
                        model: model, isPlaying: false, isSelected: true,
                        enableSecondaryInteractions: false, onTap: { _ in },
                        rowPrimaryColor: themeStore.appForegroundPalette.primaryColor,
                        rowSecondaryColor: themeStore.appForegroundPalette.secondaryColor,
                        rowTertiaryColor: themeStore.appForegroundPalette.tertiaryColor,
                        artworkTintMode: settings.artworkTintMode
                    ) { EmptyView() }
                    .frame(height: Constants.Layout.TrackRow.height)
                    .modifier(LibraryTrackDragCardSurface(cornerRadius: Constants.Layout.TrackRow.cornerRadius))
                    .offset(x: depth == 0 ? 0 : CGFloat(depth % 2 == 0 ? 4 : -4), y: CGFloat(depth) * 12)
                    .rotationEffect(.degrees(depth == 0 ? 0 : Double(depth % 2 == 0 ? 2 : -2)))
                    .zIndex(Double(models.count - depth))
                }
            }
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(themeStore.accentColor))
                    .offset(x: 5, y: -6)
            }
        }
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
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(themeStore.accentColor.opacity(isTargeted ? 0.28 : 0))
                    .allowsHitTesting(false)
                    .motionAnimation(.control, value: isTargeted)
            }
            .background(LibraryTrackDropAnchor(target: target, setTargeted: { isTargeted = $0 }) { payload in
                await LibraryTrackDropActions.perform(
                    payload, target: target, libraryVM: libraryVM,
                    playbackCoordinator: playbackCoordinator, uiState: uiState
                )
            })
    }
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
