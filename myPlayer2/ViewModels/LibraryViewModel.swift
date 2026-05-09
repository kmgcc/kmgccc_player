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

/// Sort key for the All Albums page.
/// Reuses the toolbar sort control via `LibraryViewModel.albumSortKey`.
enum AlbumSortKey: String, CaseIterable, Identifiable {
    case title
    case artist
    case trackCount
    case totalDuration
    case updatedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title:         return "标题"
        case .artist:        return "艺人"
        case .trackCount:    return "歌曲数"
        case .totalDuration: return "总时长"
        case .updatedAt:     return "最近更新"
        }
    }
}

/// Sort key for the All Artists page.
/// Reuses the toolbar sort control via `LibraryViewModel.artistSortKey`.
enum ArtistSortKey: String, CaseIterable, Identifiable {
    case name
    case trackCount
    case albumCount
    case totalDuration
    case updatedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:          return "名称"
        case .trackCount:    return "歌曲数"
        case .albumCount:    return "专辑数"
        case .totalDuration: return "总时长"
        case .updatedAt:     return "最近更新"
        }
    }
}

enum LibraryLoadState {
    case loading
    case loaded
}

enum LibraryLoadingPhase: Equatable {
    case idle
    case preparing
    case scanning
    case applying
    case rebuildingIndex
    case loaded
    case failed(String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isLoading: Bool {
        switch self {
        case .preparing, .scanning, .applying, .rebuildingIndex:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .preparing:
            return "正在准备资料库"
        case .scanning:
            return "正在扫描歌曲"
        case .applying:
            return "正在加载资料库"
        case .rebuildingIndex:
            return "正在建立索引"
        case .idle, .loaded:
            return ""
        case .failed:
            return "加载失败"
        }
    }
}

/// Explicit selection type for library content.
/// Replaces the ambiguous nil-based selection with explicit cases.
enum LibrarySelection: Hashable {
    case home
    case allSongs
    case allAlbums
    case allArtists
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

    /// Legacy data loading state (preserved for backward compatibility).
    var state: LibraryLoadState = .loading

    /// Granular loading phase for UI observation.
    var loadingPhase: LibraryLoadingPhase = .idle

    /// Last loading error message (nil when no error).
    private(set) var lastLoadingError: String?

    /// All playlists in the library.
    private(set) var playlists: [Playlist] = []

    /// Runtime-only artists derived from disk scan.
    private(set) var runtimeArtists: [ArtistSection] = []

    /// Runtime-only albums derived from disk scan.
    private(set) var runtimeAlbums: [AlbumSection] = []

    private(set) var artistEntries: [ArtistEntry] = []
    private(set) var albumEntries: [AlbumEntry] = []
    private var artistArtworkProviderTasks: Set<UUID> = []

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

