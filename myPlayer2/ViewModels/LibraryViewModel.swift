//
//  LibraryViewModel.swift
//  myPlayer2
//
//  kmgccc_player - Library ViewModel
//  Manages playlists for the UI.
//
//  Tracks/sections are loaded from Music Library (disk truth), then kept in memory.
//

import Foundation
import SwiftUI

enum TrackEditPersistenceMode {
    case metaOnly
    case metaAndLyrics
    case metaAndArtwork
    case metaLyricsAndArtwork
}

enum TrackSortKey: String, CaseIterable, Identifiable {
    case importedAt
    case addedAt
    case title
    case artist
    case duration
    case playCount
    case preference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importedAt:
            return NSLocalizedString("sort.imported_time", comment: "")
        case .addedAt:
            return NSLocalizedString("sort.added_time", comment: "")
        case .title:
            return NSLocalizedString("sort.title", comment: "")
        case .artist:
            return NSLocalizedString("sort.artist", comment: "")
        case .duration:
            return NSLocalizedString("sort.duration", comment: "")
        case .playCount:
            return NSLocalizedString("sort.play_count", comment: "")
        case .preference:
            return NSLocalizedString("sort.preference", comment: "")
        }
    }
}

enum TrackSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending:
            return NSLocalizedString("sort.ascending", comment: "")
        case .descending:
            return NSLocalizedString("sort.descending", comment: "")
        }
    }
}

enum LibraryLoadState {
    case loading
    case loaded
}

/// Explicit selection type for library content.
/// Replaces the ambiguous nil-based selection with explicit cases.
enum LibrarySelection: Hashable {
    case allSongs
    case playlist(UUID)
    case artist(String)
    case album(String)
}

/// Observable ViewModel for library content.
/// Manages playlists and selected playlist state.
@Observable
@MainActor
final class LibraryViewModel {
    struct TrackUpdateEvent: Equatable {
        let trackID: UUID
        let revision: Int
    }

    // MARK: - Published State

    /// Data loading state.
    var state: LibraryLoadState = .loading

    /// All playlists in the library.
    private(set) var playlists: [Playlist] = []

    /// Runtime-only artists derived from disk scan.
    private(set) var runtimeArtists: [ArtistSection] = []

    /// Runtime-only albums derived from disk scan.
    private(set) var runtimeAlbums: [AlbumSection] = []

    private(set) var artistEntries: [ArtistEntry] = []
    private(set) var albumEntries: [AlbumEntry] = []

    /// All tracks loaded from Music Library (in-memory snapshot).
    private(set) var allTracks: [Track] = []
    private(set) var playlistItemAddedAtMap: [UUID: [UUID: Date]] = [:]

    /// Currently selected playlist (nil = All Songs, unless artist/album selected).
    /// Published so UI can react to changes.
    var selectedPlaylistId: UUID? {
        didSet {
            if selectedPlaylistId != nil {
                selectedArtistKey = nil
                selectedAlbumKey = nil
                selectedAlbumName = nil
                applySortPreferenceForCurrentSelection()
            } else if selectedArtistKey == nil && selectedAlbumKey == nil {
                // Only apply sort if we reverted to All Songs (no other selection active)
                applySortPreferenceForCurrentSelection()
            }
        }
    }

    /// Currently selected artist key (normalized).
    var selectedArtistKey: String? {
        didSet {
            if selectedArtistKey != nil {
                selectedPlaylistId = nil
                selectedAlbumKey = nil
                selectedAlbumName = nil
            }
        }
    }

    /// Currently selected album key (normalized album + artist).
    var selectedAlbumKey: String? {
        didSet {
            if selectedAlbumKey != nil {
                selectedPlaylistId = nil
                selectedArtistKey = nil
            }
        }
    }

    /// Selected album display name for header.
    var selectedAlbumName: String?
    
