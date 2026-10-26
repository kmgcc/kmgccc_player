//
//  TrackInfoEditorCore.swift
//  myPlayer2
//
//  Reusable song-info editor body for local tracks and external playback mappings.
//

import AppKit
import ImageIO
import PopupKit
import SwiftUI
import UniformTypeIdentifiers

struct TrackInfoEditorRawReference: Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var hasLyrics: Bool
}

struct TrackInfoEditorCore: View {
    enum Mode {
        case local
        case externalPlayback
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @EnvironmentObject private var themeStore: ThemeStore

    let mode: Mode
    let duration: Double
    let rawReference: TrackInfoEditorRawReference?
    let lyricsSearchTrack: Track?
    let allowsArtworkImport: Bool
    let allowsLyricsOffset: Bool
    let allowsDescriptionEditing: Bool
    let canSave: Bool
    let saveTitle: LocalizedStringKey
    let descriptionFallback: String?
    let showsDetailedMetadata: Bool
    var enrichmentKey: String? = nil
    var enrichmentAlbumArtist: String? = nil
    let onSave: () -> Bool
    let onCancel: () -> Void
    let onClearOverride: (() -> Void)?
    let onRestoreAutomatic: (() -> Void)?
    let onFetchMetadata: (() async -> Bool)?
    let onSelectMetadataCandidate: ((String) async -> Bool)?

    @Binding var title: String
    @Binding var artist: String
    @Binding var album: String
    @Binding var trackDescription: String
    @Binding var genreTagsText: String
    @Binding var language: String
    @Binding var labelOrCompany: String
    @Binding var releaseDateText: String
    @Binding var qqMusicSongMid: String
    @Binding var metadataSource: String
    @Binding var metadataFetchedAt: Date?
    @Binding var metadataConfidence: Double?
    @Binding var lyricsText: String
    @Binding var artworkData: Data?
    @Binding var lyricsTimeOffsetMs: Double
    var onArtworkEdited: (() -> Void)? = nil

    @State private var pendingMotionCandidate: MusicEnrichmentResult?
    @State private var pendingMotionVideo: MotionVideoImportSelection?
    @State private var isMotionImportValidating = false
    @State private var motionScope: MotionArtworkScope = .album
    @State private var followAlbumMotion = false
    @State private var isSaving = false
    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var selectedTab: TrackInfoEditorTab = .artworkAndBasics
    @State private var isMetadataLookupInFlight = false
    @State private var metadataLookupMessage: String?
    @State private var lyricsValidationMessage: String?
    @State private var saveFailureMessage: String?
    @State private var coverFetchTask: Task<Void, Never>?
    @State private var metadataFetchTask: Task<Void, Never>?
    @State private var artworkPreviewTask: Task<Void, Never>?
    @State private var lyricsValidationTask: Task<Void, Never>?
    @State private var artworkPreviewImage: TrackInfoArtworkPreviewImage?
    @State private var artworkPreviewSourceIdentity: String?
    @State private var coverCoordinator: CoverSearchCoordinator?
    @State private var metadataCandidates: [QQMusicArtworkCandidate] = []
    @State private var cachedLyricsValidationError: String?

    private var effectiveLyricsValidationError: String? {
        lyricsValidationMessage ?? cachedLyricsValidationError
    }

