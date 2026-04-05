# Library Detail Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent ArtistEntry/AlbumEntry disk metadata, a post-song-change sync pipeline, and a shared `LibraryDetailHeaderView` with scrolling blurred artwork background injected into the existing `PlaylistDetailView`.

**Architecture:** Disk-first JSON sidecars (UUID-keyed directories) for artist/album metadata, mirroring the existing Track/Playlist pattern. A `LibraryMetadataSync` service merges derived groupings with persistent entries after every library load. `LibraryDetailHeaderView` is the single header component for all selection types, injected as the first item in `PlaylistDetailView`'s existing `LazyVStack` with a `BlurredArtworkBackgroundView` behind it. `PlaylistDetailView` is extended, not duplicated.

**Tech Stack:** Swift, SwiftUI, AppKit (NSImage), CoreGraphics (pixel recoloring), `ArtworkColorExtractor` (existing), Codable JSON sidecars.

---

## File Map

**New files:**
- `myPlayer2/Models/ArtistEntry.swift` — in-memory artist metadata struct (loaded from sidecar + derived stats)
- `myPlayer2/Models/AlbumEntry.swift` — in-memory album metadata struct
- `myPlayer2/Services/Library/LibraryMetadataSync.swift` — sync derived groupings ↔ persistent entries
- `myPlayer2/Services/Library/PlaylistArtworkGenerator.swift` — deterministic playlist cover generation actor
- `myPlayer2/Views/Library/DetailHeaderConfig.swift` — `DetailHeaderConfig` enum + supporting data structs
- `myPlayer2/Views/Library/BlurredArtworkBackgroundView.swift` — scrolling blurred artwork background
- `myPlayer2/Views/Library/LibraryDetailHeaderView.swift` — shared header component

**Modified files:**
- `myPlayer2/Utilities/LocalLibraryPaths.swift` — add artist/album path helpers
- `myPlayer2/Services/Library/LocalLibraryService.swift` — add `ArtistSidecar`/`AlbumSidecar` structs + read/write; add `description` to `PlaylistSidecar`; extend `ensureLibraryFolders()`
- `myPlayer2/Models/Playlist.swift` — add `description: String`
- `myPlayer2/Repositories/LibraryRepositoryProtocol.swift` — new methods for artist/album entries + playlist description
- `myPlayer2/Repositories/SwiftDataLibraryRepository.swift` — implement new protocol methods; call sync after reload
- `myPlayer2/Repositories/StubLibraryRepository.swift` — stub new protocol methods
- `myPlayer2/ViewModels/LibraryViewModel.swift` — add `artistEntries`, `albumEntries`, save methods
- `myPlayer2/Views/Library/PlaylistDetailView.swift` — inject header row + background; route non-allSongs to detail scroll view

---

## Task 1: Path helpers and folder setup

**Files:**
- Modify: `myPlayer2/Utilities/LocalLibraryPaths.swift`
- Modify: `myPlayer2/Services/Library/LocalLibraryService.swift` (only `ensureLibraryFolders`)

- [ ] **Step 1: Add path helpers to `LocalLibraryPaths.swift`**

At the end of the enum body, after `libraryURL(from:)`, add:

```swift
    static var artistsRootURL: URL {
        libraryRootURL.appendingPathComponent("Artists", isDirectory: true)
    }

    static var albumsRootURL: URL {
        libraryRootURL.appendingPathComponent("Albums", isDirectory: true)
    }

    static func artistFolderURL(for id: UUID) -> URL {
        artistsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func albumFolderURL(for id: UUID) -> URL {
        albumsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func artistMetaURL(for id: UUID) -> URL {
        artistFolderURL(for: id).appendingPathComponent("meta.json")
    }

    static func albumMetaURL(for id: UUID) -> URL {
        albumFolderURL(for: id).appendingPathComponent("meta.json")
    }
```

- [ ] **Step 2: Extend `ensureLibraryFolders()` in `LocalLibraryService.swift`**

Inside the existing `do { ... }` block in `ensureLibraryFolders()`, after the `playlistsRootURL` creation, add:

```swift
            try fileManager.createDirectory(
                at: LocalLibraryPaths.artistsRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.albumsRootURL,
                withIntermediateDirectories: true
            )
```

- [ ] **Step 3: Build and verify**

```bash
cd /Users/kmg/Documents/vscode/player/myPlayer2
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add myPlayer2/Utilities/LocalLibraryPaths.swift myPlayer2/Services/Library/LocalLibraryService.swift
git commit -m "feat(library): add artist/album path helpers and ensure folders"
```

---

## Task 2: ArtistSidecar, AlbumSidecar, and sidecar I/O in LocalLibraryService

**Files:**
- Modify: `myPlayer2/Services/Library/LocalLibraryService.swift`

- [ ] **Step 1: Add `ArtistSidecar` struct**

After the `PlaylistItemSidecar` struct (around line 213), add:

```swift
struct ArtistSidecar: Codable {
    var schemaVersion: Int
    var id: UUID
    var canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalName: String,
        displayName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.artworkFileName = artworkFileName
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AlbumSidecar: Codable {
    var schemaVersion: Int
    var id: UUID
    var canonicalKey: String
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var artworkFileName: String?
    var description: String?
    var year: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        year: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.artworkFileName = artworkFileName
        self.description = description
        self.year = year
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 2: Add `description` to `PlaylistSidecar`**

In `PlaylistSidecar`:
1. Add `let description: String?` as a stored property after `let legacyTrackIDs: [UUID]?`.
2. Add `case description` to `CodingKeys`.
3. In `init(schemaVersion:id:name:createdAt:items:)` add `description: String? = nil` parameter and `self.description = description`.
4. In `init(from decoder:)` add: `description = try c.decodeIfPresent(String.self, forKey: .description)`.
5. In `encode(to:)` add: `try c.encodeIfPresent(description, forKey: .description)`.

The `legacyTrackIDs` line already sets `self.legacyTrackIDs = nil` in the memberwise init — keep that, just add description.

- [ ] **Step 3: Add read/write methods to `LocalLibraryService`**

Add a new `// MARK: - Artist/Album Sidecars` section before `// MARK: - Bootstrap / Sync`:

```swift
    // MARK: - Artist/Album Sidecars

    func loadArtistSidecarsFromDisk() -> [(sidecar: ArtistSidecar, folderURL: URL)] {
        let root = LocalLibraryPaths.artistsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(ArtistSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }

    func loadAlbumSidecarsFromDisk() -> [(sidecar: AlbumSidecar, folderURL: URL)] {
        let root = LocalLibraryPaths.albumsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(AlbumSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }

    func writeArtistSidecar(_ sidecar: ArtistSidecar, artworkData: Data?) {
        let folder = LocalLibraryPaths.artistFolderURL(for: sidecar.id)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let metaURL = LocalLibraryPaths.artistMetaURL(for: sidecar.id)
            let data = try encoder.encode(sidecar)
            try data.write(to: metaURL, options: .atomic)
            if let artworkData, let fileName = sidecar.artworkFileName {
                let artworkURL = folder.appendingPathComponent(fileName)
                try artworkData.write(to: artworkURL, options: .atomic)
            }
        } catch {
            Log.error("Failed to write artist sidecar '\(sidecar.displayName)': \(error)", category: .library)
        }
    }

    func writeAlbumSidecar(_ sidecar: AlbumSidecar, artworkData: Data?) {
        let folder = LocalLibraryPaths.albumFolderURL(for: sidecar.id)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let metaURL = LocalLibraryPaths.albumMetaURL(for: sidecar.id)
            let data = try encoder.encode(sidecar)
            try data.write(to: metaURL, options: .atomic)
            if let artworkData, let fileName = sidecar.artworkFileName {
                let artworkURL = folder.appendingPathComponent(fileName)
                try artworkData.write(to: artworkURL, options: .atomic)
            }
        } catch {
            Log.error("Failed to write album sidecar '\(sidecar.displayTitle)': \(error)", category: .library)
        }
    }

    func deleteArtistEntry(id: UUID) {
        let folder = LocalLibraryPaths.artistFolderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try? fileManager.removeItem(at: folder)
    }

    func deleteAlbumEntry(id: UUID) {
        let folder = LocalLibraryPaths.albumFolderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try? fileManager.removeItem(at: folder)
    }
```

- [ ] **Step 4: Update `writePlaylist()` to include description**

In `writePlaylist(_:itemAddedAt:)`, update the `PlaylistSidecar` init to pass `description`:

```swift
        let sidecar = PlaylistSidecar(
            id: playlist.id,
            name: playlist.name,
            description: playlist.description.isEmpty ? nil : playlist.description,
            createdAt: playlist.createdAt,
            items: items
        )
```

- [ ] **Step 5: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add myPlayer2/Services/Library/LocalLibraryService.swift
git commit -m "feat(library): add ArtistSidecar/AlbumSidecar structs and sidecar I/O methods"
```

---

## Task 3: Playlist description field and ArtistEntry/AlbumEntry models

**Files:**
- Modify: `myPlayer2/Models/Playlist.swift`
- Create: `myPlayer2/Models/ArtistEntry.swift`
- Create: `myPlayer2/Models/AlbumEntry.swift`

- [ ] **Step 1: Add `description` to `Playlist`**

In `Playlist.swift`, add after `var name: String`:

```swift
    var description: String = ""
```

Update `init` to accept and set it (add `description: String = ""` parameter and `self.description = description`).

- [ ] **Step 2: Create `ArtistEntry.swift`**

Create `myPlayer2/Models/ArtistEntry.swift`:

```swift
//
//  ArtistEntry.swift
//  myPlayer2
//
//  In-memory artist metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct ArtistEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    let canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String
    var artworkData: Data?      // loaded from artwork file if artworkFileName is set
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var albumCount: Int
    var totalDuration: Double
    var isOrphaned: Bool        // runtime-only: true if no matching songs exist
}
```

- [ ] **Step 3: Create `AlbumEntry.swift`**

Create `myPlayer2/Models/AlbumEntry.swift`:

```swift
//
//  AlbumEntry.swift
//  myPlayer2
//
//  In-memory album metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct AlbumEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    let canonicalKey: String        // normalized album•artist key
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var primaryArtistDisplayName: String
    var artworkFileName: String?
    var description: String
    var year: Int?
    var artworkData: Data?          // user-set artwork or first track's artwork (not persisted in sidecar)
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var totalDuration: Double
    var isOrphaned: Bool            // runtime-only: true if no matching songs exist
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add myPlayer2/Models/Playlist.swift myPlayer2/Models/ArtistEntry.swift myPlayer2/Models/AlbumEntry.swift
git commit -m "feat(models): add Playlist.description, ArtistEntry, AlbumEntry"
```

---

## Task 4: LibraryMetadataSync service

**Files:**
- Create: `myPlayer2/Services/Library/LibraryMetadataSync.swift`

- [ ] **Step 1: Create `LibraryMetadataSync.swift`**

```swift
//
//  LibraryMetadataSync.swift
//  myPlayer2
//
//  Merges song-derived artist/album groupings with persistent disk metadata entries.
//  Called after every library reload. Preserves user-edited fields across syncs.
//

import Foundation

@MainActor
final class LibraryMetadataSync {