    /// Explicit current selection (replaces ambiguous nil-based selection).
    /// Default is .allSongs, never nil.
    var currentSelection: LibrarySelection = .allSongs {
        didSet {
            // Sync legacy properties for backward compatibility during transition
            switch currentSelection {
            case .allSongs:
                selectedPlaylistId = nil
                selectedArtistKey = nil
                selectedAlbumKey = nil
            case .playlist(let id):
                selectedPlaylistId = id
                selectedArtistKey = nil
                selectedAlbumKey = nil
            case .artist(let key):
                selectedPlaylistId = nil
                selectedArtistKey = key
                selectedAlbumKey = nil
            case .album(let key):
                selectedPlaylistId = nil
                selectedArtistKey = nil
                selectedAlbumKey = key
            }
            selectedAlbumName = nil
            applySortPreferenceForCurrentSelection()
        }
    }

    /// Whether data is loading.
    var isLoading: Bool { state == .loading }

    /// Total track count in library (for display).
    private(set) var totalTrackCount: Int = 0

    /// Trigger for UI refresh.
    private(set) var refreshTrigger: Int = 0
    private(set) var trackUpdateEvent: TrackUpdateEvent?

    /// Trigger to reset search text and focus in the UI (incremented on sidebar selection).
    private(set) var searchResetTrigger: Int = 0

    /// Track sorting preference for playlist views.
    var trackSortKey: TrackSortKey {
        didSet {
            if isApplyingSortPreference { return }
            persistSortPreferenceForCurrentSelection()
        }
    }

    /// Track sorting order.
    var trackSortOrder: TrackSortOrder {
        didSet {
            if isApplyingSortPreference { return }
            persistSortPreferenceForCurrentSelection()
        }
    }

    // MARK: - Dependencies

    private let repository: LibraryRepositoryProtocol
    private var importService: FileImportServiceProtocol?
    private var isApplyingSortPreference = false
    private var trackUpdateRevision = 0

    private struct SortPreference: Codable {
        let key: String
        let order: String
    }

    // MARK: - Initialization

    init(repository: LibraryRepositoryProtocol, libraryService _: LocalLibraryService? = nil) {
        self.repository = repository
        self.trackSortKey =
            TrackSortKey(
                rawValue: UserDefaults.standard.string(
                    forKey: DefaultsKey.trackSortKey
                ) ?? ""
            ) ?? .importedAt
        self.trackSortOrder =
            TrackSortOrder(
                rawValue: UserDefaults.standard.string(
                    forKey: DefaultsKey.trackSortOrder
                ) ?? ""
            ) ?? .descending
        migrateLegacySortPreferenceIfNeeded()
        applySortPreferenceForCurrentSelection()
        self.repository.setChangeHandler { [weak self] change in
            self?.handleRepositoryChange(change)
        }
        print("[Lifecycle] LibraryViewModel.init, id: \(ObjectIdentifier(self))")
        Log.debug("LibraryViewModel initialized", category: .library)
    }

    deinit {
        print("[Lifecycle] LibraryViewModel.deinit, id: \(ObjectIdentifier(self))")
    }

    private func handleRepositoryChange(_ change: LibraryRepositoryChange) {
        switch change {
        case .trackUpdated(let trackID):
            Task { @MainActor [weak self] in
                await self?.applyRepositoryTrackUpdateBatch([trackID])
            }
        case .tracksUpdated(let trackIDs):
            Task { @MainActor [weak self] in
                await self?.applyRepositoryTrackUpdateBatch(trackIDs)
            }
        }
    }

    private func applyRepositoryTrackUpdateBatch(_ trackIDs: [UUID]) async {
        let uniqueTrackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueTrackIDs.isEmpty else { return }

        Log.info(
            "[ImportEnrichmentReload] reload requested for track IDs: \(uniqueTrackIDs.map(\.uuidString))",
            category: .library
        )

        let refreshedTracks = await repository.fetchTracks(ids: uniqueTrackIDs)
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedTracks.map { ($0.id, $0) })
        guard !refreshedByID.isEmpty else { return }