    var body: some View {
        AppPopupFrame(
            title: mode == .local ? String(localized: "edit.track.title") : "编辑外部播放覆盖信息",
            systemImage: "music.note",
            onClose: {
                guard !isSaving else { return }
                onCancel(); dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TrackInfoEditorTabBar(tabs: tabs, selection: $selectedTab)
                TrackInfoEditorTabPages(tabs: tabs, selection: selectedTab) { tab in
                    AppPopupScrollRegion {
                        VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                            tabPage(tab)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, TrackInfoEditorLayout.pageBottomRoom)
                    }
                }
                // Saving stays disabled while the lyrics are invalid; say why on every tab.
                if let message = saveFailureMessage
                    ?? (selectedTab == .lyrics ? nil : effectiveLyricsValidationError.map { "歌词：\($0)" }) {
                    Text(message)
                        .font(.system(size: SettingsStyleTokens.descriptionFontSize))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .trackInfoEditorSettingsStyle()
        } footer: {
            footerView
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .frame(width: 550, height: 750)
        .dismissTextEditingOnOutsideClick()
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            if coverCoordinator == nil {
                coverCoordinator = CoverSearchCoordinator(
                    coverDownloadService: coverDownloadService,
                    netEaseCoverService: netEaseCoverService,
                    qqMusicCoverService: cacheServices.qqMusicCoverService
                )
            }
            scheduleArtworkPreviewDecode(reason: "onAppear")
            scheduleLyricsValidation(reason: "onAppear", debounceNanoseconds: 0)
        }
        .onDisappear {
            coverFetchTask?.cancel()
            coverFetchTask = nil
            metadataFetchTask?.cancel()
            metadataFetchTask = nil
            artworkPreviewTask?.cancel()
            artworkPreviewTask = nil
            lyricsValidationTask?.cancel()
            lyricsValidationTask = nil
            coverCoordinator?.cancelSearch()
            // Search results contain the downloaded cover bytes. They are
            // transient editor state and must not survive dismissal while the
            // sheet's SwiftUI state is retained for a later presentation.
            coverCoordinator?.clear()
            metadataCandidates.removeAll(keepingCapacity: false)
            pendingMotionCandidate = nil
            pendingMotionVideo = nil
            followAlbumMotion = false
            artworkPreviewImage = nil
            artworkPreviewSourceIdentity = nil
            // Building the panel lays out its whole control tree and decodes the
            // artwork preview in one burst. The objects go on dismissal, but the
            // allocator keeps the freed pages; hand them back once the layers
            // have finished tearing down.
            CacheManager.trimProcessMemory()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                CacheManager.trimProcessMemory()
            }
        }
        .onChange(of: coverCoordinator?.selectedForPreview) { _, newValue in
            if let candidate = newValue {
                artworkData = candidate.imageData
                onArtworkEdited?()
            }
        }
        .onChange(of: artworkData) { _, _ in
            scheduleArtworkPreviewDecode(reason: "artworkData changed")
        }
        .onChange(of: lyricsText) { _, _ in
            lyricsValidationMessage = nil
            scheduleLyricsValidation(reason: "lyricsText changed")
        }
    }

    /// External playback has no description or library metadata to edit.
    private var tabs: [TrackInfoEditorTab] {
        let hasDetails = allowsDescriptionEditing || showsDetailedMetadata || onFetchMetadata != nil
        return TrackInfoEditorTab.allCases.filter { $0 != .details || hasDetails }
    }

    @ViewBuilder
    private func tabPage(_ tab: TrackInfoEditorTab) -> some View {
        switch tab {
        case .artworkAndBasics:
            if let rawReference {
                rawReferenceSection(rawReference)
            }
            artworkSection
            if let motionQuery {
                SettingsSection("动态封面") {
                    MotionArtworkSearchSection(
                        query: motionQuery,
                        selection: $pendingMotionCandidate,
                        importedVideo: $pendingMotionVideo,
                        isValidatingImport: $isMotionImportValidating,
                        scope: $motionScope,
                        hasOwnChoice: lyricsSearchTrack?.motionArtwork?.isUserSelected == true,
                        followAlbum: $followAlbumMotion
                    )
                }
            }
            TrackInfoBasicsSection(title: $title, artist: $artist, album: $album, duration: duration)
        case .details:
            detailsPage
        case .lyrics:
            lyricsPage
        }
    }

    private func rawReferenceSection(_ reference: TrackInfoEditorRawReference) -> some View {
        SettingsSection("原始信息", info: "外部播放提供的信息。下方的修改会保存为这首歌的匹配与显示设置。") {
            HStack(alignment: .top, spacing: 16) {
                TrackInfoStaticArtworkPreview(data: reference.artworkData, size: 72)

                VStack(alignment: .leading, spacing: 6) {
                    TrackInfoValueRow("标题", value: reference.title)
                    TrackInfoValueRow("艺人", value: reference.artist)
                    TrackInfoValueRow("专辑", value: reference.album)
                    TrackInfoValueRow("歌词", value: reference.hasLyrics ? "可用" : "无")
                }
            }
        }
    }

