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

enum TrackSortKey: String, CaseIterable, Identifiable {
    case importedAt
    case addedAt
    case title
    case artist
    case duration

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

/// Observable ViewModel for library content.
/// Manages playlists and selected playlist state.
@Observable
@MainActor
final class LibraryViewModel {

    // MARK: - Published State

    /// Data loading state.
    var state: LibraryLoadState = .loading

    /// All playlists in the library.
    private(set) var playlists: [Playlist] = []

    /// Runtime-only artists derived from disk scan.
    private(set) var runtimeArtists: [ArtistSection] = []

    /// Runtime-only albums derived from disk scan.
    private(set) var runtimeAlbums: [AlbumSection] = []

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

    /// Whether data is loading.
    var isLoading: Bool { state == .loading }

    /// Total track count in library (for display).
    private(set) var totalTrackCount: Int = 0

    /// Trigger for UI refresh.
    private(set) var refreshTrigger: Int = 0

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
        print("📚 LibraryViewModel initialized")
    }

    /// Set the import service (called after initialization).
    func setImportService(_ service: FileImportServiceProtocol) {
        self.importService = service
        print("📚 Import service set")
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
        print("📚 load() called")
        state = .loading

        await repository.reloadFromLibrary()
        playlists = await repository.fetchPlaylists()
        allTracks = await repository.fetchTracks(in: nil)
        playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
        totalTrackCount = allTracks.count
        runtimeArtists = await repository.fetchArtistSections()
        runtimeAlbums = await repository.fetchAlbumSections()

        print(
            "📚 Loaded \(playlists.count) playlists, \(totalTrackCount) total tracks, \(runtimeArtists.count) artists, \(runtimeAlbums.count) albums"
        )

        state = .loaded
    }

    /// Refresh all data and trigger UI update.
    func refresh() async {
        await load()
        refreshTrigger += 1
        print("📚 Refresh triggered, refreshTrigger=\(refreshTrigger)")
    }

    // MARK: - Import (Per-Playlist)

    /// Import music files to the currently selected playlist.
    /// If no playlist is selected, imports to the most recently selected playlist (if any),
    /// otherwise the first available playlist. Only creates a playlist if none exist.
    func importToCurrentPlaylist() async {
        print("📥 importToCurrentPlaylist() called")
        print("   ↳ selectedPlaylistId = \(selectedPlaylistId?.uuidString ?? "nil")")
        print("   ↳ importService = \(importService != nil ? "available" : "nil")")

        guard let service = importService else {
            print("⚠️ Import service not available")
            return
        }

        // Resolve target playlist
        let targetPlaylist: Playlist
        if let selected = selectedPlaylist {
            print("   ↳ Using existing playlist: '\(selected.name)'")
            targetPlaylist = selected
        } else {
            if playlists.isEmpty {
                print("   ↳ No playlists exist, creating one for import...")
                targetPlaylist = await repository.createPlaylist(
                    name: String(
                        format: NSLocalizedString("library.imported_playlist_name", comment: ""),
                        formattedDate))
                playlists = await repository.fetchPlaylists()
                selectedPlaylistId = targetPlaylist.id
                print("   ↳ Created playlist: '\(targetPlaylist.name)' (id=\(targetPlaylist.id))")
            } else if let lastId = UserDefaults.standard.string(forKey: "lastSelectedPlaylistId"),
                let uuid = UUID(uuidString: lastId),
                let last = playlists.first(where: { $0.id == uuid })
            {
                print("   ↳ No playlist selected, using last selected: '\(last.name)'")
                targetPlaylist = last
                selectedPlaylistId = last.id
            } else {
                let fallback = playlists[0]
                print("   ↳ No playlist selected, using first playlist: '\(fallback.name)'")
                targetPlaylist = fallback
                selectedPlaylistId = fallback.id
            }
        }

        // Perform import
        print("📥 Calling pickAndImport...")
        let count = await service.pickAndImport(to: targetPlaylist)
        print("📥 pickAndImport returned: \(count) tracks imported")

        // Only refresh if tracks were actually imported
        if count > 0 {
            await refresh()
        }
    }

    /// Import to a specific playlist.
    func importToPlaylist(_ playlist: Playlist) async {
        guard let service = importService else {
            print("⚠️ Import service not available")
            return
        }

        let count = await service.pickAndImport(to: playlist)

        if count > 0 {
            await refresh()
        }
    }

    // MARK: - Playlist Operations

    /// Create a new playlist and select it.
    func createPlaylist(name: String) async -> Playlist {
        print("📚 createPlaylist: '\(name)'")
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
        print("📚 Selected playlist: \(playlist?.name ?? "All Songs")")
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

    func deletePlaylist(_ playlist: Playlist) async {
        await repository.deletePlaylist(playlist)
        if selectedPlaylistId == playlist.id {
            selectedPlaylistId = nil
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

    /// Update track availability after bookmark resolution.
    func updateTrackAvailability(
        _ track: Track, availability: TrackAvailability, refreshedBookmark: Data?
    ) async {
        track.availability = availability
        if let newBookmark = refreshedBookmark {
            track.fileBookmarkData = newBookmark
        }
        await repository.updateTrack(track)
        await refresh()
    }

    func saveTrackEdits(_ track: Track) async {
        await repository.updateTrack(track)
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
}