    func sync(
        derivedArtists: [ArtistSection],
        derivedAlbums: [AlbumSection],
        allTracks: [Track],
        libraryService: LocalLibraryService
    ) -> (artists: [ArtistEntry], albums: [AlbumEntry]) {
        let artists = syncArtists(
            derived: derivedArtists,
            allTracks: allTracks,
            libraryService: libraryService
        )
        let albums = syncAlbums(
            derived: derivedAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        return (artists, albums)
    }

    // MARK: - Artist Sync

    private func syncArtists(
        derived: [ArtistSection],
        allTracks: [Track],
        libraryService: LocalLibraryService
    ) -> [ArtistEntry] {
        let loaded = libraryService.loadArtistSidecarsFromDisk()
        var existing: [String: (sidecar: ArtistSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.sidecar.canonicalName, $0) })
        let now = Date()

        // Compute album counts per artist canonical key
        var albumCountByArtist: [String: Set<String>] = [:]
        for track in allTracks {
            let artistKey = LibraryNormalization.normalizeArtist(track.artist)
            let albumKey = LibraryNormalization.normalizedAlbumKey(
                album: track.album, artist: track.artist)
            albumCountByArtist[artistKey, default: []].insert(albumKey)
        }

        var result: [ArtistEntry] = []

        for section in derived {
            let totalDuration = allTracks
                .filter { LibraryNormalization.normalizeArtist($0.artist) == section.key }
                .reduce(0) { $0 + $1.duration }
            let albumCount = albumCountByArtist[section.key]?.count ?? 0

            if let (sidecar, folderURL) = existing[section.key] {
                existing.removeValue(forKey: section.key)
                // Preserve user edits; do NOT write sidecar (updatedAt unchanged)
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(ArtistEntry(
                    id: sidecar.id,
                    canonicalName: sidecar.canonicalName,
                    displayName: sidecar.displayName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: section.trackCount,
                    albumCount: albumCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            } else {
                // New artist: create sidecar on disk
                let newID = UUID()
                let newSidecar = ArtistSidecar(
                    id: newID,
                    canonicalName: section.key,
                    displayName: section.name,
                    createdAt: now,
                    updatedAt: now
                )
                libraryService.writeArtistSidecar(newSidecar, artworkData: nil)
                result.append(ArtistEntry(
                    id: newID,
                    canonicalName: section.key,
                    displayName: section.name,
                    artworkFileName: nil,
                    description: "",
                    artworkData: nil,
                    createdAt: now,
                    updatedAt: now,
                    trackCount: section.trackCount,
                    albumCount: albumCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            }
        }

        // Handle orphans: keep if user-edited content exists, otherwise delete
        for (_, (sidecar, folderURL)) in existing {
            let hasUserContent =
                !(sidecar.description ?? "").isEmpty || sidecar.artworkFileName != nil
            if hasUserContent {
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(ArtistEntry(
                    id: sidecar.id,
                    canonicalName: sidecar.canonicalName,
                    displayName: sidecar.displayName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    albumCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                try? FileManager.default.removeItem(at: folderURL)
            }
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Album Sync

    private func syncAlbums(
        derived: [AlbumSection],
        allTracks: [Track],
        libraryService: LocalLibraryService
    ) -> [AlbumEntry] {
        let loaded = libraryService.loadAlbumSidecarsFromDisk()
        var existing: [String: (sidecar: AlbumSidecar, folderURL: URL)] =
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.sidecar.canonicalKey, $0) })
        let now = Date()

        var result: [AlbumEntry] = []

        for section in derived {
            let matchingTracks = allTracks.filter {
                LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                    == section.key
            }
            let totalDuration = matchingTracks.reduce(0) { $0 + $1.duration }
            let firstArtwork = matchingTracks.first?.artworkData
            let primaryArtistKey = LibraryNormalization.normalizeArtist(section.artistName)

            if let (sidecar, folderURL) = existing[section.key] {
                existing.removeValue(forKey: section.key)
                // User-set artwork takes priority; fall back to first track
                let artworkData: Data?
                if let fileName = sidecar.artworkFileName {
                    artworkData = try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                } else {
                    artworkData = firstArtwork
                }
                result.append(AlbumEntry(
                    id: sidecar.id,
                    canonicalKey: sidecar.canonicalKey,
                    displayTitle: sidecar.displayTitle,
                    primaryArtistCanonicalName: sidecar.primaryArtistCanonicalName,
                    primaryArtistDisplayName: section.artistName,
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    year: sidecar.year,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: section.trackCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            } else {
                let newID = UUID()
                let newSidecar = AlbumSidecar(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: primaryArtistKey,
                    createdAt: now,
                    updatedAt: now
                )
                libraryService.writeAlbumSidecar(newSidecar, artworkData: nil)
                result.append(AlbumEntry(
                    id: newID,
                    canonicalKey: section.key,
                    displayTitle: section.name,
                    primaryArtistCanonicalName: primaryArtistKey,
                    primaryArtistDisplayName: section.artistName,
                    artworkFileName: nil,
                    description: "",
                    year: nil,
                    artworkData: firstArtwork,
                    createdAt: now,
                    updatedAt: now,
                    trackCount: section.trackCount,
                    totalDuration: totalDuration,
                    isOrphaned: false
                ))
            }
        }

        // Handle orphans
        for (_, (sidecar, folderURL)) in existing {
            let hasUserContent =
                !(sidecar.description ?? "").isEmpty
                || sidecar.artworkFileName != nil
                || sidecar.year != nil
            if hasUserContent {
                let artworkData = sidecar.artworkFileName.flatMap { fileName in
                    try? Data(contentsOf: folderURL.appendingPathComponent(fileName))
                }
                result.append(AlbumEntry(
                    id: sidecar.id,
                    canonicalKey: sidecar.canonicalKey,
                    displayTitle: sidecar.displayTitle,
                    primaryArtistCanonicalName: sidecar.primaryArtistCanonicalName,
                    primaryArtistDisplayName: "",
                    artworkFileName: sidecar.artworkFileName,
                    description: sidecar.description ?? "",
                    year: sidecar.year,
                    artworkData: artworkData,
                    createdAt: sidecar.createdAt,
                    updatedAt: sidecar.updatedAt,
                    trackCount: 0,
                    totalDuration: 0,
                    isOrphaned: true
                ))
            } else {
                try? FileManager.default.removeItem(at: folderURL)
            }
        }

        return result.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Services/Library/LibraryMetadataSync.swift
git commit -m "feat(library): add LibraryMetadataSync service"
```

---

## Task 5: Repository protocol and implementation

**Files:**
- Modify: `myPlayer2/Repositories/LibraryRepositoryProtocol.swift`
- Modify: `myPlayer2/Repositories/SwiftDataLibraryRepository.swift`
- Modify: `myPlayer2/Repositories/StubLibraryRepository.swift`

- [ ] **Step 1: Add new methods to `LibraryRepositoryProtocol`**

Append to the end of the protocol (before the closing `}`), after `func save()`:

```swift
    // MARK: - Artist/Album Entries

    func fetchArtistEntries() async -> [ArtistEntry]
    func fetchAlbumEntries() async -> [AlbumEntry]
    func updateArtistEntry(_ entry: ArtistEntry) async
    func updateAlbumEntry(_ entry: AlbumEntry) async

    // MARK: - Playlist Description

    func updatePlaylistDescription(_ playlist: Playlist, description: String) async
```

- [ ] **Step 2: Add stored properties to `SwiftDataLibraryRepository`**

After `private var playlistItemAddedAtMap` in `SwiftDataLibraryRepository`, add:

```swift
    private var artistEntries: [ArtistEntry] = []
    private var albumEntries: [AlbumEntry] = []
    private let metadataSync = LibraryMetadataSync()
```

- [ ] **Step 3: Call sync in `reloadFromLibrary()` and load playlist description**

In `reloadFromLibrary()`, after `rebuildTrackIndexCache()` at the end, add:

```swift
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
```

Also, in the `loadedPlaylists` mapping inside `reloadFromLibrary()`, update the `Playlist` init to include `description`:

```swift
            return Playlist(
                id: sidecar.id,
                name: sidecar.name,
                description: sidecar.description ?? "",
                createdAt: sidecar.createdAt,
                tracks: resolved
            )
```

Call sync after `rebuildRuntimeDerivedState()` in `addTracks(_:)`, `deleteTrack(_:)`, and `updateTrack(_:)` too. Add after each `rebuildTrackIndexCache()` call:

```swift
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
```

- [ ] **Step 4: Implement new protocol methods in `SwiftDataLibraryRepository`**

Add a new `// MARK: - Artist/Album Entries` section after the existing `// MARK: - Statistics & Runtime Sections` section:

```swift
    // MARK: - Artist/Album Entries

    func fetchArtistEntries() async -> [ArtistEntry] {
        artistEntries
    }

    func fetchAlbumEntries() async -> [AlbumEntry] {
        albumEntries
    }

    func updateArtistEntry(_ entry: ArtistEntry) async {
        if let idx = artistEntries.firstIndex(where: { $0.id == entry.id }) {
            artistEntries[idx] = entry
        }
        let sidecar = ArtistSidecar(
            id: entry.id,
            canonicalName: entry.canonicalName,
            displayName: entry.displayName,
            artworkFileName: entry.artworkFileName,
            description: entry.description.isEmpty ? nil : entry.description,
            createdAt: entry.createdAt,
            updatedAt: Date()
        )
        libraryService.writeArtistSidecar(sidecar, artworkData: entry.artworkData)
    }

    func updateAlbumEntry(_ entry: AlbumEntry) async {
        if let idx = albumEntries.firstIndex(where: { $0.id == entry.id }) {
            albumEntries[idx] = entry
        }
        let sidecar = AlbumSidecar(
            id: entry.id,
            canonicalKey: entry.canonicalKey,
            displayTitle: entry.displayTitle,
            primaryArtistCanonicalName: entry.primaryArtistCanonicalName,
            artworkFileName: entry.artworkFileName,
            description: entry.description.isEmpty ? nil : entry.description,
            year: entry.year,
            createdAt: entry.createdAt,
            updatedAt: Date()
        )
        // Only write artwork data if artworkFileName is set (user explicitly set artwork)
        libraryService.writeAlbumSidecar(sidecar, artworkData: entry.artworkFileName != nil ? entry.artworkData : nil)
    }

    func updatePlaylistDescription(_ playlist: Playlist, description: String) async {
        playlist.description = description
        writePlaylistToDisk(playlist)
    }
```

- [ ] **Step 5: Add stub implementations in `StubLibraryRepository`**

Append to `StubLibraryRepository`:

```swift
    func fetchArtistEntries() async -> [ArtistEntry] { [] }
    func fetchAlbumEntries() async -> [AlbumEntry] { [] }
    func updateArtistEntry(_ entry: ArtistEntry) async {}
    func updateAlbumEntry(_ entry: AlbumEntry) async {}
    func updatePlaylistDescription(_ playlist: Playlist, description: String) async {}
```

- [ ] **Step 6: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add myPlayer2/Repositories/LibraryRepositoryProtocol.swift \
        myPlayer2/Repositories/SwiftDataLibraryRepository.swift \
        myPlayer2/Repositories/StubLibraryRepository.swift
git commit -m "feat(repository): wire artist/album entry persistence through repository layer"
```

---

## Task 6: LibraryViewModel additions

**Files:**
- Modify: `myPlayer2/ViewModels/LibraryViewModel.swift`

- [ ] **Step 1: Add `artistEntries` and `albumEntries` published state**

After `private(set) var runtimeAlbums: [AlbumSection] = []`, add:

```swift
    private(set) var artistEntries: [ArtistEntry] = []
    private(set) var albumEntries: [AlbumEntry] = []
```

- [ ] **Step 2: Load entries in `load()`**

In `load()`, after `runtimeAlbums = await repository.fetchAlbumSections()`, add:

```swift
        artistEntries = await repository.fetchArtistEntries()
        albumEntries = await repository.fetchAlbumEntries()
```

- [ ] **Step 3: Add lookup helpers and save methods**

After `func deleteTrack(_:)`, add:

```swift
    // MARK: - Artist/Album Entry Lookups

    func artistEntry(for section: ArtistSection) -> ArtistEntry? {
        artistEntries.first { $0.canonicalName == section.key }
    }

    func albumEntry(for section: AlbumSection) -> AlbumEntry? {
        albumEntries.first { $0.canonicalKey == section.key }
    }

    // MARK: - Artist/Album Entry Saves

    func saveArtistEntry(_ entry: ArtistEntry) async {
        await repository.updateArtistEntry(entry)
        if let idx = artistEntries.firstIndex(where: { $0.id == entry.id }) {
            artistEntries[idx] = entry
        }
    }

    func saveAlbumEntry(_ entry: AlbumEntry) async {
        await repository.updateAlbumEntry(entry)
        if let idx = albumEntries.firstIndex(where: { $0.id == entry.id }) {
            albumEntries[idx] = entry
        }
    }

    func savePlaylistDescription(_ playlist: Playlist, description: String) async {
        await repository.updatePlaylistDescription(playlist, description: description)
    }
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add myPlayer2/ViewModels/LibraryViewModel.swift
git commit -m "feat(viewmodel): expose artistEntries/albumEntries and save methods"
```

---

## Task 7: DetailHeaderConfig types

**Files:**
- Create: `myPlayer2/Views/Library/DetailHeaderConfig.swift`

- [ ] **Step 1: Create `DetailHeaderConfig.swift`**

```swift
//
//  DetailHeaderConfig.swift
//  myPlayer2
//
//  Configuration enum for LibraryDetailHeaderView.
//  Drives content, artwork source, and edit behavior for each selection type.
//

import AppKit
import Foundation

enum DetailHeaderConfig {
    case playlist(Playlist, entry: PlaylistHeaderData)
    case artist(ArtistEntry, stats: ArtistDerivedStats)
    case album(AlbumEntry, stats: AlbumDerivedStats)
}

struct PlaylistHeaderData {
    var description: String
    var tracks: [Track]
}

struct ArtistDerivedStats {
    let trackCount: Int
    let albumCount: Int
    let totalDuration: Double
}

struct AlbumDerivedStats {
    let artistName: String
    let trackCount: Int
    let totalDuration: Double
    let artworkImage: NSImage?
}

extension DetailHeaderConfig {
    /// Stable string identity used to detect config changes in SwiftUI `.onChange`.
    var identity: String {
        switch self {
        case .playlist(let p, _): return "playlist-\(p.id)"
        case .artist(let e, _): return "artist-\(e.id)"
        case .album(let e, _): return "album-\(e.id)"
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Views/Library/DetailHeaderConfig.swift
git commit -m "feat(ui): add DetailHeaderConfig enum and supporting data types"
```

---

## Task 8: PlaylistArtworkGenerator

**Files:**
- Create: `myPlayer2/Services/Library/PlaylistArtworkGenerator.swift`

- [ ] **Step 1: Create `PlaylistArtworkGenerator.swift`**

```swift
//
//  PlaylistArtworkGenerator.swift
//  myPlayer2
//
//  Generates deterministic playlist cover art by recoloring a grayscale base image
//  with colors extracted from the playlist's track artworks.
//  Generation is off-thread; result is cached by (playlistID, contentSignature).
//

import AppKit

actor PlaylistArtworkGenerator {

    static let shared = PlaylistArtworkGenerator()

    private var cache: [UUID: (signature: String, image: NSImage)] = [:]

    // MARK: - Public API

    /// Returns cached or newly generated artwork for a playlist.
    /// Safe to call from MainActor; dispatches generation off-thread.
    func artwork(for playlist: Playlist, tracks: [Track]) async -> NSImage? {
        let signature = contentSignature(tracks: tracks)
        if let cached = cache[playlist.id], cached.signature == signature {
            return cached.image
        }

        let playlistID = playlist.id
        // Snapshot track data for off-thread use (IDs + artworkData only)
        let snapshots: [(id: UUID, artworkData: Data?)] = tracks.map {
            (id: $0.id, artworkData: $0.artworkData)
        }

        let result = await Task.detached(priority: .userInitiated) {
            PlaylistArtworkGenerator.generate(playlistID: playlistID, snapshots: snapshots)
        }.value

        if let result {
            cache[playlistID] = (signature, result)
        }
        return result
    }

    // MARK: - Cache

    func invalidate(playlistID: UUID) {
        cache.removeValue(forKey: playlistID)
    }

    // MARK: - Generation (nonisolated, runs off main thread)

    private static nonisolated func generate(
        playlistID: UUID,
        snapshots: [(id: UUID, artworkData: Data?)]
    ) -> NSImage? {
        let hash = stableHash(for: playlistID.uuidString)

        // Step 1: Select base image
        let baseNames = ["cov1", "cov2", "cov3"]
        let baseName = baseNames[hash % 3]
        guard let baseImage = NSImage(named: baseName) else { return nil }

        // Step 2: Sample track indices deterministically
        let artSnapshots = snapshots.filter { $0.artworkData != nil }
        guard !artSnapshots.isEmpty else {
            return tintedFallback(baseImage: baseImage)
        }

        let sampleCount = min(5, artSnapshots.count)
        let indices = sampleIndices(from: hash, count: sampleCount, total: artSnapshots.count)

        // Step 3: Extract colors from sampled artworks
        var colors: [NSColor] = []
        for idx in indices {
            guard let data = artSnapshots[idx].artworkData else { continue }
            let palette = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 3)
            colors.append(contentsOf: palette)
        }
        guard !colors.isEmpty else {
            return tintedFallback(baseImage: baseImage)
        }

        // Step 4: Sort by luminance (darkest → lightest)
        let sorted = colors.sorted { luminance($0) < luminance($1) }

        // Step 5: Deduplicate nearby luminance values, keep up to 5
        let representative = deduped(sorted, maxCount: 5)

        // Step 6: Build 256-entry gradient LUT
        let lut = buildLUT(from: representative)

        // Step 7: Recolor
        return recolor(baseImage: baseImage, lut: lut) ?? tintedFallback(baseImage: baseImage)
    }

    // MARK: - Stable Hash (DJB2, launch-stable)

    static nonisolated func stableHash(for string: String) -> Int {
        var hash: Int = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) ^ Int(byte)
        }
        return abs(hash)
    }

    // MARK: - Sample Index Selection

    private static nonisolated func sampleIndices(from hash: Int, count: Int, total: Int) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        var h = hash
        while result.count < count {
            let idx = abs(h) % total
            if seen.insert(idx).inserted {
                result.append(idx)
            }
            h = (h &* 1_664_525) &+ 1_013_904_223  // LCG step
        }
        return result
    }

    // MARK: - Content Signature

    private nonisolated func contentSignature(tracks: [Track]) -> String {
        let sortedIDs = tracks.map(\.id.uuidString).sorted().joined()
        return String(PlaylistArtworkGenerator.stableHash(for: sortedIDs))
    }

    // MARK: - Luminance

    private static nonisolated func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    // MARK: - Dedup by luminance proximity

    private static nonisolated func deduped(_ colors: [NSColor], maxCount: Int) -> [NSColor] {
        var result: [NSColor] = []
        for color in colors {
            let lum = luminance(color)
            if !result.contains(where: { abs(luminance($0) - lum) < 0.08 }) {
                result.append(color)
                if result.count == maxCount { break }
            }
        }
        return result.isEmpty ? Array(colors.prefix(maxCount)) : result
    }

    // MARK: - LUT Construction

    private static nonisolated func buildLUT(from colors: [NSColor]) -> [NSColor] {
        guard !colors.isEmpty else { return Array(repeating: .gray, count: 256) }
        var lut = [NSColor](repeating: .black, count: 256)
        for i in 0..<256 {
            let t = CGFloat(i) / 255.0
            lut[i] = interpolateColor(t: t, stops: colors)
        }
        return lut
    }

    private static nonisolated func interpolateColor(t: CGFloat, stops: [NSColor]) -> NSColor {
        let count = stops.count
        guard count > 1 else { return stops[0] }
        let scaled = t * CGFloat(count - 1)
        let lower = min(Int(scaled), count - 2)
        let upper = lower + 1
        let localT = scaled - CGFloat(lower)
        return blend(stops[lower], stops[upper], t: localT)
    }

    private static nonisolated func blend(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        guard let ac = a.usingColorSpace(.deviceRGB),
              let bc = b.usingColorSpace(.deviceRGB) else { return a }
        return NSColor(
            calibratedRed: ac.redComponent + (bc.redComponent - ac.redComponent) * t,
            green: ac.greenComponent + (bc.greenComponent - ac.greenComponent) * t,
            blue: ac.blueComponent + (bc.blueComponent - ac.blueComponent) * t,
            alpha: 1.0
        )
    }

    // MARK: - Pixel Recolor

    private static nonisolated func recolor(baseImage: NSImage, lut: [NSColor]) -> NSImage? {
        guard let cgBase = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgBase.width
        let height = cgBase.height
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgBase, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let a = CGFloat(pixelData[i + 3]) / 255.0
            guard a > 0 else { continue }
            let r = CGFloat(pixelData[i]) / (255.0 * a)
            let g = CGFloat(pixelData[i + 1]) / (255.0 * a)
            let b = CGFloat(pixelData[i + 2]) / (255.0 * a)
            let luma = min(1.0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            let lutIdx = min(255, Int(luma * 255))
            guard let mapped = lut[lutIdx].usingColorSpace(.deviceRGB) else { continue }
            pixelData[i]     = UInt8(min(255, mapped.redComponent   * a * 255))
            pixelData[i + 1] = UInt8(min(255, mapped.greenComponent * a * 255))
            pixelData[i + 2] = UInt8(min(255, mapped.blueComponent  * a * 255))
            // alpha unchanged
        }

        guard let outCG = ctx.makeImage() else { return nil }
        let result = NSImage(size: baseImage.size)
        result.addRepresentation(NSBitmapImageRep(cgImage: outCG))
        return result
    }

    // MARK: - Fallback

    private static nonisolated func tintedFallback(baseImage: NSImage) -> NSImage {
        let size = baseImage.size
        guard let cgBase = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return baseImage
        }
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage.draw(in: NSRect(origin: .zero, size: size))
        NSColor.systemIndigo.withAlphaComponent(0.45).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        result.unlockFocus()
        _ = cgBase  // suppress unused warning
        return result
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Services/Library/PlaylistArtworkGenerator.swift
git commit -m "feat(library): add deterministic PlaylistArtworkGenerator"
```

---

## Task 9: BlurredArtworkBackgroundView

**Files:**
- Create: `myPlayer2/Views/Library/BlurredArtworkBackgroundView.swift`

- [ ] **Step 1: Create `BlurredArtworkBackgroundView.swift`**

```swift
//
//  BlurredArtworkBackgroundView.swift
//  myPlayer2
//
//  Large soft blurred artwork image placed at the top of the detail page scroll area.
//  Scrolls with the content — not a fixed window background.
//  Fades out at the bottom via a gradient mask.
//

import SwiftUI

struct BlurredArtworkBackgroundView: View {
    let image: NSImage?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 520)
                .blur(radius: 40, opaque: false)
                .opacity(colorScheme == .dark ? 0.38 : 0.22)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.35),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
                .allowsHitTesting(false)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Views/Library/BlurredArtworkBackgroundView.swift
git commit -m "feat(ui): add BlurredArtworkBackgroundView for scrolling artwork wash"
```

---

## Task 10: LibraryDetailHeaderView

**Files:**
- Create: `myPlayer2/Views/Library/LibraryDetailHeaderView.swift`

- [ ] **Step 1: Create `LibraryDetailHeaderView.swift`**

```swift
//
//  LibraryDetailHeaderView.swift
//  myPlayer2
//
//  Unified detail-page header for playlist, artist, and album selections.
//  Shows large artwork on the left, text metadata in the center, edit button on the right.
//  Edit mode exposes description and (for album) year fields.
//  The header is a plain view — not inside a List — so no listRow modifiers are needed.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryDetailHeaderView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme

    let config: DetailHeaderConfig
    let onArtworkChange: (NSImage?) -> Void

    @State private var isEditing = false
    @State private var editDescription = ""
    @State private var editYear = ""          // album only
    @State private var generatedArtwork: NSImage?
    @State private var artworkGenTask: Task<Void, Never>?
    @State private var isImportingArtwork = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            artworkColumn
                .frame(width: 180, height: 180)

            VStack(alignment: .leading, spacing: 5) {
                titleView
                subtitleView
                metadataView
                Spacer().frame(height: 2)
                if isEditing {
                    descriptionEditor
                    if case .album = config { yearEditor }
                } else {
                    descriptionReadView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            editButtonView
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .onAppear { refreshArtwork() }
        .onChange(of: config.identity) { refreshArtwork() }
        .fileImporter(
            isPresented: $isImportingArtwork,
            allowedContentTypes: [UTType.jpeg, UTType.png, UTType.heic, UTType.tiff],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result: result)
        }
    }

    // MARK: - Artwork column

    @ViewBuilder
    private var artworkColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            artworkImage
                .clipShape(artworkClipShape)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

            if isEditing {
                Button { isImportingArtwork = true } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: 5)
            }
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        switch config {
        case .playlist:
            Group {
                if let img = generatedArtwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
        case .artist:
            ZStack {
                Circle().fill(.secondary.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        case .album(_, let stats):
            Group {
                if let img = stats.artworkImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .overlay(
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
        }
    }

    private var artworkClipShape: AnyShape {
        switch config {
        case .artist: AnyShape(Circle())
        default: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Text fields

    private var titleView: some View {
        Text(titleString)
            .font(.title)
            .fontWeight(.bold)
            .lineLimit(2)
    }

    private var titleString: String {
        switch config {
        case .playlist(let p, _): return p.name
        case .artist(let e, _): return e.displayName
        case .album(let e, _): return e.displayTitle
        }
    }

    private var subtitleView: some View {
        Text(subtitleString)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var subtitleString: String {
        switch config {
        case .playlist(_, let data):
            let n = data.tracks.count
            return n == 1 ? "1 首歌曲" : "\(n) 首歌曲"
        case .artist(_, let stats):
            return "\(stats.trackCount) 首歌曲 · \(stats.albumCount) 张专辑"
        case .album(_, let stats):
            return stats.artistName
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        switch config {
        case .playlist(_, let data):
            let dur = data.tracks.reduce(0) { $0 + $1.duration }
            Text(formatDuration(dur))
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .artist:
            EmptyView()
        case .album(let entry, let stats):
            let parts = buildAlbumMetaParts(entry: entry, stats: stats)
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func buildAlbumMetaParts(entry: AlbumEntry, stats: AlbumDerivedStats) -> [String] {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        let n = stats.trackCount
        parts.append(n == 1 ? "1 首歌曲" : "\(n) 首歌曲")
        parts.append(formatDuration(stats.totalDuration))
        return parts
    }

    // MARK: - Description

    private var currentDescription: String {
        switch config {
        case .playlist(_, let data): return data.description
        case .artist(let e, _): return e.description
        case .album(let e, _): return e.description
        }
    }

    private var descriptionReadView: some View {
        Text(currentDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var descriptionEditor: some View {
        TextField("添加描述…", text: $editDescription, axis: .vertical)
            .font(.callout)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var yearEditor: some View {
        HStack(spacing: 6) {
            Text("年份")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $editYear)
                .font(.callout)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .onSubmit { commitEdits() }
        }
    }

    // MARK: - Edit button

    private var editButtonView: some View {
        Button {
            if isEditing { commitEdits() } else { beginEditing() }
        } label: {
            Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEditing ? Color.accentColor : .secondary)
    }

    private func beginEditing() {
        editDescription = currentDescription
        if case .album(let entry, _) = config {
            editYear = entry.year.map { String($0) } ?? ""
        }
        isEditing = true
    }

    private func commitEdits() {
        isEditing = false
        let desc = editDescription
        let yearStr = editYear
        Task {
            switch config {
            case .playlist(let playlist, _):
                await libraryVM.savePlaylistDescription(playlist, description: desc)
            case .artist(let entry, _):
                var updated = entry
                updated.description = desc
                await libraryVM.saveArtistEntry(updated)
            case .album(let entry, _):
                var updated = entry
                updated.description = desc
                updated.year = Int(yearStr)
                await libraryVM.saveAlbumEntry(updated)
            }
        }
    }

    // MARK: - Artwork loading

    private func refreshArtwork() {
        artworkGenTask?.cancel()
        switch config {
        case .playlist(let playlist, let data):
            artworkGenTask = Task {
                let img = await PlaylistArtworkGenerator.shared.artwork(
                    for: playlist, tracks: data.tracks)
                guard !Task.isCancelled else { return }
                generatedArtwork = img
                onArtworkChange(img)
            }
        case .artist:
            generatedArtwork = nil
            onArtworkChange(nil)
        case .album(_, let stats):
            generatedArtwork = nil
            onArtworkChange(stats.artworkImage)
        }
    }

    // MARK: - Artwork import

    private func handleArtworkImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let nsImage = NSImage(contentsOf: url) else { return }
        let pngData: Data? = {
            guard let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else { return nil }
            return rep.representation(using: .png, properties: [:])
        }()

        // Update display immediately
        switch config {
        case .playlist:
            generatedArtwork = nsImage
        default:
            break
        }
        onArtworkChange(nsImage)

        // Persist for artist/album
        Task {
            switch config {
            case .playlist:
                break   // playlist artwork replacement not persisted in this pass
            case .artist(let entry, _):
                var updated = entry
                updated.artworkFileName = "artwork.png"
                updated.artworkData = pngData
                await libraryVM.saveArtistEntry(updated)
            case .album(let entry, _):
                var updated = entry
                updated.artworkFileName = "artwork.png"
                updated.artworkData = pngData
                await libraryVM.saveAlbumEntry(updated)
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Views/Library/LibraryDetailHeaderView.swift
git commit -m "feat(ui): add LibraryDetailHeaderView shared header component"
```

---

## Task 11: PlaylistDetailView integration

**Files:**
- Modify: `myPlayer2/Views/Library/PlaylistDetailView.swift`

This task makes targeted additions to `PlaylistDetailView`. All existing properties, caching, multiselect, and batch logic remain completely untouched.

- [ ] **Step 1: Add `headerArtwork` state**

After `@State private var batchEditRequest: BatchEditRequest?` (around line 52), add:

```swift
    @State private var headerArtwork: NSImage?
```

- [ ] **Step 2: Add `detailHeaderConfig` computed property**

After the `private var isFiltering` computed property (around line 155), add:

```swift
    // MARK: - Detail Header

    /// Config for LibraryDetailHeaderView. Nil for .allSongs (no header).
    private var detailHeaderConfig: DetailHeaderConfig? {
        switch libraryVM.currentSelection {
        case .allSongs:
            return nil
        case .playlist(let id):
            guard let playlist = libraryVM.playlists.first(where: { $0.id == id }) else {
                return nil
            }
            return .playlist(
                playlist,
                entry: PlaylistHeaderData(
                    description: playlist.description,
                    tracks: displayedTracksCache
                )
            )
        case .artist(let key):
            guard let entry = libraryVM.artistEntries.first(where: { $0.canonicalName == key }) else {
                return nil
            }
            let albumCount = libraryVM.albumEntries
                .filter { $0.primaryArtistCanonicalName == key }
                .count
            let totalDuration = displayedTracksCache.reduce(0) { $0 + $1.duration }
            return .artist(
                entry,
                stats: ArtistDerivedStats(
                    trackCount: displayedTracksCache.count,
                    albumCount: albumCount,
                    totalDuration: totalDuration
                )
            )
        case .album(let key):
            guard let entry = libraryVM.albumEntries.first(where: { $0.canonicalKey == key }) else {
                return nil
            }
            let totalDuration = displayedTracksCache.reduce(0) { $0 + $1.duration }
            let firstArtwork = displayedTracksCache.first?.artworkData.flatMap {
                NSImage(data: $0)
            }
            return .album(
                entry,
                stats: AlbumDerivedStats(
                    artistName: entry.primaryArtistDisplayName,
                    trackCount: displayedTracksCache.count,
                    totalDuration: totalDuration,
                    artworkImage: firstArtwork
                )
            )
        }
    }
```

- [ ] **Step 3: Extract track rows into `trackRowsContent`**

This avoids duplicating the ForEach in two places. The current `trackListView` contains a `ForEach` over `viewSnapshot.trackIDs` and a bottom spacer. Extract these as a computed property by adding, after `detailHeaderConfig`:

```swift
    /// The track rows and bottom spacer shared by both scroll view variants.
    @ViewBuilder
    private var trackRowsContent: some View {
        ForEach(viewSnapshot.trackIDs, id: \.self) { trackID in
            if
                let rowSnapshot = viewSnapshot.snapshot(for: trackID),
                let track = trackByIDCache[trackID]
            {
                TrackRowView(
                    model: trackRowModel(for: rowSnapshot),
                    isPlaying: playerVM.currentTrack?.id == trackID,
                    isSelected: isMultiselectMode && selectedTrackIDs.contains(trackID),
                    onTap: {
                        if isMultiselectMode {
                            if selectedTrackIDs.contains(trackID) {
                                selectedTrackIDs.remove(trackID)
                            } else {
                                selectedTrackIDs.insert(trackID)
                            }
                        } else {
                            let startIndex = parentSortedTrackIndexMapCache[trackID] ?? 0
                            playerVM.playTracks(
                                parentSortedTracksCache,
                                startingAt: startIndex
                            )
                        }
                    },
                    onRowAppear: {
                        prefetchAroundTrackID(trackID)
                    }
                ) {
                    trackMenu(track: track)
                }
                .contextMenu {
                    trackMenu(track: track)
                }
            }
        }
        Color.clear.frame(height: 160)
    }
```

Then simplify the ForEach portion of `trackListView` to use `trackRowsContent`:

```swift
    private var trackListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                trackRowsContent
            }
            .scrollTargetLayout()
            .padding(.top, listTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in tx.animation = nil }
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: listScrollPositionID) { _, _ in
            scheduleSnapshotUpdate()
        }
        .onTapGesture {
            clearSearchFocus()
        }
    }
```

- [ ] **Step 4: Add `detailScrollView`**

Add a new `detailScrollView` computed property that always shows the header, followed by the content state (loading / empty / tracks):

```swift
    /// Scroll view used for playlist/artist/album selections.
    /// Always renders the detail header row regardless of content state.
    private var detailScrollView: some View {
        ScrollView(.vertical) {
            ZStack(alignment: .top) {
                BlurredArtworkBackgroundView(image: headerArtwork)

                LazyVStack(spacing: 0) {
                    // Header row (always present for non-allSongs)
                    if let config = detailHeaderConfig {
                        LibraryDetailHeaderView(config: config) { image in
                            headerArtwork = image
                        }
                    }

                    // Content: loading indicator, empty state, or track rows
                    if libraryVM.state == .loading
                        || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
                    {
                        ProgressView()
                            .controlSize(.large)
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                    } else if filteredTracksCache.isEmpty
                        && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        // Inline no-results (search active)
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("library.no_results")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        trackRowsContent
                    }
                }
                .scrollTargetLayout()
                .padding(.top, listTopPadding)
                .padding(.bottom, listBottomPadding)
                .padding(.horizontal)
                .transaction { tx in tx.animation = nil }
            }
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: listScrollPositionID) { _, _ in
            scheduleSnapshotUpdate()
        }
        .onTapGesture {
            clearSearchFocus()
        }
    }
```

- [ ] **Step 5: Route non-allSongs to `detailScrollView` in `body`**

The current `body` starts with:

```swift
    var body: some View {
        Group {
            if libraryVM.state == .loading
                || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
            {
                ProgressView()...
            } else if displayedTracksCache.isEmpty {
                emptyStateView
            } else if filteredTracksCache.isEmpty {
                noResultsView
            } else {
                trackListView
            }
        }
```

Replace the `Group { ... }` block with:

```swift
    var body: some View {
        Group {
            if libraryVM.currentSelection == .allSongs {
                // All Songs: no detail header, existing loading/empty/list states
                if libraryVM.state == .loading
                    || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
                {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedTracksCache.isEmpty {
                    emptyStateView
                } else if filteredTracksCache.isEmpty {
                    noResultsView
                } else {
                    trackListView
                }
            } else {
                // Playlist / artist / album: always show scrollable view with detail header
                detailScrollView
            }
        }
```

Keep everything after the `Group { }` block unchanged (`.frame`, `.overlay`, `.sheet`, `.onAppear`, `.onChange`, etc.).

- [ ] **Step 6: Reset `headerArtwork` on selection change**

In the existing `.onChange(of: libraryVM.currentSelection)` handler (around line 148), add `headerArtwork = nil` before `scheduleRebuild`:

```swift
        .onChange(of: libraryVM.currentSelection) { oldVal, newVal in
            headerArtwork = nil
            scheduleRebuild(reason: "selection", restoreScroll: true)
        }
```

- [ ] **Step 7: Build and verify**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 8: Verify behavior in Xcode preview**

Open `PlaylistDetailView.swift` and run the existing `#Preview("Playlist Detail")` at the bottom of the file. Confirm:
- Preview renders without crash
- The existing all-songs view shows the track list without the header
- Switching to a playlist selection shows the header row at the top of the scroll content

- [ ] **Step 9: Commit**

```bash
git add myPlayer2/Views/Library/PlaylistDetailView.swift
git commit -m "feat(ui): inject LibraryDetailHeaderView and BlurredArtworkBackgroundView into PlaylistDetailView"
```

---

## Task 12: Final integration smoke test and cleanup

- [ ] **Step 1: Full build**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`, no errors. Review any new warnings introduced by this feature.

- [ ] **Step 2: Verify disk output**

Run the app in Xcode (⌘R). Open the library. If any songs are imported:

```bash
ls ~/Music/kmgccc_player\ Library/Artists/
ls ~/Music/kmgccc_player\ Library/Albums/
```

Expected: subdirectories with UUID names exist, each containing a `meta.json`.

- [ ] **Step 3: Verify sidecar content**

```bash
cat ~/Music/kmgccc_player\ Library/Artists/$(ls ~/Music/kmgccc_player\ Library/Artists/ | head -1)/meta.json
```

Expected: valid JSON with `schemaVersion`, `id`, `canonicalName`, `displayName`, `createdAt`, `updatedAt` fields.

- [ ] **Step 4: Verify header appears**

In the running app:
1. Select a playlist in the sidebar → header with artwork, title, subtitle should appear at top of scroll content
2. Select an artist → header with `person.fill` circle, title, subtitle
3. Select an album → header with track artwork, title, artist name, track count

- [ ] **Step 5: Verify edit mode**

1. Click the pencil button in the header → description text field appears
2. Type a description and click checkmark → description persists after reloading the app
3. On album header → year field appears in edit mode, accepts numeric input

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat(library-header): complete detail header feature integration

- Persistent ArtistEntry/AlbumEntry disk sidecars (UUID dirs with meta.json)
- LibraryMetadataSync merges derived groupings with persistent entries
- PlaylistArtworkGenerator: deterministic grayscale-base recoloring
- LibraryDetailHeaderView: shared header for playlist/artist/album
- BlurredArtworkBackgroundView: scrolling soft artwork wash
- PlaylistDetailView extended with detail scroll path for non-allSongs

Temporary limitations:
- Artist artwork shows person.fill placeholder (upload wired, no real art)
- Playlist artwork replacement is display-only (not persisted)
- Album track ordering uses existing sort, not track-number order"
```

---

## Temporary Limitations

| Area | Status |
|------|--------|
| Artist artwork | `person.fill` placeholder. File import UI is wired and persists to `ArtistEntry`. |
| Playlist artwork replacement | Artwork file import updates the displayed image + blurred background but is not written to disk in this pass. |
| Album track ordering | Uses the existing sort preference, not track-number ordering. |
| Orphaned entries (no songs) | Kept on disk with `isOrphaned = true` in memory. No UI to surface or clean them up. |
| Artist/album entries on first run | Created on first `reloadFromLibrary()` call; the library must contain at least one song for entries to appear. |