        allTracks = allTracks.map { refreshedByID[$0.id] ?? $0 }
        for playlist in playlists {
            playlist.tracks = playlist.tracks.map { refreshedByID[$0.id] ?? $0 }
        }
        totalTrackCount = allTracks.count

        Log.info(
            "[ImportEnrichmentReload] visible playlist rows refreshed for \(refreshedTracks.count) tracks",
            category: .library
        )

        for trackID in uniqueTrackIDs {
            trackUpdateRevision += 1
            trackUpdateEvent = TrackUpdateEvent(trackID: trackID, revision: trackUpdateRevision)
            NotificationCenter.default.post(
                name: .libraryTrackDidUpdate,
                object: nil,
                userInfo: ["trackID": trackID]
            )
        }

        Log.info(
            "[ImportEnrichmentReload] current detail/lyrics refreshed for current track if applicable",
            category: .library
        )
    }

    /// Set the import service (called after initialization).
    func setImportService(_ service: FileImportServiceProtocol) {
        self.importService = service
        Log.debug("Import service set", category: .library)
    }

    // MARK: - Computed Properties

    /// Get the currently selected playlist object.
    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistId else { return nil }
        return playlists.first { $0.id == id }
    }

    /// Sort tracks for playlist display.
    func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted { sortTrack($0, $1) }
    }

    // MARK: - Loading

    /// Load all library data.
    func load() async {
        Log.debug("load() called", category: .library)
        state = .loading

        await repository.reloadFromLibrary()
        playlists = await repository.fetchPlaylists()
        allTracks = await repository.fetchTracks(in: nil)
        playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
        totalTrackCount = allTracks.count
        runtimeArtists = await repository.fetchArtistSections()
        runtimeAlbums = await repository.fetchAlbumSections()
        artistEntries = await repository.fetchArtistEntries()
        albumEntries = await repository.fetchAlbumEntries()
        reconcileSelectionAfterLoad()

        Log.info("Loaded \(playlists.count) playlists, \(totalTrackCount) total tracks, \(runtimeArtists.count) artists, \(runtimeAlbums.count) albums", category: .library)

        state = .loaded
        
        // Explicitly set default selection to All Songs after load completes
        // This ensures the main content area shows All Songs by default
        if currentSelection == .allSongs {
            // Trigger selection change to force content refresh even if already .allSongs
            currentSelection = .allSongs
        }
    }

    /// Refresh all data and trigger UI update.
    func refresh() async {
        await load()
        refreshTrigger += 1
        Log.debug("Refresh triggered, refreshTrigger=\(refreshTrigger)", category: .library)
    }

    /// Notify the UI that in-memory track-adjacent data changed without forcing a repository reload.
    func notifyTrackAuxiliaryDataChanged(trackIDs: [UUID]) {
        let uniqueTrackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueTrackIDs.isEmpty else { return }

        refreshTrigger += 1

        if let currentTrackID = SharedAppState.shared.playerVM?.currentTrack?.id,
           uniqueTrackIDs.contains(currentTrackID) {
            trackUpdateRevision += 1
            trackUpdateEvent = TrackUpdateEvent(trackID: currentTrackID, revision: trackUpdateRevision)
            NotificationCenter.default.post(
                name: .libraryTrackDidUpdate,
                object: nil,
                userInfo: ["trackID": currentTrackID]
            )
        }
    }

    // MARK: - Import (Per-Playlist)

    /// Import music files to the currently selected playlist.
    /// If no playlist is selected, imports to the most recently selected playlist (if any),
    /// otherwise the first available playlist. Only creates a playlist if none exist.
    func importToCurrentPlaylist() async {
        let clickTimestamp = Date()

        guard let service = importService else {
            Log.warning("Import service not available", category: .import)
            return
        }

        guard let selectedURLs = await service.pickImportURLs(triggeredAt: clickTimestamp) else {
            return
        }

        // Resolve target playlist
        let targetPlaylist: Playlist
        if let selected = selectedPlaylist {
            targetPlaylist = selected
        } else {
            if playlists.isEmpty {
                targetPlaylist = await repository.createPlaylist(
                    name: String(
                        format: NSLocalizedString("library.imported_playlist_name", comment: ""),
                        formattedDate))
                playlists = await repository.fetchPlaylists()
                selectedPlaylistId = targetPlaylist.id
            } else if let lastId = UserDefaults.standard.string(forKey: "lastSelectedPlaylistId"),
                let uuid = UUID(uuidString: lastId),
                let last = playlists.first(where: { $0.id == uuid })
            {
                targetPlaylist = last
                selectedPlaylistId = last.id
            } else {
                let fallback = playlists[0]
                targetPlaylist = fallback
                selectedPlaylistId = fallback.id
            }
        }

        // Perform import
        let count = await service.importSelectedURLs(selectedURLs, to: targetPlaylist)

        // Only refresh if tracks were actually imported
        if count > 0 {
            await refresh()
        }
    }

    /// Import to a specific playlist.
    func importToPlaylist(_ playlist: Playlist) async {
        let clickTimestamp = Date()
        guard let service = importService else {
            Log.warning("Import service not available", category: .import)
            return
        }

        guard let selectedURLs = await service.pickImportURLs(triggeredAt: clickTimestamp) else {
            return
        }

        let count = await service.importSelectedURLs(selectedURLs, to: playlist)

        if count > 0 {
            await refresh()
        }
    }

    // MARK: - Playlist Operations

    /// Create a new playlist and select it.
    func createPlaylist(name: String) async -> Playlist {
        Log.debug("createPlaylist: '\(name)'", category: .library)
        let playlist = await repository.createPlaylist(name: name)
        playlists = await repository.fetchPlaylists()
        selectedPlaylistId = playlist.id
        return playlist
    }

    /// Create a new playlist with default name.
    func createNewPlaylist() async -> Playlist {
        let name = String(
            format: NSLocalizedString("library.new_playlist_name", comment: ""), playlists.count + 1
        )
        return await createPlaylist(name: name)
    }

    /// Select a playlist by ID.
    func selectPlaylist(_ playlist: Playlist?) {
        searchResetTrigger += 1
        selectedPlaylistId = playlist?.id
        selectedArtistKey = nil
        selectedAlbumKey = nil
        selectedAlbumName = nil
        if let id = playlist?.id {
            UserDefaults.standard.set(id.uuidString, forKey: "lastSelectedPlaylistId")
        }
        Log.debug("Selected playlist: \(playlist?.name ?? "All Songs")", category: .library)
    }

    /// Select an artist.
    func selectArtist(_ artist: ArtistSection) {
        searchResetTrigger += 1
        selectedArtistKey = artist.key
        // selectedPlaylistId handled by didSet
    }

    /// Select an album.
    func selectAlbum(_ album: AlbumSection) {
        searchResetTrigger += 1
        selectedAlbumKey = album.key
        selectedAlbumName = album.name
        // selectedPlaylistId handled by didSet
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        await repository.renamePlaylist(playlist, name: name)
        await refresh()
    }

    func savePlaylistEdits(_ playlist: Playlist, name: String, description: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        await repository.updatePlaylistDetails(
            playlist,
            name: trimmedName,
            description: description
        )
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "playlist-\(playlist.id.uuidString)"
        )
        await refresh()
    }

    func deletePlaylist(_ playlist: Playlist) async {
        await repository.deletePlaylist(playlist)
        if currentSelection == .playlist(playlist.id) {
            currentSelection = .allSongs
        }
        await refresh()
    }

    func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.addTracks(tracks, to: playlist)
        await refresh()
    }

    func removeTracksFromPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.removeTracks(tracks, from: playlist)
        await refresh()
    }

    // MARK: - Track Operations

    func deleteTrack(_ track: Track) async {
        await repository.deleteTrack(track)
        await refresh()
    }

    // MARK: - Artist/Album Entry Lookups

    func artistEntry(for section: ArtistSection) -> ArtistEntry? {
        artistEntries.first { $0.canonicalName == section.key }
    }

    func albumEntry(for section: AlbumSection) -> AlbumEntry? {
        albumEntries.first { $0.canonicalKey == section.key }
    }

    // MARK: - Artist/Album Entry Saves

    func saveArtistEntry(_ entry: ArtistEntry) async {
        var persisted = entry
        persisted.updatedAt = Date()
        await repository.updateArtistEntry(persisted)
        if let idx = artistEntries.firstIndex(where: { $0.id == persisted.id }) {
            artistEntries[idx] = persisted
        }
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "artist-\(persisted.canonicalName)"
        )
    }

    func saveArtistEdits(original: ArtistEntry, updated: ArtistEntry) async {
        let trimmedName = updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var persisted = updated
        persisted.displayName = trimmedName
        persisted.canonicalName = LibraryNormalization.normalizeArtist(trimmedName)
        persisted.updatedAt = Date()

        await repository.applyArtistEdits(original: original, updated: persisted)
        currentSelection = .artist(persisted.canonicalName)
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "artist-\(original.canonicalName)"
        )
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "artist-\(persisted.canonicalName)"
        )
        await refresh()
    }

    func saveAlbumEntry(_ entry: AlbumEntry) async {
        var persisted = entry
        persisted.updatedAt = Date()
        await repository.updateAlbumEntry(persisted)
        if let idx = albumEntries.firstIndex(where: { $0.id == persisted.id }) {
            albumEntries[idx] = persisted
        }
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "album-\(persisted.canonicalKey)"
        )
    }

    func saveAlbumEdits(original: AlbumEntry, updated: AlbumEntry) async {
        let trimmedTitle = updated.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        var persisted = updated
        persisted.displayTitle = trimmedTitle
        persisted.canonicalKey = LibraryNormalization.normalizedAlbumKey(
            album: trimmedTitle,
            artist: original.primaryArtistDisplayName
        )
        persisted.primaryArtistCanonicalName = original.primaryArtistCanonicalName
        persisted.primaryArtistDisplayName = original.primaryArtistDisplayName
        persisted.updatedAt = Date()

        await repository.applyAlbumEdits(original: original, updated: persisted)
        currentSelection = .album(persisted.canonicalKey)
        selectedAlbumName = persisted.displayTitle
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "album-\(original.canonicalKey)"
        )
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "album-\(persisted.canonicalKey)"
        )
        await refresh()
    }

    func deleteArtist(_ entry: ArtistEntry) async {
        let affectedTrackIDs = Set(
            allTracks
                .filter { LibraryNormalization.normalizeArtist($0.artist) == entry.canonicalName }
                .map(\.id)
        )
        let affectedAlbumKeys = Set(
            allTracks
                .filter { LibraryNormalization.normalizeArtist($0.artist) == entry.canonicalName }
                .map { LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist) }
        )

        if currentSelection == .artist(entry.canonicalName) {
            currentSelection = .allSongs
        } else if case .album(let key) = currentSelection, affectedAlbumKeys.contains(key) {
            currentSelection = .allSongs
        }

        cleanupPlaybackAfterDeletingTracks(affectedTrackIDs)
        await repository.deleteArtist(entry)
        await refresh()
    }

    func deleteAlbum(_ entry: AlbumEntry) async {
        let affectedTrackIDs = Set(
            allTracks
                .filter {
                    LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                        == entry.canonicalKey
                }
                .map(\.id)
        )

        if currentSelection == .album(entry.canonicalKey) {
            currentSelection = .allSongs
        }

        cleanupPlaybackAfterDeletingTracks(affectedTrackIDs)
        await repository.deleteAlbum(entry)
        await refresh()
    }

    func savePlaylistDescription(_ playlist: Playlist, description: String) async {
        await repository.updatePlaylistDescription(playlist, description: description)
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "playlist-\(playlist.id.uuidString)"
        )
    }

    /// Update track availability after bookmark resolution.
    func updateTrackAvailability(
        _ track: Track, availability: TrackAvailability, refreshedBookmark: Data?
    ) async {
        track.availability = availability
        if let newBookmark = refreshedBookmark {
            track.fileBookmarkData = newBookmark
        }
        await repository.persistTrackMetaOnly(track, reason: "availabilityRefresh")
        await refresh()
    }

    func saveTrackEdits(_ track: Track, mode: TrackEditPersistenceMode, reason: String) async {
        switch mode {
        case .metaOnly:
            await repository.persistTrackMetaOnly(track, reason: reason)
        case .metaAndLyrics:
            await repository.persistTrackMetaAndLyrics(track, reason: reason)
        case .metaAndArtwork:
            await repository.persistTrackMetaAndArtwork(track, reason: reason)
        case .metaLyricsAndArtwork:
            await repository.persistTrackMetaLyricsAndArtwork(track, reason: reason)
        }
        await refresh()
    }

    func clearIndexCacheAndRebuild() async {
        await repository.clearIndexCacheAndRebuild()
        await refresh()
    }

    // MARK: - Display Helpers

    /// Title for the current view.
    var currentTitle: String {
        if let playlist = selectedPlaylist {
            return playlist.name
        } else if let artistKey = selectedArtistKey {
            return runtimeArtists.first(where: { $0.key == artistKey })?.name
                ?? LibraryNormalization.unknownArtist
        } else if let albumName = selectedAlbumName {
            return albumName
        }
        return NSLocalizedString("library.all_songs", comment: "")
    }

    /// Subtitle for the current view.
    var currentSubtitle: String {
        let count = selectedPlaylist?.trackCount ?? totalTrackCount
        let format =
            count == 1
            ? NSLocalizedString("library.song_count_one", comment: "")
            : NSLocalizedString("library.song_count", comment: "")
        return String(format: format, count)
    }

    /// Whether import is available.
    var canImport: Bool {
        importService != nil
    }

    // MARK: - Private Helpers

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }

    // MARK: - Sorting Helpers

    private enum DefaultsKey {
        static let trackSortKey = "trackSortKey"
        static let trackSortOrder = "trackSortOrder"
        static let trackSortPreferencesByPlaylist = "trackSortPreferencesByPlaylist"
        static let trackSortMigrationDone = "trackSortMigrationDone"
    }

    private var sortContextKey: String {
        if let id = selectedPlaylistId {
            return id.uuidString
        } else if let artistKey = selectedArtistKey {
            return "ARTIST_\(artistKey)"
        } else if let albumKey = selectedAlbumKey {
            return "ALBUM_\(albumKey)"
        }
        return "__all_songs__"
    }

    private func persistSortPreferenceForCurrentSelection() {
        var preferences = loadSortPreferencesMap()
        preferences[sortContextKey] = SortPreference(
            key: trackSortKey.rawValue,
            order: trackSortOrder.rawValue
        )
        saveSortPreferencesMap(preferences)
    }

    private func applySortPreferenceForCurrentSelection() {
        let preferences = loadSortPreferencesMap()
        guard let preference = preferences[sortContextKey] else { return }
        guard
            let key = TrackSortKey(rawValue: preference.key),
            let order = TrackSortOrder(rawValue: preference.order)
        else {
            return
        }

        isApplyingSortPreference = true
        trackSortKey = key
        trackSortOrder = order
        isApplyingSortPreference = false
    }

    private func loadSortPreferencesMap() -> [String: SortPreference] {
        guard
            let data = UserDefaults.standard.data(
                forKey: DefaultsKey.trackSortPreferencesByPlaylist)
        else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: SortPreference].self, from: data)) ?? [:]
    }

    private func saveSortPreferencesMap(_ map: [String: SortPreference]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.trackSortPreferencesByPlaylist)
    }

    private func migrateLegacySortPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: DefaultsKey.trackSortMigrationDone) { return }

        var preferences = loadSortPreferencesMap()
        if preferences["__all_songs__"] == nil {
            preferences["__all_songs__"] = SortPreference(
                key: trackSortKey.rawValue,
                order: trackSortOrder.rawValue
            )
            saveSortPreferencesMap(preferences)
        }

        defaults.set(true, forKey: DefaultsKey.trackSortMigrationDone)
    }

    private func invalidateDetailSelectionCacheIfNeeded(selectionIdentity: String) async {
        await PlaylistPageModelCacheService.shared.invalidate(selectionIdentity: selectionIdentity)

        guard currentSelectionIdentity == selectionIdentity else { return }
        refreshTrigger += 1
    }

    private func reconcileSelectionAfterLoad() {
        switch currentSelection {
        case .allSongs:
            break
        case .playlist(let id):
            guard playlists.contains(where: { $0.id == id }) else {
                currentSelection = .allSongs
                return
            }
        case .artist(let key):
            guard runtimeArtists.contains(where: { $0.key == key }) else {
                currentSelection = .allSongs
                return
            }
        case .album(let key):
            guard let album = runtimeAlbums.first(where: { $0.key == key }) else {
                currentSelection = .allSongs
                return
            }
            selectedAlbumName = album.name
        }
    }

    private func cleanupPlaybackAfterDeletingTracks(_ deletedTrackIDs: Set<UUID>) {
        guard !deletedTrackIDs.isEmpty else { return }
        guard let playerVM = SharedAppState.shared.playerVM else { return }

        if let currentTrackID = playerVM.currentTrack?.id, deletedTrackIDs.contains(currentTrackID) {
            playerVM.stop()
            return
        }

        let remainingQueue = playerVM.currentQueueTracks.filter { !deletedTrackIDs.contains($0.id) }
        guard remainingQueue.count != playerVM.currentQueueTracks.count else { return }

        if remainingQueue.isEmpty {
            playerVM.stop()
        } else {
            playerVM.updateQueueTracks(remainingQueue)
        }
    }

    private var currentSelectionIdentity: String {
        switch currentSelection {
        case .allSongs:
            return "allSongs"
        case .playlist(let id):
            return "playlist-\(id.uuidString)"
        case .artist(let key):
            return "artist-\(key)"
        case .album(let key):
            return "album-\(key)"
        }
    }

    private func sortTrack(_ lhs: Track, _ rhs: Track) -> Bool {
        let result: ComparisonResult

        switch trackSortKey {
        case .importedAt:
            result = compareDates(
                lhs.importedAt ?? lhs.addedAt,
                rhs.importedAt ?? rhs.addedAt
            )
        case .addedAt:
            if let playlistID = selectedPlaylistId {
                let left =
                    playlistItemAddedAtMap[playlistID]?[lhs.id]
                    ?? lhs.importedAt
                    ?? lhs.addedAt
                let right =
                    playlistItemAddedAtMap[playlistID]?[rhs.id]
                    ?? rhs.importedAt
                    ?? rhs.addedAt
                result = compareDates(left, right)
            } else {
                result = compareDates(lhs.addedAt, rhs.addedAt)
            }
        case .title:
            result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        case .artist:
            result = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
        case .duration:
            result = compareDoubles(lhs.duration, rhs.duration)
        case .playCount:
            result = compareInts(lhs.preferenceStats.playCount, rhs.preferenceStats.playCount)
        case .preference:
            result = compareDoubles(lhs.preferenceScore, rhs.preferenceScore)
        }

        if result == .orderedSame {
            let titleResult = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleResult != .orderedSame {
                return titleResult == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return trackSortOrder == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compareDates(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func compareDoubles(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