    private var artworkSection: some View {
        TrackInfoArtworkSection(
            coordinator: coverCoordinator,
            hasArtwork: artworkData != nil,
            allowsImport: allowsArtworkImport,
            onChooseImage: { showingArtworkPicker = true },
            onFetchCover: { fetchCover() },
            onRemoveArtwork: {
                artworkData = nil
                onArtworkEdited?()
                coverCoordinator?.clear()
            },
            onSelectCandidate: { candidate in
                coverCoordinator?.selectForPreview(candidate)
                artworkData = candidate.imageData
                onArtworkEdited?()
            },
            preview: { artworkPreview(size: 100) }
        )
        .fileImporter(
            isPresented: $showingArtworkPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result)
        }
    }

    private func artworkPreview(size: CGFloat) -> some View {
        Group {
            if let artworkPreviewImage {
                Image(decorative: artworkPreviewImage.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            }
        }
        .frame(width: size, height: size)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func scheduleArtworkPreviewDecode(reason _: String) {
        artworkPreviewTask?.cancel()
        artworkPreviewTask = nil

        guard let data = artworkData, !data.isEmpty else {
            artworkPreviewImage = nil
            artworkPreviewSourceIdentity = nil
            return
        }

        let identity = TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: data)
        guard identity != artworkPreviewSourceIdentity else { return }

        if let cachedPreview = TrackInfoArtworkPreviewDecoder.cachedImage(forIdentity: identity) {
            artworkPreviewSourceIdentity = identity
            artworkPreviewImage = cachedPreview
            return
        }

        artworkPreviewSourceIdentity = identity
        artworkPreviewImage = nil

        artworkPreviewTask = Task.detached(priority: .utility) { [data, identity] in
            guard !Task.isCancelled else { return }
            let decoded = TrackInfoArtworkPreviewDecoder.decode(
                data: data,
                identity: identity,
                maxPixelSize: 320
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard artworkPreviewSourceIdentity == identity else { return }
                artworkPreviewImage = decoded?.image
            }
        }
    }

    @ViewBuilder
    private var detailsPage: some View {
        // The lookup also fills the description, so it comes first.
        if onFetchMetadata != nil {
            TrackInfoMetadataLookupSection(
                isLookupInFlight: isMetadataLookupInFlight,
                message: metadataLookupMessage,
                candidates: metadataCandidates,
                selectedSongMid: qqMusicSongMid,
                onFetch: { fetchMetadata() },
                onSelect: { selectMetadataCandidate($0) }
            )
        }

        if allowsDescriptionEditing {
            TrackInfoDescriptionSection(text: $trackDescription, albumDescription: descriptionFallback)
        }

        if showsDetailedMetadata {
            TrackInfoDetailFieldsSection(
                genreTagsText: $genreTagsText,
                releaseDateText: $releaseDateText,
                language: $language,
                labelOrCompany: $labelOrCompany
            )
            TrackInfoMetadataRecordSection(
                songMid: qqMusicSongMid,
                source: metadataSource,
                fetchedAt: metadataFetchedAt,
                confidence: metadataConfidence
            )
            if let trackID = lyricsSearchTrack?.id {
                TrackLoudnessMetadataSection(trackIDs: [trackID])
            }
        }
    }

    private var lyricsPage: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
            TrackInfoLyricsEditorSection(
                lyricsText: $lyricsText,
                validationMessage: effectiveLyricsValidationError,
                onImport: { showingLyricsPicker = true },
                onClear: { lyricsText = "" }
            )

            if allowsLyricsOffset {
                TrackInfoLyricsOffsetSection(offsetMs: $lyricsTimeOffsetMs)
            }

            lyricsSearchSection
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: LocalLyricsImporter.pickerContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    @ViewBuilder
    private var lyricsSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lyricsSearchTrack {
                LDDCSearchSection(track: lyricsSearchTrack) { ttml in
                    lyricsText = ttml
                }
            } else {
                LDDCSearchSection(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    autoSearchOnAppear: false
                ) { ttml in
                    lyricsText = ttml
                }
                .id("\(title)|\(artist)|\(album)|\(duration)")
            }
        }
    }

    private var footerView: some View {
        AppPopupActionGroup {
            Button(LocalizedStringKey("edit.track.cancel")) {
                onCancel()
                dismiss()
            }
            .buttonStyle(AppDialogGlassButtonStyle())
            .keyboardShortcut(.escape)

            if let onClearOverride {
                Button("清除覆盖", role: .destructive) {
                    onClearOverride()
                    dismiss()
                }
                .buttonStyle(AppDialogGlassButtonStyle(kind: .destructive))
            }


            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Button(saveTitle) {
                saveEdits()
            }
            .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
            .keyboardShortcut(.return)
            .disabled((!canSave && pendingMotionCandidate == nil && pendingMotionVideo == nil && !followAlbumMotion) || effectiveLyricsValidationError != nil || isSaving || isMotionImportValidating)
        }
    }

    private var motionQuery: MusicEnrichmentQuery? {
        guard let key = enrichmentKey ?? lyricsSearchTrack.map({ "track:" + $0.id.uuidString }) else { return nil }
        return MusicEnrichmentQuery(
            key: key, title: title, artist: artist, album: album, duration: duration,
            albumArtist: lyricsSearchTrack?.albumArtist ?? enrichmentAlbumArtist
        )
    }

    private func saveEdits() {
        guard !isSaving, !isMotionImportValidating else { return }
        if let message = LyricsEditorInput.saveIssue(in: lyricsText) {
            lyricsValidationMessage = message
            return
        }
        saveFailureMessage = nil
        isSaving = true
        let candidate = pendingMotionCandidate
        let importedVideo = pendingMotionVideo
        let query = motionQuery
        let scope = motionScope
        let followAlbum = followAlbumMotion
        Task { @MainActor in
            defer { isSaving = false }
            do {
                guard onSave() else {
                    saveFailureMessage = "无法保存，请重试。"
                    return
                }
                if let importedVideo, let query {
                    _ = try await cacheServices.musicEnrichmentService.importMotionVideo(from: importedVideo.url, for: query, scope: scope)
                } else if let candidate, let query {
                    _ = try await cacheServices.musicEnrichmentService.selectMotion(candidate, for: query, scope: scope)
                } else if followAlbum, let query {
                    _ = try await cacheServices.musicEnrichmentService.clearMotion(for: query, resumeAutomatic: true)
                }
                dismiss()
            } catch {
                Log.warning("[MusicEnrichment] event=editor-import-failed errorType=\(String(describing: type(of: error)))", category: .library)
                saveFailureMessage = (error as? MotionVideoImportError)?.errorDescription ?? "动态封面保存失败，请重试。"
            }
        }
    }

    private func scheduleLyricsValidation(
        reason _: String,
        debounceNanoseconds: UInt64 = 120_000_000
    ) {
        lyricsValidationTask?.cancel()
        let text = lyricsText
        lyricsValidationTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let review = await LyricsEditorInput.review(text)
            guard !Task.isCancelled else { return }
            guard text == self.lyricsText else { return }
            let message: String?
            switch review {
            case .accepted:
                message = nil
            case .rejected(let reason):
                message = reason
            case .converted(let ttml):
                // Pasted lyrics in another format; the replaced text is validated again.
                self.lyricsText = ttml
                return
            }
            self.cachedLyricsValidationError = message
            if message == nil, self.lyricsValidationMessage != nil {
                self.lyricsValidationMessage = nil
            }
        }
    }

    private func fetchCover() {
        coverFetchTask?.cancel()
        coverCoordinator?.clear()

        coverFetchTask = Task {
            guard let coordinator = coverCoordinator else { return }
            // External display edits are independent of the provider identity.
            await coordinator.search(
                artist: mode == .externalPlayback ? (rawReference?.artist ?? artist) : artist,
                album: mode == .externalPlayback ? (rawReference?.album ?? album) : album,
                title: mode == .externalPlayback ? (rawReference?.title ?? title) : title,
                duration: duration
            )
        }
    }

    private func fetchMetadata() {
        guard let onFetchMetadata else { return }
        metadataFetchTask?.cancel()
        isMetadataLookupInFlight = true
        metadataLookupMessage = nil
        metadataCandidates = []

        metadataFetchTask = Task {
            let candidates = await libraryVM.searchTrackMetadataCandidates(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            await MainActor.run {
                self.metadataCandidates = candidates
            }

            let didApply = await onFetchMetadata()
            await MainActor.run {
                isMetadataLookupInFlight = false
                if didApply {
                    metadataLookupMessage = "已自动应用最佳匹配"
                } else {
                    metadataLookupMessage = candidates.isEmpty ? "未找到匹配" : "没有可补全的空白字段，可从候选中选择"
                }
            }
        }
    }

    private func selectMetadataCandidate(_ candidate: QQMusicArtworkCandidate) {
        guard let songMid = candidate.songMid else { return }
        guard let onSelectMetadataCandidate else { return }
        metadataFetchTask?.cancel()
        isMetadataLookupInFlight = true
        metadataLookupMessage = nil

        metadataFetchTask = Task {
            let didApply = await onSelectMetadataCandidate(songMid)
            await MainActor.run {
                isMetadataLookupInFlight = false
                metadataLookupMessage = didApply ? "已更新所选元数据" : "未发生更改"
            }
        }
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
        guard allowsArtworkImport else { return }
        guard case .success(let urls) = result, let url = urls.first else { return }

        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) { @Sendable in
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try? Data(contentsOf: url)
            }.value
            if let data {
                artworkData = data
                onArtworkEdited?()
            }
        }
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        Task { @MainActor in
            switch await LocalLyricsImporter.loadTTML(fromFileAt: url) {
            case .success(let ttml):
                lyricsValidationMessage = nil
                lyricsText = ttml
            case .failure(let error):
                lyricsValidationMessage = error.localizedDescription
            }
        }
    }

}

