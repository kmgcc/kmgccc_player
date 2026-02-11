//
//  LibraryViewModel.swift
//  myPlayer2
//
//  TrueMusic - Library ViewModel
//  Manages playlists for the UI.
//
//  NOTE: Track display is handled by @Query in PlaylistDetailView.
//  This ViewModel only manages playlist selection and import triggering.
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

/// Observable ViewModel for library content.
/// Manages playlists and selected playlist state.
/// Tracks are displayed via @Query in PlaylistDetailView (方案 A).
@Observable
@MainActor
final class LibraryViewModel {

    // MARK: - Published State

    /// All playlists in the library.
    private(set) var playlists: [Playlist] = []

    /// Currently selected playlist (nil = All Songs).
    /// Published so UI can react to changes.
    var selectedPlaylistId: UUID? {
        didSet {
            applySortPreferenceForCurrentSelection()
        }
    }

    /// Whether data is loading.
    private(set) var isLoading: Bool = false

    /// Total track count in library (for display).
    private(set) var totalTrackCount: Int = 0

    /// Trigger for UI refresh (increment to force @Query update).
    private(set) var refreshTrigger: Int = 0

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
    private let libraryService: LocalLibraryService
    private var isApplyingSortPreference = false

    private struct SortPreference: Codable {
        let key: String
        let order: String
    }

    // MARK: - Initialization

    init(repository: LibraryRepositoryProtocol, libraryService: LocalLibraryService? = nil) {
        self.repository = repository
        self.libraryService = libraryService ?? LocalLibraryService.shared
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
        isLoading = true
        defer { isLoading = false }

        await libraryService.bootstrapIfNeeded(repository: repository)
        playlists = await repository.fetchPlaylists()
        totalTrackCount = await repository.totalTrackCount()

        print("📚 Loaded \(playlists.count) playlists, \(totalTrackCount) total tracks")
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

        // Always refresh after import attempt
        await refresh()
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
        selectedPlaylistId = playlist?.id
        if let id = playlist?.id {
            UserDefaults.standard.set(id.uuidString, forKey: "lastSelectedPlaylistId")
        }
        print("📚 Selected playlist: \(playlist?.name ?? "All Songs")")
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        await repository.renamePlaylist(playlist, name: name)
        playlists = await repository.fetchPlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) async {
        await repository.deletePlaylist(playlist)
        if selectedPlaylistId == playlist.id {
            selectedPlaylistId = nil
        }
        playlists = await repository.fetchPlaylists()
    }

    func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.addTracks(tracks, to: playlist)
        // Refresh handled by caller or automatic if needed
    }

    func removeTracksFromPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.removeTracks(tracks, from: playlist)
        refreshTrigger += 1
    }

    // MARK: - Track Operations

    func deleteTrack(_ track: Track) async {
        await repository.deleteTrack(track)
        totalTrackCount = await repository.totalTrackCount()
        refreshTrigger += 1
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
    }

    // MARK: - Display Helpers

    /// Title for the current view.
    var currentTitle: String {
        selectedPlaylist?.name ?? NSLocalizedString("library.all_songs", comment: "")
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
        selectedPlaylistId?.uuidString ?? "__all_songs__"
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
            let data = UserDefaults.standard.data(forKey: DefaultsKey.trackSortPreferencesByPlaylist)
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
            result = compareDates(lhs.addedAt, rhs.addedAt)
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

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private func compareDoubles(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