    /// Currently selected album key (normalized logical album identity).
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
    var currentSelection: LibrarySelection = .home {
        didSet {
            if currentSelection != oldValue {
                searchResetTrigger += 1
            }
            // Sync legacy properties for backward compatibility during transition
            switch currentSelection {
            case .home, .allAlbums, .allArtists:
                selectedPlaylistId = nil
                selectedArtistKey = nil
                selectedAlbumKey = nil
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

    /// Sort key for the All Albums page. Persists globally (not per-context),
    /// since the All Albums page is a single shared view rather than a
    /// per-playlist drilldown. Sort order is shared with `trackSortOrder`.
    var albumSortKey: AlbumSortKey {
        didSet {
            if albumSortKey != oldValue {
                UserDefaults.standard.set(
                    albumSortKey.rawValue,
                    forKey: DefaultsKey.albumSortKey
                )
            }
        }
    }

    /// Sort key for the All Artists page. Persists globally (not per-context),
    /// since the All Artists page is a single shared view rather than a
    /// per-playlist drilldown. Sort order is shared with `trackSortOrder`.
    var artistSortKey: ArtistSortKey {
        didSet {
            if artistSortKey != oldValue {
                UserDefaults.standard.set(
                    artistSortKey.rawValue,
                    forKey: DefaultsKey.artistSortKey
                )
            }
        }
    }

    // MARK: - Dependencies

    private let repository: LibraryRepositoryProtocol
    private let metadataDetailCoordinator: MetadataDetailCoordinator
    private var importService: FileImportServiceProtocol?
    var currentTrackIDProvider: (() -> UUID?)?
    var onTracksDeleted: ((Set<UUID>) -> Void)?
    private var isApplyingSortPreference = false
    private var trackUpdateRevision = 0
    private var pendingRepositoryDeletionTrackIDs: Set<UUID> = []

    // MARK: - Loading Task Management

    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var currentTaskID: UUID?
    private var libraryLocationObserver: NSObjectProtocol?

    private struct SortPreference: Codable {
        let key: String
        let order: String
    }

    // MARK: - Initialization

    init(
        repository: LibraryRepositoryProtocol,
        libraryService _: LocalLibraryService? = nil,
        metadataDetailCoordinator: MetadataDetailCoordinator = .shared
    ) {
        self.repository = repository
        self.metadataDetailCoordinator = metadataDetailCoordinator
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
        self.albumSortKey =
            AlbumSortKey(
                rawValue: UserDefaults.standard.string(
                    forKey: DefaultsKey.albumSortKey
                ) ?? ""
            ) ?? .title
        self.artistSortKey =
            ArtistSortKey(
                rawValue: UserDefaults.standard.string(
                    forKey: DefaultsKey.artistSortKey
                ) ?? ""
            ) ?? .name
        migrateLegacySortPreferenceIfNeeded()
        applySortPreferenceForCurrentSelection()
        self.repository.setChangeHandler { [weak self] change in
            self?.handleRepositoryChange(change)
        }
        setupLibraryLocationObserver()
        print("[Lifecycle] LibraryViewModel.init, id: \(ObjectIdentifier(self))")
        Log.debug("LibraryViewModel initialized", category: .library)
    }

    deinit {
        // deinit runs nonisolated; schedule cleanup on MainActor.
        Task { @MainActor [weak self] in
            self?.cancelCurrentLoad()
            self?.removeLibraryLocationObserver()
        }
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
        case .tracksDeleted(let trackIDs):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let deletedTrackIDs = Set(trackIDs)
                if deletedTrackIDs.isSubset(of: self.pendingRepositoryDeletionTrackIDs) {
                    self.pendingRepositoryDeletionTrackIDs.subtract(deletedTrackIDs)
                    return
                }
                await self.applyRepositoryTrackDeletionBatch(trackIDs)
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
        runtimeArtists = await repository.fetchArtistSections()
        runtimeAlbums = await repository.fetchAlbumSections()
        artistEntries = await repository.fetchArtistEntries()
        albumEntries = await repository.fetchAlbumEntries()

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

    private func applyRepositoryTrackDeletionBatch(_ trackIDs: [UUID]) async {
        let deletedTrackIDs = Set(trackIDs)
        guard !deletedTrackIDs.isEmpty else { return }

        resetSelectionIfNeededAfterDeletingTracks(deletedTrackIDs)
        cleanupPlaybackAfterDeletingTracks(deletedTrackIDs)
        releaseTransientResources(for: allTracks.filter { deletedTrackIDs.contains($0.id) })
        removeDeletedTracksFromVisibleState(deletedTrackIDs)
        let invalidatedSelectionIdentities = selectionIdentitiesAffectedByDeletedTracks(
            deletedTrackIDs
        )
        await invalidateSelectionCaches(invalidatedSelectionIdentities)
        await syncVisibleStateFromRepository(
            reason: "repositoryDeleteEvent",
            invalidatedSelectionIdentities: invalidatedSelectionIdentities
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

    /// Legacy entry point: delegates to `reloadLibrary()`.
    func load() async {
        Log.debug("load() called", category: .library)
        await reloadLibrary()

        // Explicitly set default selection to All Songs after load completes
        // This ensures the main content area shows All Songs by default
        if currentSelection == .allSongs {
            // Trigger selection change to force content refresh even if already .allSongs
            currentSelection = .allSongs
        }
    }

    /// Unified reload entry point with phase tracking, cancellation, and stale-root guard.
    func reloadLibrary() async {
        cancelCurrentLoad()

        let capturedRoot = LocalLibraryPaths.libraryRootURL
        loadGeneration &+= 1
        let generation = loadGeneration
        let taskID = UUID()
        currentTaskID = taskID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReload(capturedRoot: capturedRoot, generation: generation)
        }
        loadTask = task

        await task.value
        if currentTaskID == taskID {
            loadTask = nil
            currentTaskID = nil
        }
    }

    private func performReload(capturedRoot: URL, generation: UInt64) async {
        guard loadGeneration == generation else { return }

        state = .loading
        loadingPhase = .preparing
        lastLoadingError = nil

        do {
            // Phase: preparing
            loadingPhase = .preparing
            try Task.checkCancellation()

            // Phase: scanning
            loadingPhase = .scanning
            try Task.checkCancellation()
            await repository.reloadFromLibrary()

            // Stale-root guard after repository reload
            guard LocalLibraryPaths.libraryRootURL == capturedRoot else {
                Log.info(
                    "[LibraryVM] Stale root after repository reload; discarding (generation=\(generation))",
                    category: .library
                )
                throw CancellationError()
            }
            guard loadGeneration == generation else {
                throw CancellationError()
            }
            try Task.checkCancellation()

            // Phase: applying
            loadingPhase = .applying
            try Task.checkCancellation()
            playlists = await repository.fetchPlaylists()
            allTracks = await repository.fetchTracks(in: nil)
            playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
            totalTrackCount = allTracks.count
            runtimeArtists = await repository.fetchArtistSections()
            runtimeAlbums = await repository.fetchAlbumSections()
            artistEntries = await repository.fetchArtistEntries()
            albumEntries = await repository.fetchAlbumEntries()
            reconcileSelectionAfterLoad()

            // Phase: rebuilding index
            loadingPhase = .rebuildingIndex
            try Task.checkCancellation()
            // Repository already rebuilt index during reloadFromLibrary();
            // this phase exists for UI observation.

            // Final guards before marking loaded
            guard loadGeneration == generation else {
                throw CancellationError()
            }
            guard LocalLibraryPaths.libraryRootURL == capturedRoot else {
                Log.info(
                    "[LibraryVM] Stale root before marking loaded; discarding (generation=\(generation))",
                    category: .library
                )
                throw CancellationError()
            }
            try Task.checkCancellation()

            loadingPhase = .loaded
            state = .loaded

            Log.info(
                "Library loaded: \(playlists.count) playlists, \(totalTrackCount) tracks",
                category: .library
            )

        } catch is CancellationError {
            Log.debug("[LibraryVM] Load cancelled (generation=\(generation))", category: .library)
            if loadGeneration == generation {
                loadingPhase = .idle
                // Do not set state = .loaded on cancellation.
            }
        } catch {
            Log.error("[LibraryVM] Load failed: \(error.localizedDescription)", category: .library)
            if loadGeneration == generation {
                lastLoadingError = error.localizedDescription
                loadingPhase = .failed(error.localizedDescription)
                state = .loaded
            }
        }
    }

    /// Refresh all data and trigger UI update.
    func refresh() async {
        await reloadLibrary()
        refreshTrigger += 1
        Log.debug("Refresh triggered, refreshTrigger=\(refreshTrigger)", category: .library)
    }

    /// Notify the UI that in-memory track-adjacent data changed without forcing a repository reload.
    func notifyTrackAuxiliaryDataChanged(trackIDs: [UUID]) {
        let uniqueTrackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueTrackIDs.isEmpty else { return }

        refreshTrigger += 1

        if let currentTrackID = currentTrackIDProvider?(),
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
            await syncVisibleStateFromRepositoryAfterImport()
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
            await syncVisibleStateFromRepositoryAfterImport()
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
        playlists.removeAll { $0.id == playlist.id }
        playlistItemAddedAtMap[playlist.id] = nil
        if currentSelection == .playlist(playlist.id) {
            currentSelection = .allSongs
        }
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "playlist-\(playlist.id.uuidString)"
        )
        refreshTrigger += 1
    }

    func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.addTracks(tracks, to: playlist)
        playlists = await repository.fetchPlaylists()
        playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "playlist-\(playlist.id.uuidString)"
        )
        refreshTrigger += 1
    }

    func removeTracksFromPlaylist(_ tracks: [Track], playlist: Playlist) async {
        await repository.removeTracks(tracks, from: playlist)
        playlists = await repository.fetchPlaylists()
        playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "playlist-\(playlist.id.uuidString)"
        )
        refreshTrigger += 1
    }

    // MARK: - Track Operations

    func deleteTrack(_ track: Track) async {
        await deleteTracks([track])
    }

    func deleteTracks(_ tracks: [Track]) async {
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let deletedTrackIDs = Set(uniqueTracks.map(\.id))
        guard !deletedTrackIDs.isEmpty else { return }

        let invalidatedSelectionIdentities = selectionIdentitiesAffectedByDeletedTracks(
            deletedTrackIDs
        )

        resetSelectionIfNeededAfterDeletingTracks(deletedTrackIDs)
        await importService?.cancelEnrichment(for: deletedTrackIDs)
        cleanupPlaybackAfterDeletingTracks(deletedTrackIDs)
        releaseTransientResources(for: uniqueTracks)
        removeDeletedTracksFromVisibleState(deletedTrackIDs)
        await invalidateSelectionCaches(invalidatedSelectionIdentities)
        refreshTrigger += 1

        pendingRepositoryDeletionTrackIDs.formUnion(deletedTrackIDs)
        await repository.deleteTracks(uniqueTracks)
        pendingRepositoryDeletionTrackIDs.subtract(deletedTrackIDs)
        await syncVisibleStateFromRepository(
            reason: "trackDelete",
            invalidatedSelectionIdentities: invalidatedSelectionIdentities
        )
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

    @discardableResult
    func fetchAndApplyMissingArtistMetadata(
        _ entry: ArtistEntry,
        minimumConfidence: Double = 0.70
    ) async -> Bool {
        let current = artistEntries.first(where: { $0.id == entry.id }) ?? entry
        do {
            let detail = try await metadataDetailCoordinator.fetchArtistDetail(
                name: current.displayName,
                singerMid: current.qqMusicSingerMid
            )
            guard let latest = artistEntries.first(where: { $0.id == entry.id }) else {
                Log.warning(
                    "[MetadataDetail] artist stale entry removed artist=\(current.displayName)",
                    category: .library
                )
                return false
            }
            let result = metadataDetailCoordinator.applyMissingFields(
                detail,
                to: latest,
                minimumConfidence: minimumConfidence
            )
            guard result.changed else {
                Log.info(
                    "[MetadataDetail] artist skipped artist=\(latest.displayName) confidence=\(String(format: "%.2f", detail.confidence))",
                    category: .library
                )
                return false
            }
            await saveArtistEntry(result.value)
            Log.info(
                "[MetadataDetail] artist applied source=\(detail.source.rawValue) confidence=\(String(format: "%.2f", detail.confidence)) artist=\(latest.displayName)",
                category: .library
            )
            return true
        } catch {
            Log.warning(
                "[MetadataDetail] artist failed artist=\(current.displayName) reason=\(error)",
                category: .library
            )
            return false
        }
    }

    @discardableResult
    func autofillArtistArtworkIfMissing(_ entry: ArtistEntry) async -> Bool {
        await applyArtistArtworkFromProviders(
            entry,
            allowReplacingExistingArtwork: false,
            reason: "auto-missing"
        )
    }

    @discardableResult
    func replaceArtistArtworkFromProviders(_ entry: ArtistEntry) async -> Bool {
        await applyArtistArtworkFromProviders(
            entry,
            allowReplacingExistingArtwork: true,
            reason: "manual-header"
        )
    }

    @discardableResult
    private func applyArtistArtworkFromProviders(
        _ entry: ArtistEntry,
        allowReplacingExistingArtwork: Bool,
        reason: String
    ) async -> Bool {
        guard allowReplacingExistingArtwork || !hasPersistedArtistArtwork(entry) else {
            return false
        }
        guard !artistArtworkProviderTasks.contains(entry.id) else {
            return false
        }

        artistArtworkProviderTasks.insert(entry.id)
        defer {
            artistArtworkProviderTasks.remove(entry.id)
        }

        do {
            let candidates = try await ArtistArtworkProviderCoordinator.shared.searchCandidates(
                artist: entry.displayName,
                limit: CoverLookupConfiguration.qqMusicCandidateLimit
            )
            guard let selected = CoverCandidateSorter.bestAutomaticCandidate(from: candidates) else {
                let topConfidence = candidates.map(\.confidence).max() ?? 0
                Log.info(
                    "[QQMusicCover] artist \(reason) skipped lowConfidence top=\(String(format: "%.2f", topConfidence)) artist=\(entry.displayName)",
                    category: .import
                )
                return false
            }

            guard var current = artistEntries.first(where: { $0.id == entry.id }) else {
                return false
            }
            guard allowReplacingExistingArtwork || !hasPersistedArtistArtwork(current) else {
                return false
            }

            current.artworkFileName = "artwork.png"
            current.artworkData = selected.imageData
            await saveArtistEntry(current)
            Log.info(
                "[QQMusicCover] artist \(reason) applied source=\(selected.source.shortLabel) confidence=\(String(format: "%.2f", selected.confidence)) artist=\(entry.displayName)",
                category: .import
            )
            return true
        } catch {
            Log.warning(
                "[QQMusicCover] artist \(reason) failed artist=\(entry.displayName) reason=\(error)",
                category: .import
            )
            return false
        }
    }

    private func hasPersistedArtistArtwork(_ entry: ArtistEntry) -> Bool {
        entry.artworkFileName != nil || entry.artworkData?.isEmpty == false
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

    @discardableResult
    func fetchAndApplyMissingAlbumMetadata(
        _ entry: AlbumEntry,
        minimumConfidence: Double = 0.70
    ) async -> Bool {
        let current = albumEntries.first(where: { $0.id == entry.id }) ?? entry
        do {
            let detail = try await metadataDetailCoordinator.fetchAlbumDetail(
                album: current.displayTitle,
                artist: current.primaryArtistDisplayName,
                albumMid: current.qqMusicAlbumMid
            )
            guard let latest = albumEntries.first(where: { $0.id == entry.id }) else {
                Log.warning(
                    "[MetadataDetail] album stale entry removed album=\(current.displayTitle)",
                    category: .library
                )
                return false
            }
            let result = metadataDetailCoordinator.applyMissingFields(
                detail,
                to: latest,
                minimumConfidence: minimumConfidence
            )
            guard result.changed else {
                Log.info(
                    "[MetadataDetail] album skipped album=\(latest.displayTitle) confidence=\(String(format: "%.2f", detail.confidence))",
                    category: .library
                )
                return false
            }
            await saveAlbumEntry(result.value)
            Log.info(
                "[MetadataDetail] album applied source=\(detail.source.rawValue) confidence=\(String(format: "%.2f", detail.confidence)) album=\(latest.displayTitle)",
                category: .library
            )
            return true
        } catch {
            Log.warning(
                "[MetadataDetail] album failed album=\(current.displayTitle) reason=\(error)",
                category: .library
            )
            return false
        }
    }

    func saveAlbumEdits(original: AlbumEntry, updated: AlbumEntry) async {
        let trimmedTitle = updated.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        var persisted = updated
        persisted.displayTitle = trimmedTitle
        persisted.canonicalKey = LibraryNormalization.retitledAlbumKey(
            existingKey: original.canonicalKey,
            newAlbumTitle: trimmedTitle
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

    func restoreDefaultAlbumArtwork(_ entry: AlbumEntry) async {
        let fallbackArtwork = allTracks.first {
            $0.albumGroupKey == entry.canonicalKey
        }?.artworkData

        var updated = entry
        updated.artworkFileName = nil
        updated.artworkData = fallbackArtwork
        updated.updatedAt = Date()

        await repository.updateAlbumEntry(updated)
        if let idx = albumEntries.firstIndex(where: { $0.id == updated.id }) {
            albumEntries[idx] = updated
        }

        await invalidateDetailSelectionCacheIfNeeded(
            selectionIdentity: "album-\(updated.canonicalKey)"
        )
        await refresh()
    }

    func deleteArtist(_ entry: ArtistEntry) async {
        let affectedTrackIDs = Set(
            allTracks
                .filter { LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist) }
                .map(\.id)
        )
        let affectedAlbumKeys = Set(
            allTracks
                .filter { LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist) }
                .map(\.albumGroupKey)
        )

        if currentSelection == .artist(entry.canonicalName) {
            currentSelection = .allSongs
        } else if case .album(let key) = currentSelection, affectedAlbumKeys.contains(key) {
            currentSelection = .allSongs
        }

        cleanupPlaybackAfterDeletingTracks(affectedTrackIDs)
        await importService?.cancelEnrichment(for: affectedTrackIDs)
        releaseTransientResources(for: allTracks.filter { affectedTrackIDs.contains($0.id) })
        removeDeletedTracksFromVisibleState(affectedTrackIDs)
        let invalidatedSelectionIdentities = selectionIdentitiesAffectedByDeletedTracks(
            affectedTrackIDs
        )
        await invalidateSelectionCaches(invalidatedSelectionIdentities)
        refreshTrigger += 1

        pendingRepositoryDeletionTrackIDs.formUnion(affectedTrackIDs)
        await repository.deleteArtist(entry)
        pendingRepositoryDeletionTrackIDs.subtract(affectedTrackIDs)
        await syncVisibleStateFromRepository(
            reason: "artistDelete",
            invalidatedSelectionIdentities: invalidatedSelectionIdentities
        )
    }

    func deleteAlbum(_ entry: AlbumEntry) async {
        let affectedTrackIDs = Set(
            allTracks
                .filter { $0.albumGroupKey == entry.canonicalKey }
                .map(\.id)
        )

        if currentSelection == .album(entry.canonicalKey) {
            currentSelection = .allSongs
        }

        cleanupPlaybackAfterDeletingTracks(affectedTrackIDs)
        await importService?.cancelEnrichment(for: affectedTrackIDs)
        releaseTransientResources(for: allTracks.filter { affectedTrackIDs.contains($0.id) })
        removeDeletedTracksFromVisibleState(affectedTrackIDs)
        let invalidatedSelectionIdentities = selectionIdentitiesAffectedByDeletedTracks(
            affectedTrackIDs
        )
        await invalidateSelectionCaches(invalidatedSelectionIdentities)
        refreshTrigger += 1

        pendingRepositoryDeletionTrackIDs.formUnion(affectedTrackIDs)
        await repository.deleteAlbum(entry)
        pendingRepositoryDeletionTrackIDs.subtract(affectedTrackIDs)
        await syncVisibleStateFromRepository(
            reason: "albumDelete",
            invalidatedSelectionIdentities: invalidatedSelectionIdentities
        )
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
    }

    @discardableResult
    func fetchAndApplyMissingTrackMetadata(
        _ track: Track,
        minimumConfidence: Double = 0.70
    ) async -> Bool {
        guard let current = allTracks.first(where: { $0.id == track.id }) else {
            Log.warning(
                "[MetadataDetail] track stale track=\(track.title)",
                category: .library
            )
            return false
        }
        do {
            let duration = current.duration.isFinite && current.duration > 0
                ? Int(current.duration.rounded())
                : nil
            let detail = try await metadataDetailCoordinator.fetchTrackDetail(
                title: current.title,
                artist: current.artist,
                album: current.album,
                songMid: current.qqMusicSongMid,
                duration: duration
            )
            let changed = metadataDetailCoordinator.applyMissingFields(
                detail,
                to: current,
                minimumConfidence: minimumConfidence
            )
            guard changed else {
                Log.info(
                    "[MetadataDetail] track skipped track=\(current.title) confidence=\(String(format: "%.2f", detail.confidence))",
                    category: .library
                )
                return false
            }

            await saveTrackEdits(current, mode: .metaOnly, reason: "metadataDetailFill")
            Log.info(
                "[MetadataDetail] track applied source=\(detail.source.rawValue) confidence=\(String(format: "%.2f", detail.confidence)) track=\(current.title)",
                category: .library
            )
            return true
        } catch {
            Log.warning(
                "[MetadataDetail] track failed track=\(current.title) reason=\(error)",
                category: .library
            )
            return false
        }
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

    // MARK: - Library Location Change

    private func setupLibraryLocationObserver() {
        libraryLocationObserver = NotificationCenter.default.addObserver(
            forName: .libraryLocationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLibraryLocationChanged()
            }
        }
    }

    private func removeLibraryLocationObserver() {
        if let observer = libraryLocationObserver {
            NotificationCenter.default.removeObserver(observer)
            libraryLocationObserver = nil
        }
    }

    private func handleLibraryLocationChanged() {
        Log.info(
            "[LibraryVM] Library location changed, cancelling current load and resetting",
            category: .library
        )
        cancelCurrentLoad()
        resetLibraryData()
        Task { @MainActor [weak self] in
            await self?.reloadLibrary()
        }
    }

    private func cancelCurrentLoad() {
        loadTask?.cancel()
        loadTask = nil
        currentTaskID = nil
    }

    private func resetLibraryData() {
        playlists = []
        allTracks = []
        playlistItemAddedAtMap = [:]
        runtimeArtists = []
        runtimeAlbums = []
        artistEntries = []
        albumEntries = []
        totalTrackCount = 0
        currentSelection = .allSongs
        loadingPhase = .idle
        // Do not touch `state` here; reloadLibrary() manages it.
    }

    // MARK: - Private Helpers

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }

    private func syncVisibleStateFromRepositoryAfterImport() async {
        await syncVisibleStateFromRepository(reason: "import", invalidatedSelectionIdentities: [])
    }

    private func syncVisibleStateFromRepository(
        reason: String,
        invalidatedSelectionIdentities: Set<String>
    ) async {
        playlists = await repository.fetchPlaylists()
        allTracks = await repository.fetchTracks(in: nil)
        playlistItemAddedAtMap = await repository.fetchPlaylistItemAddedAtMap()
        totalTrackCount = allTracks.count
        runtimeArtists = await repository.fetchArtistSections()
        runtimeAlbums = await repository.fetchAlbumSections()
        artistEntries = await repository.fetchArtistEntries()
        albumEntries = await repository.fetchAlbumEntries()
        reconcileSelectionAfterLoad()
        await invalidateSelectionCaches(invalidatedSelectionIdentities)
        refreshTrigger += 1
        Log.info(
            "Synced visible library state without full disk reload reason=\(reason), totalTracks=\(totalTrackCount)",
            category: .library
        )
    }

    // MARK: - Sorting Helpers

    private enum DefaultsKey {
        static let trackSortKey = "trackSortKey"
        static let trackSortOrder = "trackSortOrder"
        static let trackSortPreferencesByPlaylist = "trackSortPreferencesByPlaylist"
        static let trackSortMigrationDone = "trackSortMigrationDone"
        static let albumSortKey = "albumSortKey"
        static let artistSortKey = "artistSortKey"
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
        // Track sort preferences (key + order) only persist for selections
        // backed by a track list. Album / artist / home pages have their
        // own dedicated sort keys and reuse `trackSortOrder` in-memory only,
        // so they should not contaminate the per-playlist preference map.
        switch currentSelection {
        case .home, .allAlbums, .allArtists:
            return
        default:
            break
        }
        var preferences = loadSortPreferencesMap()
        preferences[sortContextKey] = SortPreference(
            key: trackSortKey.rawValue,
            order: trackSortOrder.rawValue
        )
        saveSortPreferencesMap(preferences)
    }

    private func applySortPreferenceForCurrentSelection() {
        // Mirror the persistence guard: home / all-albums / all-artists
        // do not own a track preference entry, so there's nothing to apply.
        switch currentSelection {
        case .home, .allAlbums, .allArtists:
            return
        default:
            break
        }
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

    private func invalidateSelectionCaches(_ selectionIdentities: Set<String>) async {
        for selectionIdentity in selectionIdentities {
            await PlaylistPageModelCacheService.shared.invalidate(selectionIdentity: selectionIdentity)
        }
    }

    private func selectionIdentitiesAffectedByDeletedTracks(_ deletedTrackIDs: Set<UUID>) -> Set<String> {
        guard !deletedTrackIDs.isEmpty else { return [] }

        var identities: Set<String> = ["allSongs"]
        for playlist in playlists where playlist.tracks.contains(where: { deletedTrackIDs.contains($0.id) }) {
            identities.insert("playlist-\(playlist.id.uuidString)")
        }
        for track in allTracks where deletedTrackIDs.contains(track.id) {
            for artistKey in LibraryNormalization.artistCanonicalNames(track.artist) {
                identities.insert("artist-\(artistKey)")
            }
            identities.insert("album-\(track.albumGroupKey)")
        }
        return identities
    }

    private func resetSelectionIfNeededAfterDeletingTracks(_ deletedTrackIDs: Set<UUID>) {
        guard !deletedTrackIDs.isEmpty else { return }

        switch currentSelection {
        case .home, .allSongs, .allAlbums, .allArtists:
            return
        case .playlist:
            return
        case .artist(let key):
            let hasRemaining = allTracks.contains {
                !deletedTrackIDs.contains($0.id)
                    && LibraryNormalization.containsArtist(key, in: $0.artist)
            }
            if !hasRemaining {
                currentSelection = .allSongs
            }
        case .album(let key):
            let hasRemaining = allTracks.contains {
                !deletedTrackIDs.contains($0.id) && $0.albumGroupKey == key
            }
            if !hasRemaining {
                currentSelection = .allSongs
            }
        }
    }

    private func removeDeletedTracksFromVisibleState(_ deletedTrackIDs: Set<UUID>) {
        guard !deletedTrackIDs.isEmpty else { return }

        allTracks.removeAll { deletedTrackIDs.contains($0.id) }
        for playlist in playlists {
            playlist.tracks.removeAll { deletedTrackIDs.contains($0.id) }
            guard var addedAt = playlistItemAddedAtMap[playlist.id] else { continue }
            for trackID in deletedTrackIDs {
                addedAt[trackID] = nil
            }
            playlistItemAddedAtMap[playlist.id] = addedAt
        }
        totalTrackCount = allTracks.count
    }

    private func releaseTransientResources(for tracks: [Track]) {
        for track in tracks {
            track.releaseTransientMediaResources()
        }
    }

    private func reconcileSelectionAfterLoad() {
        switch currentSelection {
        case .home, .allSongs, .allAlbums, .allArtists:
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
        onTracksDeleted?(deletedTrackIDs)
    }

    private var currentSelectionIdentity: String {
        switch currentSelection {
        case .home:
            return "home"
        case .allSongs:
            return "allSongs"
        case .allAlbums:
            return "allAlbums"
        case .allArtists:
            return "allArtists"
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