private nonisolated final class TrackInfoArtworkPreviewImage: @unchecked Sendable {
    let identity: String
    let cgImage: CGImage
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int

    init(identity: String, cgImage: CGImage, sourcePixelWidth: Int, sourcePixelHeight: Int) {
        self.identity = identity
        self.cgImage = cgImage
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
    }
}

private nonisolated struct TrackInfoArtworkPreviewDecodeResult: Sendable {
    let image: TrackInfoArtworkPreviewImage
}

private nonisolated enum TrackInfoArtworkPreviewDecoder {
    private nonisolated(unsafe) static let previewCache: NSCache<NSString, TrackInfoArtworkPreviewImage> = {
        let cache = NSCache<NSString, TrackInfoArtworkPreviewImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    nonisolated static func lightweightIdentity(for data: Data) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count
            guard count > 0 else { return }

            func feed(_ byte: UInt8) {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }

            let edgeCount = min(128, count)
            for index in 0..<edgeCount {
                feed(rawBuffer[index])
            }

            if count > edgeCount {
                let suffixStart = max(edgeCount, count - edgeCount)
                for index in suffixStart..<count {
                    feed(rawBuffer[index])
                }
            }
        }
        return "\(data.count)-\(String(hash, radix: 16))"
    }

    nonisolated static func cachedImage(forIdentity identity: String) -> TrackInfoArtworkPreviewImage? {
        previewCache.object(forKey: identity as NSString)
    }

    nonisolated static func decode(
        data: Data,
        identity: String,
        maxPixelSize: Int
    ) -> TrackInfoArtworkPreviewDecodeResult? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let result = TrackInfoArtworkPreviewDecodeResult(
            image: TrackInfoArtworkPreviewImage(
                identity: identity,
                cgImage: cgImage,
                sourcePixelWidth: sourceWidth,
                sourcePixelHeight: sourceHeight
            )
        )
        previewCache.setObject(
            result.image,
            forKey: identity as NSString,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return result
    }
}

private struct TrackInfoStaticArtworkPreview: View {
    let data: Data?
    let size: CGFloat

    @State private var image: TrackInfoArtworkPreviewImage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: data.map { TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: $0) } ?? "nil") {
            task?.cancel()
            guard let data, !data.isEmpty else {
                image = nil
                return
            }
            let identity = TrackInfoArtworkPreviewDecoder.lightweightIdentity(for: data)
            task = Task.detached(priority: .utility) {
                let decoded = TrackInfoArtworkPreviewDecoder.decode(
                    data: data,
                    identity: identity,
                    maxPixelSize: 160
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    image = decoded?.image
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }
}
