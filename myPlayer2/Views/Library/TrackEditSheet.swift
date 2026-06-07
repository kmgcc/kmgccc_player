//
//  TrackEditSheet.swift
//  myPlayer2
//
//  kmgccc_player - Track Metadata Edit Sheet
//  Edit track title, artist, album, artwork, and lyrics.
//

import SwiftUI

private struct TrackEditDeferredMediaSnapshot: Sendable {
    let trackID: UUID
    let libraryRootSnapshot: String
    let artworkFileName: String?
    let lyricsFileName: String?
    let ttmlLyricsFileName: String?

    static func capture(from track: Track) -> TrackEditDeferredMediaSnapshot {
        TrackEditDeferredMediaSnapshot(
            trackID: track.id,
            libraryRootSnapshot: track.libraryRootSnapshot,
            artworkFileName: track.artworkFileName,
            lyricsFileName: track.lyricsFileName,
            ttmlLyricsFileName: track.ttmlLyricsFileName
        )
    }
}

private struct TrackEditDeferredMediaResult: Sendable {
    let artworkData: Data?
    let lyricsTTML: String?
}

private enum TrackEditDeferredMediaLoader {
    nonisolated static func load(from snapshot: TrackEditDeferredMediaSnapshot) -> TrackEditDeferredMediaResult {
        let root = snapshot.libraryRootSnapshot.isEmpty
            ? LocalLibraryPaths.libraryRootURL
            : URL(fileURLWithPath: snapshot.libraryRootSnapshot)
        let folder = root
            .appendingPathComponent("Tracks", isDirectory: true)
            .appendingPathComponent(snapshot.trackID.uuidString, isDirectory: true)

        let artworkURL = resolveArtworkURL(folder: folder, preferredFileName: snapshot.artworkFileName)
        let artworkData = artworkURL.flatMap { try? Data(contentsOf: $0) }

        let ttmlURL = snapshot.ttmlLyricsFileName.map { folder.appendingPathComponent($0) }
        let lyricsURL = snapshot.lyricsFileName.map { folder.appendingPathComponent($0) }
        let lyricsTTML: String?
        if let ttmlURL,
           let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
           let normalized = LyricsFormatSupport.normalizedTTMLText(text) {
            lyricsTTML = normalized
        } else if let lyricsURL,
                  lyricsURL.lastPathComponent.lowercased().hasSuffix(".ttml"),
                  let text = try? String(contentsOf: lyricsURL, encoding: .utf8),
                  let normalized = LyricsFormatSupport.normalizedTTMLText(text) {
            lyricsTTML = normalized
        } else {
            lyricsTTML = nil
        }

        return TrackEditDeferredMediaResult(
            artworkData: artworkData,
            lyricsTTML: lyricsTTML
        )
    }

    private nonisolated static func resolveArtworkURL(folder: URL, preferredFileName: String?) -> URL? {
        let fileManager = FileManager.default
        for fileName in LocalLibraryPaths.trackArtworkCandidateFileNames(preferredFileName: preferredFileName) {
            let candidate = folder.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        guard let preferredFileName, !preferredFileName.isEmpty else { return nil }
        return folder.appendingPathComponent(preferredFileName)
    }
}

struct TrackEditSheet: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM

    let track: Track

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

    @State private var deferredMediaTask: Task<Void, Never>?
    @State private var deferredMediaLoadGeneration: UInt64 = 0
    @State private var originalArtworkData: Data?
    @State private var originalLyricsStorage = TrackLyricsDraft.Storage(ttmlText: nil, plainText: nil)

    private struct TrackEditChangeSet {
        let hasChanges: Bool
        let persistenceMode: TrackEditPersistenceMode
        let affectsLiveLyrics: Bool
    }

