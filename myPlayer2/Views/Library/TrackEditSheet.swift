//
//  TrackEditSheet.swift
//  myPlayer2
//
//  kmgccc_player - Track Metadata Edit Sheet
//  Edit track title, artist, album, artwork, and lyrics.
//

import SwiftUI
import UniformTypeIdentifiers

/// Sheet for editing track metadata.
struct TrackEditSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @EnvironmentObject private var themeStore: ThemeStore

    let track: Track

    // MARK: - Editable State

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var trackDescription: String = ""
    @State private var genreTagsText: String = ""
    @State private var language: String = ""
    @State private var labelOrCompany: String = ""
    @State private var releaseDateText: String = ""
    @State private var qqMusicSongMid: String = ""
    @State private var metadataSource: String = ""
    @State private var metadataFetchedAt: Date?
    @State private var metadataConfidence: Double?
    @State private var lyricsText: String = ""
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0

    // MARK: - UI State

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var coverFetchTask: Task<Void, Never>?

    // MARK: - Cover Search Coordinator

    @State private var coverCoordinator: CoverSearchCoordinator?

    private struct TrackEditChangeSet {
        let hasChanges: Bool
        let persistenceMode: TrackEditPersistenceMode
        let affectsLiveLyrics: Bool
    }

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

    var body: some View {
        TrackInfoEditorCore(
            mode: .local,
            duration: track.duration,
            rawReference: nil,
            lyricsSearchTrack: track,
            allowsArtworkImport: true,
            allowsLyricsOffset: true,
            allowsDescriptionEditing: true,
            canSave: trackEditChangeSet.hasChanges,
            saveTitle: "edit.track.save",
            descriptionFallback: albumDescriptionFallback,
            showsDetailedMetadata: true,
            onSave: {
                saveChanges()
            },
            onCancel: {},
            onClearOverride: nil,
            onRestoreAutomatic: nil,
            onFetchMetadata: {
                await fetchMissingMetadataIntoDraft()
            },
            title: $title,
            artist: $artist,
            album: $album,
            trackDescription: $trackDescription,
            genreTagsText: $genreTagsText,
            language: $language,
            labelOrCompany: $labelOrCompany,
            releaseDateText: $releaseDateText,
            qqMusicSongMid: $qqMusicSongMid,
            metadataSource: $metadataSource,
            metadataFetchedAt: $metadataFetchedAt,
            metadataConfidence: $metadataConfidence,
            lyricsText: $lyricsText,
            artworkData: $artworkData,
            lyricsTimeOffsetMs: $lyricsTimeOffsetMs
        )
        .onAppear {
            loadTrackData()
        }
        .onDisappear {
            coverFetchTask?.cancel()
            coverFetchTask = nil
            coverCoordinator?.cancelSearch()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("edit.track.title")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                dismiss()
            }
        }
        .padding()
    }

    // MARK: - Artwork Section

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("edit.track.artwork", systemImage: "photo")
                .font(.headline)

            HStack(spacing: 16) {
                // Artwork preview
                Group {
                    if let data = artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Button(LocalizedStringKey("edit.track.choose_image")) {
                        showingArtworkPicker = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    Button(LocalizedStringKey("查找封面")) {
                        fetchCover()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(coverCoordinator?.isLoading == true)

                    if coverCoordinator?.isLoading == true {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if artworkData != nil {
                        Button(LocalizedStringKey("edit.track.remove_artwork")) {
                            artworkData = nil
                            coverCoordinator?.clear()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .clipShape(Capsule())
                    }

                    if let error = coverCoordinator?.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Candidate strip (shown when candidates available)
                if let coordinator = coverCoordinator, coordinator.hasCandidates {
                    CoverCandidateStripView(
                        candidates: coordinator.candidates,
                        selectedCandidate: coordinator.selectedForPreview,
                        onSelect: { candidate in
                            coordinator.selectForPreview(candidate)
                            artworkData = candidate.imageData
                        }
                    )
                }
            }
        }
        .fileImporter(
            isPresented: $showingArtworkPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result)
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("edit.track.metadata", systemImage: "info.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.track_title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "edit.track.track_title", text: $title
                    )
                    .textFieldStyle(.roundedBorder)
                }

                // Artist
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.artist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "edit.track.artist_name", text: $artist
                    )
                    .textFieldStyle(.roundedBorder)
                }

                // Album
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.album")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("edit.track.album_name", text: $album)
                        .textFieldStyle(.roundedBorder)
                }

                // Duration (read-only)
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.duration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(formatDuration(track.duration))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Lyrics Section

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    "edit.track.lyrics", systemImage: "text.quote"
                )
                .font(.headline)

                Spacer()

                Button {
                    openURL(amllDbURL)
                } label: {
                    Label("AMLL DB", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button {
                    openURL(ttmlToolURL)
                } label: {
                    Label("TTML Tool", systemImage: "hammer.fill")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button(LocalizedStringKey("edit.track.import_lyrics")) {
                    showingLyricsPicker = true
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)
            }

            Text(
                "AMLL DB 歌词库中的 TTML 专为 AMLL 组件设计，支持对唱歌词、背景歌词等高级特性，来自网络的转换歌词仅为歌词缺失情况下的备选。您也可以使用 AMLL TTML Tool 自己制作歌词使用或贡献到 AMLL DB。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $lyricsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("edit.track.paste_desc")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("edit.track.offset")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button(LocalizedStringKey("edit.track.reset")) {
                        lyricsTimeOffsetMs = 0
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .font(.caption)
                }

                Slider(value: $lyricsTimeOffsetMs, in: -5000...5000, step: 100)

                Text(NSLocalizedString("edit.track.offset_desc", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.vertical, 8)

            // LDDC Lyrics Search
            LDDCSearchSection(track: track) { ttml in
                lyricsText = ttml
            }
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "ttml") ?? .xml,
                .plainText,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button(LocalizedStringKey("edit.track.cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .keyboardShortcut(.escape)

            Spacer()

            Button(LocalizedStringKey("edit.track.save")) {
                saveChanges()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .keyboardShortcut(.return)
            .disabled(!trackEditChangeSet.hasChanges)
        }
        .padding()
    }

    // MARK: - Data Handling

    private func loadTrackData() {
        title = track.title
        artist = track.artist
        album = track.album
        trackDescription = track.userDescription
        genreTagsText = track.genreTags.joined(separator: ", ")
        language = track.language
        labelOrCompany = track.labelOrCompany
        releaseDateText = formatDateForEditing(track.releaseDate)
        qqMusicSongMid = track.qqMusicSongMid ?? ""
        metadataSource = track.metadataSource ?? ""
        metadataFetchedAt = track.metadataFetchedAt
        metadataConfidence = track.metadataConfidence
        lyricsText = track.ttmlLyricText ?? track.lyricsText ?? ""
        artworkData = track.artworkData
        lyricsTimeOffsetMs = track.lyricsTimeOffsetMs
        loadDeferredMediaData()
    }

    private func loadDeferredMediaData() {
        let artworkURL = track.artworkData == nil ? track.resolvedArtworkURL() : nil
        let ttmlURL = track.ttmlLyricText == nil ? track.resolvedTTMLURL() : nil
        let legacyLyricsURL = track.lyricsText == nil ? track.resolvedLyricsURL() : nil

        guard artworkURL != nil || ttmlURL != nil || legacyLyricsURL != nil else { return }

        Task { @MainActor in
            async let artworkTask: Data? = Task.detached(priority: .utility) { @Sendable in
                guard let artworkURL else { return nil }
                return try? Data(contentsOf: artworkURL)
            }.value
            async let lyricsTask: String? = Task.detached(priority: .utility) { @Sendable in
                if let ttmlURL,
                   let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
                   !text.isEmpty {
                    return text
                }
                if let legacyLyricsURL,
                   let text = try? String(contentsOf: legacyLyricsURL, encoding: .utf8),
                   !text.isEmpty {
                    return text
                }
                return nil
            }.value

            let loadedArtwork = await artworkTask
            let loadedLyrics = await lyricsTask

            if let loadedArtwork, artworkData == nil {
                artworkData = loadedArtwork
                track.artworkData = loadedArtwork
            }
            if let loadedLyrics, lyricsText.isEmpty {
                lyricsText = loadedLyrics
                if loadedLyrics.lowercased().contains("<tt") {
                    track.ttmlLyricText = loadedLyrics
                } else {
                    track.lyricsText = loadedLyrics
                }
            }
        }
    }

    private var albumDescriptionFallback: String? {
        libraryVM.albumEntries.first(where: { $0.canonicalKey == track.albumGroupKey })?.description
    }

    private var trackEditChangeSet: TrackEditChangeSet {
        let savedTitle =
            title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        let savedArtist =
            artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        let savedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        let lyricsOffsetChanged = abs(lyricsTimeOffsetMs - track.lyricsTimeOffsetMs) > 0.000_1
        let metadataChanged =
            savedTitle != track.title
            || savedArtist != track.artist
            || savedAlbum != track.album
            || trackDescription != track.userDescription
            || parsedGenreTags(from: genreTagsText) != track.genreTags
            || language.trimmingCharacters(in: .whitespacesAndNewlines) != track.language
            || labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines) != track.labelOrCompany
            || parseEditingDate(releaseDateText) != track.releaseDate
            || optionalTrimmed(qqMusicSongMid) != track.qqMusicSongMid
            || optionalTrimmed(metadataSource) != track.metadataSource
            || metadataFetchedAt != track.metadataFetchedAt
            || metadataConfidence != track.metadataConfidence
            || lyricsOffsetChanged

        let lyricsChanged = TrackLyricsDraft.differs(from: track, editorText: lyricsText)
        let artworkChanged = artworkData != track.artworkData
        let hasChanges = metadataChanged || lyricsChanged || artworkChanged

        let persistenceMode: TrackEditPersistenceMode
        if artworkChanged && lyricsChanged {
            persistenceMode = .metaLyricsAndArtwork
        } else if artworkChanged {
            persistenceMode = .metaAndArtwork
        } else if lyricsChanged {
            persistenceMode = .metaAndLyrics
        } else {
            persistenceMode = .metaOnly
        }

        return TrackEditChangeSet(
            hasChanges: hasChanges,
            persistenceMode: persistenceMode,
            affectsLiveLyrics: lyricsChanged || lyricsOffsetChanged
        )
    }

    private func reason(for mode: TrackEditPersistenceMode, preferredReason: String?) -> String {
        switch mode {
        case .metaOnly:
            return preferredReason ?? "trackEditMetaOnly"
        case .metaAndLyrics:
            return preferredReason ?? "trackEditLyrics"
        case .metaAndArtwork, .metaLyricsAndArtwork:
            return "trackEditArtwork"
        }
    }

    private func saveChanges(preferredReason: String? = nil) {
        let changeSet = trackEditChangeSet
        guard changeSet.hasChanges else {
            print("[TrackEditSheet] No changes detected, skipping save")
            return
        }

        track.title =
            title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        track.artist =
            artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        track.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        track.userDescription = trackDescription
        track.genreTags = parsedGenreTags(from: genreTagsText)
        track.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        track.labelOrCompany = labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        track.releaseDate = parseEditingDate(releaseDateText)
        track.qqMusicSongMid = optionalTrimmed(qqMusicSongMid)
        track.metadataSource = optionalTrimmed(metadataSource)
        track.metadataFetchedAt = metadataFetchedAt
        track.metadataConfidence = metadataConfidence
        TrackLyricsDraft.assign(editorText: lyricsText, to: track)
        track.artworkData = artworkData
        track.lyricsTimeOffsetMs = lyricsTimeOffsetMs

        if changeSet.affectsLiveLyrics {
            refreshLiveLyricsIfEditingCurrentTrack(reason: "track info saved draft")
        }

        Task {
            await libraryVM.saveTrackEdits(
                track,
                mode: changeSet.persistenceMode,
                reason: reason(for: changeSet.persistenceMode, preferredReason: preferredReason)
            )
            print("[TrackEditSheet] Saved changes for: \(track.title)")
            if changeSet.affectsLiveLyrics {
                refreshLiveLyricsIfEditingCurrentTrack(reason: "track info saved")
            }
        }
    }

    private func refreshLiveLyricsIfEditingCurrentTrack(reason: String) {
        guard playerVM.currentTrack?.id == track.id else { return }
        lyricsVM.ensureAMLLLoaded(
            track: track,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceLyricsReload: true
        )
    }

    @MainActor
    private func fetchMissingMetadataIntoDraft() async -> Bool {
        guard let detail = await libraryVM.fetchTrackMetadataDetail(track) else { return false }
        guard detail.confidence >= 0.70 else { return false }

        var changed = false
        if LibraryNormalization.isUnknownAlbum(album) {
            fillString(&album, with: detail.album, changed: &changed)
        }
        fillString(&trackDescription, with: detail.description, changed: &changed)
        if genreTagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !detail.genreTags.isEmpty {
            genreTagsText = detail.genreTags.joined(separator: ", ")
            changed = true
        }
        fillString(&language, with: detail.language, changed: &changed)
        fillString(&labelOrCompany, with: detail.labelOrCompany, changed: &changed)
        if releaseDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let releaseDate = detail.releaseDate {
            releaseDateText = formatDateForEditing(releaseDate)
            changed = true
        }
        fillString(&qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)
        fillString(&metadataSource, with: detail.source.rawValue, changed: &changed)
        if metadataFetchedAt == nil {
            metadataFetchedAt = detail.fetchedAt ?? Date()
            changed = true
        }
        if metadataConfidence == nil {
            metadataConfidence = detail.confidence
            changed = true
        }
        return changed
    }

    private func fillString(_ target: inout String, with candidate: String?, changed: inout Bool) {
        guard target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        target = candidate
        changed = true
    }

    private func parsedGenreTags(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" }
            .compactMap { part in
                let tag = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
                return tag
            }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formatDateForEditing(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseEditingDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
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
                print("[TrackEditSheet] Imported artwork: \(data.count) bytes")
            }
        }
    }

    private func fetchCover() {
        coverFetchTask?.cancel()
        coverCoordinator?.clear()

        coverFetchTask = Task {
            guard let coordinator = coverCoordinator else { return }
            await coordinator.search(
                artist: artist,
                album: album,
                title: title,
                duration: track.duration
            )
            // Note: artworkData is updated reactively via onChange(of: selectedForPreview)
        }
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) { @Sendable in
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            if let text {
                lyricsText = text
                print("[TrackEditSheet] Imported lyrics: \(text.prefix(50))...")
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Preview

#Preview("Track Edit Sheet") {
    let track = Track(
        title: "Sample Track",
        artist: "Sample Artist",
        album: "Sample Album",
        duration: 180,
        fileBookmarkData: Data(),
        originalFilePath: "/path/to/file.mp3"
    )

    TrackEditSheet(track: track)
}
