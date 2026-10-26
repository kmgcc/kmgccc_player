import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Searches with the shared library service. Selection stays in the editor until Save.
/// The caller places it in its own "动态封面" section.
struct MotionArtworkSearchSection: View {
    @Environment(LibraryCacheServices.self) private var cacheServices
    @EnvironmentObject private var themeStore: ThemeStore

    let query: MusicEnrichmentQuery
    @Binding var selection: MusicEnrichmentResult?
    @Binding var importedVideo: MotionVideoImportSelection?
    @Binding var isValidatingImport: Bool
    /// Where a new choice applies; nil when the editor itself is the album's.
    var scope: Binding<MotionArtworkScope>?
    /// The song has its own artwork; offers to follow the album again on Save.
    var hasOwnChoice = false
    var followAlbum: Binding<Bool>?
    var titlePrompt: String = "歌曲名称"
    @State private var showingVideoPicker = false
    @State private var importValidationTask: Task<Void, Never>?

    @State private var searchTitle: String
    @State private var searchArtist: String
    @State private var candidates: [MusicEnrichmentResult] = []
    @State private var hoveredCandidate: Int?
    @State private var isSearching = false
    @State private var statusMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(
        query: MusicEnrichmentQuery, selection: Binding<MusicEnrichmentResult?>,
        importedVideo: Binding<MotionVideoImportSelection?>, isValidatingImport: Binding<Bool>,
        scope: Binding<MotionArtworkScope>? = nil, hasOwnChoice: Bool = false, followAlbum: Binding<Bool>? = nil,
        titlePrompt: String = "歌曲名称"
    ) {
        self.query = query
        _selection = selection
        _importedVideo = importedVideo
        _isValidatingImport = isValidatingImport
        self.scope = scope
        self.hasOwnChoice = hasOwnChoice
        self.followAlbum = followAlbum
        self.titlePrompt = titlePrompt
        _searchTitle = State(initialValue: query.title)
        _searchArtist = State(initialValue: query.artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scope {
                CapsulePicker(
                    label: "应用于",
                    options: MotionArtworkScope.allCases,
                    selection: scope,
                    displayName: { $0 == .album ? "整张专辑" : "仅此歌曲" },
                    info: "整张专辑：专辑里没有单独设置的歌曲都会使用。"
                )
            }
            if hasOwnChoice, let followAlbum {
                HStack(spacing: 8) {
                    Text(followAlbum.wrappedValue ? "保存后改为跟随专辑" : "这首歌使用单独设置的动态封面")
                        .settingsDescriptionStyle()
                    Spacer(minLength: 0)
                    Button(followAlbum.wrappedValue ? "保留单独设置" : "跟随专辑") {
                        followAlbum.wrappedValue.toggle()
                    }
                    .buttonStyle(AppPanelButtonStyle())
                }
            }

            HStack(spacing: 8) {
                TextField(titlePrompt, text: $searchTitle)
                TextField("艺人", text: $searchArtist)
                Button("搜索") { search() }
                    .buttonStyle(AppPanelButtonStyle())
                    .disabled(isSearching || searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .textFieldStyle(.roundedBorder)

            if let selection {
                HStack(spacing: 8) {
                    Label(selectedTitle(selection), systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    Spacer(minLength: 0)
                    Button("取消选择") { self.selection = nil }
                        .buttonStyle(AppPanelButtonStyle())
                }
                .font(.caption)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            }

            ForEach(candidates.indices, id: \.self) { index in
                candidateRow(candidates[index], index: index)
            }

            Divider()
            importRow
        }
        .fileImporter(
            isPresented: $showingVideoPicker,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            validateImport(url)
        }
        .onDisappear {
            importValidationTask?.cancel()
            importValidationTask = nil
            isValidatingImport = false
            searchTask?.cancel()
            searchTask = nil
            isSearching = false
            hoveredCandidate = nil
        }
    }

    /// The secondary path: the user's own video.
    @ViewBuilder
    private var importRow: some View {
        HStack(spacing: 8) {
            Text("手动导入动态封面")
                .settingsRowLabelStyle()
                .settingsInfoHint("时长接近歌曲的视频按 MV 随歌曲同步播放。")
            Spacer(minLength: 0)
            Button("导入视频") { showingVideoPicker = true }
                .buttonStyle(AppPanelButtonStyle())
                .disabled(isValidatingImport)
        }
        if isValidatingImport {
            ProgressView("正在检查视频…").controlSize(.small)
        }
        if let importedVideo {
            HStack {
                Label(importedVideo.url.lastPathComponent, systemImage: "video.fill")
                    .lineLimit(1)
                Spacer()
                Button("取消选择") { self.importedVideo = nil }
                    .buttonStyle(AppPanelButtonStyle())
            }
            .font(.caption)
            .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
        }
    }

    private func candidateRow(_ candidate: MusicEnrichmentResult, index: Int) -> some View {
        Button {
            importValidationTask?.cancel()
            isValidatingImport = false
            importedVideo = nil
            selection = candidate
        } label: {
            HStack(spacing: 10) {
                MotionCandidatePreview(
                    thumbnail: thumbnailURL(candidate),
                    video: previewURL(candidate),
                    plays: hoveredCandidate == index || selection == candidate
                )
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTitle(candidate))
                        .font(.subheadline)
                        .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    if let artist = candidate.attributes?["artistName"]?.text {
                        Text(artist)
                    }
                    if let album = candidate.attributes?["albumName"]?.text,
                       album != selectedTitle(candidate) {
                        Text(album)
                    }
                    if let releaseDate = candidate.attributes?["releaseDate"]?.text {
                        Text(releaseDate)
                    }
                }
                .font(.caption)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .lineLimit(1)

                Spacer(minLength: 0)
                if selection == candidate {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(themeStore.accentColor)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appPopupContentBackground()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredCandidate = index } else if hoveredCandidate == index { hoveredCandidate = nil }
        }
        .accessibilityLabel("选择动态封面：\(selectedTitle(candidate))")
        .accessibilityAddTraits(selection == candidate ? .isSelected : [])
    }

    private func selectedTitle(_ candidate: MusicEnrichmentResult) -> String {
        candidate.attributes?["name"]?.text
            ?? candidate.attributes?["albumName"]?.text
            ?? query.album
    }

    private func thumbnailURL(_ candidate: MusicEnrichmentResult) -> URL? {
        guard let template = candidate.attributes?["artwork"]?.dictionary?["url"]?.text else { return nil }
        return URL(string: template
            .replacingOccurrences(of: "{w}", with: "96")
            .replacingOccurrences(of: "{h}", with: "96")
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }

    private func previewURL(_ candidate: MusicEnrichmentResult) -> URL? {
        let motion = candidate.motion ?? []
        let descriptor = motion.first { $0.kind == "square" } ?? motion.first
        guard let url = descriptor.flatMap({ URL(string: $0.url) }), url.scheme == "https" else { return nil }
        return url
    }

    private func validateImport(_ url: URL) {
        importValidationTask?.cancel()
        let pending = MotionVideoImportSelection(url: url)
        isValidatingImport = true
        statusMessage = nil
        importValidationTask = Task { @MainActor in
            defer { if !Task.isCancelled { isValidatingImport = false } }
            do {
                _ = try await cacheServices.musicEnrichmentService.validateMotionVideo(from: pending.url)
                guard !Task.isCancelled else { return }
                importedVideo = pending
                selection = nil
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = (error as? MotionVideoImportError)?.errorDescription ?? "无法读取视频。"
            }
        }
    }

    private func search() {
        guard !isSearching else { return }
        var searchQuery = query
        searchQuery.title = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery.artist = searchArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.title.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        statusMessage = nil
        candidates = []
        hoveredCandidate = nil
        searchTask = Task { @MainActor in
            defer { isSearching = false }
            do {
                let results = try await cacheServices.musicEnrichmentService.searchMotionCandidates(query: searchQuery)
                guard !Task.isCancelled else { return }
                candidates = results.filter { $0.motion?.isEmpty == false }
                if candidates.isEmpty { statusMessage = "未找到动态封面" }
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = "动态封面搜索失败，请重试。"
            }
        }
    }
}

/// A candidate's still cover; its video streams only while hovered or chosen,
/// at thumbnail size, and the player is released as soon as it stops.
private struct MotionCandidatePreview: View {
    let thumbnail: URL?
    let video: URL?
    let plays: Bool

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        AsyncImage(url: thumbnail) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "music.note")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                .appPopupContentBackground()
        }
        .overlay {
            if plays, let video {
                MotionCandidatePlayerLayer(url: video)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct MotionCandidatePlayerLayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> MotionCandidatePlayerView { MotionCandidatePlayerView(url: url) }
    func updateNSView(_ nsView: MotionCandidatePlayerView, context: Context) {}
    static func dismantleNSView(_ nsView: MotionCandidatePlayerView, coordinator: ()) { nsView.stop() }
}

private final class MotionCandidatePlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        super.init(frame: .zero)
        let item = AVPlayerItem(url: url)
        // A 48 pt thumbnail needs the smallest variant of the stream.
        item.preferredMaximumResolution = CGSize(width: 192, height: 192)
        item.preferredPeakBitRate = 800_000
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        wantsLayer = true
        player.play()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}