    init(track: Track) {
        self.track = track

        let initialLyricsText = Self.initialLyricsText(for: track)
        let initialArtworkData = track.artworkData

        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _trackDescription = State(initialValue: track.userDescription)
        _genreTagsText = State(initialValue: track.genreTags.joined(separator: ", "))
        _language = State(initialValue: track.language)
        _labelOrCompany = State(initialValue: track.labelOrCompany)
        _releaseDateText = State(initialValue: Self.formatDateForEditing(track.releaseDate))
        _qqMusicSongMid = State(initialValue: track.qqMusicSongMid ?? "")
        _metadataSource = State(initialValue: track.metadataSource ?? "")
        _metadataFetchedAt = State(initialValue: track.metadataFetchedAt)
        _metadataConfidence = State(initialValue: track.metadataConfidence)
        _lyricsText = State(initialValue: initialLyricsText)
        _artworkData = State(initialValue: initialArtworkData)
        _lyricsTimeOffsetMs = State(initialValue: track.lyricsTimeOffsetMs)
        _originalArtworkData = State(initialValue: initialArtworkData)
        _originalLyricsStorage = State(initialValue: TrackLyricsDraft.storage(from: initialLyricsText))
    }

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
            onSelectMetadataCandidate: { songMid in
                await fetchMetadataForSongMidIntoDraft(songMid)
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
            loadDeferredMediaData()
        }
        .onDisappear {
            deferredMediaTask?.cancel()
            deferredMediaTask = nil
        }
    }

    private func loadDeferredMediaData() {
        guard track.artworkData == nil || track.ttmlLyricText == nil else { return }

        deferredMediaTask?.cancel()
        deferredMediaLoadGeneration &+= 1
        let generation = deferredMediaLoadGeneration
        let snapshot = TrackEditDeferredMediaSnapshot.capture(from: track)

        deferredMediaTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) { @Sendable in
                TrackEditDeferredMediaLoader.load(from: snapshot)
            }.value

            guard !Task.isCancelled, deferredMediaLoadGeneration == generation else { return }

            if let loadedArtwork = result.artworkData {
                originalArtworkData = loadedArtwork
                if artworkData == nil {
                    artworkData = loadedArtwork
                }
                if track.artworkData == nil {
                    track.artworkData = loadedArtwork
                }
            }

            if let loadedLyrics = result.lyricsTTML {
                originalLyricsStorage = TrackLyricsDraft.storage(from: loadedLyrics)
                if lyricsText.isEmpty {
                    lyricsText = loadedLyrics
                }
                if track.ttmlLyricText?.isEmpty != false {
                    track.ttmlLyricText = loadedLyrics
                }
            }
        }
    }

    private var albumDescriptionFallback: String? {
        libraryVM.albumEntries.first(where: { $0.canonicalKey == track.albumGroupKey })?.description
    }

    private static func initialLyricsText(for track: Track) -> String {
        LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText)
            ?? LyricsFormatSupport.normalizedTTMLText(track.lyricsText)
            ?? ""
    }

    private static func formatDateForEditing(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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

        let lyricsChanged = TrackLyricsDraft.storage(from: lyricsText) != originalLyricsStorage
        let artworkChanged = artworkData != originalArtworkData
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
        guard changeSet.hasChanges else { return }

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
        if changeSet.persistenceMode == .metaAndLyrics || changeSet.persistenceMode == .metaLyricsAndArtwork {
            TrackLyricsDraft.assign(editorText: lyricsText, to: track)
        }
        if changeSet.persistenceMode == .metaAndArtwork || changeSet.persistenceMode == .metaLyricsAndArtwork {
            track.artworkData = artworkData
        }
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
            if changeSet.affectsLiveLyrics {
                refreshLiveLyricsIfEditingCurrentTrack(reason: "track info saved")
            }
        }
    }

    private func refreshLiveLyricsIfEditingCurrentTrack(reason: String) {
        guard playerVM.currentTrack?.id == track.id else { return }
        lyricsVM.ensureAMLLLoaded(
            track: track,
            currentTime: playerVM.lyricsCurrentTime,
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

    @MainActor
    private func fetchMetadataForSongMidIntoDraft(_ songMid: String) async -> Bool {
        guard let detail = await libraryVM.fetchTrackMetadataDetailForMid(
            songMid,
            title: title,
            artist: artist,
            album: album,
            duration: track.duration
        ) else { return false }

        var changed = false
        updateString(&album, with: detail.album, changed: &changed)
        updateString(&trackDescription, with: detail.description, changed: &changed)

        let newGenreTags = detail.genreTags.joined(separator: ", ")
        if genreTagsText != newGenreTags {
            genreTagsText = newGenreTags
            changed = true
        }
        updateString(&language, with: detail.language, changed: &changed)
        updateString(&labelOrCompany, with: detail.labelOrCompany, changed: &changed)

        let newReleaseDate = detail.releaseDate.map(formatDateForEditing) ?? ""
        if releaseDateText != newReleaseDate {
            releaseDateText = newReleaseDate
            changed = true
        }

        updateString(&qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)
        updateString(&metadataSource, with: detail.source.rawValue, changed: &changed)

        metadataFetchedAt = detail.fetchedAt ?? Date()
        metadataConfidence = detail.confidence
        changed = true

        return changed
    }

    private func updateString(_ target: inout String, with candidate: String?, changed: inout Bool) {
        let candidateVal = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target != candidateVal {
            target = candidateVal
            changed = true
        }
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
        Self.formatDateForEditing(date)
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
}

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
