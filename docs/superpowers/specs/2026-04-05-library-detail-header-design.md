# Library Detail Header & Persistent Artist/Album Metadata — Design Spec

Date: 2026-04-05
Status: Approved

---

## Overview

Introduce a unified detail-header UI for the music library's detail pane, backed by persistent on-disk metadata for artist and album entries. The feature covers three areas:

1. **Persistent metadata entities** — `ArtistEntry` and `AlbumEntry` stored as disk-based JSON sidecars, following the same philosophy as existing Tracks and Playlists.
2. **A sync pipeline** — merges song-derived groupings with persistent entries after each library load or song change.
3. **A shared header UI** — `LibraryDetailHeaderView` injected into the existing `PlaylistDetailView` as the first scrollable row, plus a scrolling blurred artwork background layer.
4. **Playlist artwork generation** — deterministic grayscale-base recoloring using extracted song colors.

`PlaylistDetailView` is already the single unified detail page for all selection types. This feature extends it; it does not create separate artist/album pages.

---

## Section 1: Persistent Metadata Entities

### Storage Layout

```
~/Music/kmgccc_player Library/
├── Tracks/<UUID>/meta.json            (existing)
├── Playlists/<UUID>/meta.json         (existing)
├── Artists/<UUID>/meta.json           (NEW)
│   └── artwork.png                    (optional)
└── Albums/<UUID>/meta.json            (NEW)
    └── artwork.png                    (optional)
```

Directory names use stable UUIDs assigned at entry creation time. Canonical keys and display names live inside the JSON. Paths never depend on display or canonical text.

### ArtistSidecar (meta.json)

```json
{
  "schemaVersion": 1,
  "id": "uuid",
  "canonicalName": "normalized-artist-key",
  "displayName": "Display Name",
  "artworkFileName": "artwork.png",
  "description": "",
  "createdAt": "iso8601",
  "updatedAt": "iso8601"
}
```

All fields except `artworkFileName` and `description` are required. Missing optional fields decoded with `decodeIfPresent`.

### AlbumSidecar (meta.json)

```json
{
  "schemaVersion": 1,
  "id": "uuid",
  "canonicalKey": "normalized-album•artist-key",
  "displayTitle": "Album Title",
  "primaryArtistCanonicalName": "normalized-artist-key",
  "artworkFileName": "artwork.png",
  "description": "",
  "year": null,
  "createdAt": "iso8601",
  "updatedAt": "iso8601"
}
```

`year` is `Int?`. `artworkFileName`, `description`, and `year` are optional.
`canonicalKey` encodes the normalized album+artist identity key (matching `LibraryNormalization.normalizedAlbumKey(album:artist:)`), not just the album title.

### Playlist Description

`PlaylistSidecar` gains a `description: String?` field. Backward-compatible: `decodeIfPresent`, defaults to `nil`. Written as `""` when empty. Schema version stays at `2` — no destructive migration needed.

### In-Memory Representations

- `Models/ArtistEntry.swift` — struct holding all sidecar fields plus `trackCount`, `albumCount`, `totalDuration` populated at sync time.
- `Models/AlbumEntry.swift` — struct holding all sidecar fields plus `trackCount`, `totalDuration`, representative `artworkData: Data?` populated at sync time from the first track's artwork.

### New Path Helpers (LocalLibraryPaths)

```swift
static var artistsRootURL: URL
static var albumsRootURL: URL
static func artistFolderURL(for id: UUID) -> URL
static func albumFolderURL(for id: UUID) -> URL
static func artistMetaURL(for id: UUID) -> URL
static func albumMetaURL(for id: UUID) -> URL
```

### New LocalLibraryService Methods

```swift
func loadArtistSidecarsFromDisk() -> [(sidecar: ArtistSidecar, folderURL: URL)]
func loadAlbumSidecarsFromDisk() -> [(sidecar: AlbumSidecar, folderURL: URL)]
func writeArtistSidecar(_ sidecar: ArtistSidecar, artworkData: Data?)
func writeAlbumSidecar(_ sidecar: AlbumSidecar, artworkData: Data?)
func deleteArtistEntry(id: UUID)
func deleteAlbumEntry(id: UUID)
```

`ensureLibraryFolders()` is extended to create `Artists/` and `Albums/` subdirectories.

---

## Section 2: Sync Pipeline

### Trigger Points

The sync runs inside `SwiftDataLibraryRepository.reloadFromLibrary()`, after the existing `rebuildRuntimeDerivedState()` call. It also runs after `addTracks()`, `deleteTrack()`, and `updateTrack()`.

### LibraryMetadataSync Service

A focused, non-UI service:

```swift
actor LibraryMetadataSync {
    func sync(
        derivedArtists: [ArtistSection],
        derivedAlbums: [AlbumSection],
        allTracks: [Track],
        libraryService: LocalLibraryService
    ) async -> (artists: [ArtistEntry], albums: [AlbumEntry])
}
```

### Sync Logic

**Artist sync:**
1. Load existing `ArtistSidecar` records from disk.
2. Build a lookup: `[canonicalName: ArtistSidecar]`.
3. For each derived `ArtistSection`:
   - If a matching sidecar exists: produce `ArtistEntry` with user-edited fields preserved + updated derived stats (`trackCount`, `albumCount`, `totalDuration`). Do not update or rewrite the sidecar — `updatedAt` is only bumped when user-editable persisted fields change, not during derived-stat sync.
   - If no sidecar exists: create a new `ArtistSidecar` with a new UUID, write to disk, produce `ArtistEntry`.
4. For sidecars with no matching derived section (orphaned):
   - If `description` is non-empty or `artworkFileName` is set → keep, set `isOrphaned = true` on the in-memory `ArtistEntry` only. This is runtime-only derived state; it is not persisted to disk.
   - If no user-edited content → delete folder from disk.

**Album sync:** Same structure, keyed by `canonicalKey` (which encodes album + primary artist canonical name).

**User-editable fields that survive sync:** `description`, `artworkFileName`, `displayName`/`displayTitle`, `year`.
**Derived fields that sync refreshes:** `trackCount`, `albumCount`, `totalDuration`, representative artwork loaded from first matching track.

### Repository & ViewModel

`LibraryRepositoryProtocol` gains:
```swift
func fetchArtistEntries() async -> [ArtistEntry]
func fetchAlbumEntries() async -> [AlbumEntry]
func updateArtistEntry(_ entry: ArtistEntry) async
func updateAlbumEntry(_ entry: AlbumEntry) async
func updatePlaylistDescription(_ playlist: Playlist, description: String) async
```

`LibraryViewModel` gains:
```swift
private(set) var artistEntries: [ArtistEntry] = []
private(set) var albumEntries: [AlbumEntry] = []

func artistEntry(for section: ArtistSection) -> ArtistEntry?
func albumEntry(for section: AlbumSection) -> AlbumEntry?
func saveArtistEntry(_ entry: ArtistEntry) async
func saveAlbumEntry(_ entry: AlbumEntry) async
func savePlaylistDescription(_ playlist: Playlist, description: String) async
```

These are loaded during `load()` alongside existing data.

---

## Section 3: Detail View Reuse

`PlaylistDetailView` is the existing unified detail page. It already handles `.allSongs`, `.playlist`, `.artist`, `.album` selections internally. This design does not create separate artist/album pages.

**Changes to `PlaylistDetailView`:**
1. Add `@State private var headerArtwork: NSImage?` — tracks the current header artwork for the blurred background.
2. Insert `LibraryDetailHeaderView` as the first element in the existing `LazyVStack`, before track rows.
3. Insert the blurred artwork background layer into the existing `ScrollView`, positioned behind the `LazyVStack`.
4. Wire `onArtworkChange` from the header to update `headerArtwork`.

All existing scroll position restoration, caching, prefetching, multiselect, and batch operation logic remains untouched.

### DetailHeaderConfig

```swift
enum DetailHeaderConfig {
    case playlist(Playlist, entry: PlaylistHeaderData)
    case artist(ArtistEntry, stats: ArtistDerivedStats)
    case album(AlbumEntry, stats: AlbumDerivedStats)
}

struct PlaylistHeaderData {
    var description: String
    var tracks: [Track]  // passed to PlaylistArtworkGenerator internally by the header
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
    let artworkImage: NSImage?  // first track artwork
}
```

`PlaylistDetailView` computes the appropriate `DetailHeaderConfig` from `libraryVM.currentSelection`.

**Playlist artwork generation:** `LibraryDetailHeaderView` triggers artwork generation internally (via `PlaylistArtworkGenerator`) when given a `.playlist` config. The parent does not pre-generate artwork. The header calls `onArtworkChange` once the generated image is ready and whenever it changes.

**Header visibility in all states:** For non-`.allSongs` selections, the header row must appear in all content states (loading, empty, no-results, loaded). The header is not gated behind the existing empty/loaded state switch. `PlaylistDetailView` will show the header outside that conditional block for playlist/artist/album selections.

---

## Section 4: LibraryDetailHeaderView

A single shared SwiftUI component. Not three separate implementations.

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  [Artwork 180×180]  Title                   [Edit btn]  │
│                     Subtitle                            │
│                     Metadata row                        │
│                     Description (read/edit)             │
└─────────────────────────────────────────────────────────┘
```

- Artwork: left, 180×180
- Text stack: center/right, flexible
- Edit button: far right edge, right-aligned — not overlaid on artwork
- Full row is a list row: `.listRowBackground(Color.clear)`, `.listRowSeparator(.hidden)`

### Artwork Shape

- Playlist, Album: `RoundedRectangle(cornerRadius: 14)` clip
- Artist: `Circle()` clip
- All: subtle shadow, no glow

### Per-Type Content

| | Playlist | Artist | Album |
|---|---|---|---|
| Artwork | Generated (see §5) | `person.fill` placeholder | First track's `artworkData` |
| Title | `playlist.name` | `entry.displayName` | `entry.displayTitle` |
| Subtitle | "N songs" | "N songs · M albums" | Album's primary artist display name (looked up from `runtimeArtists` or `ArtistEntry.displayName`) |
| Metadata | Total duration | (blank) | Year · N songs · duration |
| Description | Editable, persists on Playlist | Editable, persists on ArtistEntry | Editable, persists on AlbumEntry |

### Edit Mode

- Toggled by the edit button (right-aligned, inside the header row)
- In read mode: missing values appear as blank text — no "Unknown" placeholders
- In edit mode: text fields for description (all types), year (album only), and artwork replacement (all types). Title editing is out of scope for this pass.
- Artwork replacement: `NSOpenPanel` / file importer for local image selection
- On save: calls the appropriate `libraryVM.save*Entry()` method; updates `onArtworkChange` callback

### Callbacks

```swift
struct LibraryDetailHeaderView: View {
    let config: DetailHeaderConfig
    let onArtworkChange: (NSImage?) -> Void
}
```

One consistent callback. No mixed `Binding<NSImage?>` / callback patterns across pages.

---

## Section 5: Playlist Artwork Generation

### Pipeline

**Step 1 — Stable hash:** Compute a stable hash from `playlist.id.uuidString`. Do not use Swift `hashValue` (randomized per launch). A simple DJB2 or FNV hash over the UTF-8 bytes of the UUID string is sufficient.

**Step 2 — Select base image:** `stableHash % 3` → index into `["cov1", "cov2", "cov3"]`. Load via `NSImage(named:)`.

**Step 3 — Select tracks:** Derive N sample indices (N = min(5, trackCount)) directly from the stable hash — compute index positions mathematically from hash bytes, no full shuffle. Retain only tracks with non-nil `artworkData`.

**Step 4 — Extract colors:** For each sampled track's `artworkData`, call `ArtworkColorExtractor.uiThemePalette(from:)`. Merge results into 3–5 representative colors.

**Step 5 — Sort by luminance:** Sort the representative colors from darkest to lightest before building the LUT.

**Step 6 — Build gradient LUT:** A luminance → color mapping. Grayscale 0.0 → darkest color, 1.0 → lightest color, intermediate values interpolate between adjacent stops. Represented as a 256-entry `[NSColor]` array.

**Step 7 — Recolor:** Apply LUT to the selected grayscale base image. For each pixel, sample the pixel's luminance from the grayscale base, look up the corresponding color in the LUT, write the result to an output bitmap context. Use CoreGraphics or vImage. Return as `NSImage`.

### Determinism

- Stable hash from `playlist.id.uuidString`
- Base image selection and track sampling both derived from the same hash
- Same playlist produces identical artwork across launches once a generated cover has been persisted. Content changes do not replace an existing generated cover except for the bootstrap transition from an empty playlist to a non-empty playlist, where the app regenerates the built-in cover if no custom cover is active.

### Cache Key

Generated playlist artwork is persisted on disk and exposed through an `artworkRevision` stored in the playlist sidecar. Header, halo, and Home card artwork requests include that revision in their identity, so saving a new generated or custom cover naturally invalidates the rendered derivatives without a separate cache path.

**Implementation:** `PlaylistArtworkGenerator` Swift actor generates the image. `LocalLibraryService.savePlaylistGeneratedArtwork` stores it and updates `artworkRevision` when generated artwork is the active source. If a playlist already has custom artwork, automatic generation can update the generated file but must not activate it or replace the custom cover.

### Threading

Generation runs in `Task.detached`. Result is published back on `@MainActor`.

### Fallback

If the playlist has zero tracks with artwork data, or if color extraction fails, or if recoloring fails for any reason: return the raw grayscale base image tinted with the app's accent color. The header must never show a broken or empty artwork state.

---

## Section 6: Scrolling Blurred Artwork Background Layer

### Placement

Inside `PlaylistDetailView`'s existing `ScrollView`, a background image sits behind the `LazyVStack`. It is positioned absolutely at the top of the scroll content so it scrolls naturally with the content — it is not a fixed window background.

### Structure

```
ScrollView
  ZStack(alignment: .top)
    BlurredArtworkBackgroundView(image: headerArtwork)  ← scrolls with content
    LazyVStack                                           ← track rows + header
```

`BlurredArtworkBackgroundView`:
- Takes `NSImage?`; shows nothing (clear) when nil
- Scales image to fill a large rect (e.g., `maxWidth: .infinity`, height ~500pt)
- Applies Gaussian blur (~40pt)
- Applies brightness/opacity adjustment: reuse `ArtworkColorExtractor` luminance logic to avoid blinding bright covers or muddying dark ones
- Gradient mask: fully opaque at top, fades to transparent at the bottom
- `.ignoresSafeArea()` to bleed under sidebar

### Source

`PlaylistDetailView` holds `@State private var headerArtwork: NSImage?`. The `LibraryDetailHeaderView` calls `onArtworkChange` whenever its artwork resolves or changes. This updates `headerArtwork`, which drives the background layer.

---

## Section 7: Missing Data Rules

These rules apply to all fields that don't yet exist in the current data model (year, descriptions):

1. **Read mode:** Display as empty string / blank text slot. Do not show "Unknown" labels. Do not collapse layout.
2. **Edit mode:** Show an editable text field. Accept user input.
3. **Persistence:** Wire through the correct entity (Playlist, ArtistEntry, AlbumEntry). Save on edit-mode commit.
4. **Layout stability:** The header visual structure is the same whether or not values are present.

---

## New Files

| File | Purpose |
|------|---------|
| `Models/ArtistEntry.swift` | In-memory artist metadata (loaded from sidecar) |
| `Models/AlbumEntry.swift` | In-memory album metadata (loaded from sidecar) |
| `Services/Library/LibraryMetadataSync.swift` | Sync derived groupings ↔ persistent entries |
| `Services/Library/PlaylistArtworkGenerator.swift` | Deterministic playlist cover generation actor |
| `Views/Library/LibraryDetailHeaderView.swift` | Shared detail header component |
| `Views/Library/BlurredArtworkBackgroundView.swift` | Scrolling blurred artwork background layer |

## Modified Files

| File | Changes |
|------|---------|
| `Utilities/LocalLibraryPaths.swift` | Add artists/albums path helpers |
| `Services/Library/LocalLibraryService.swift` | Add artist/album sidecar read/write, ensure folders |
| `Models/PlaylistSidecar` (in `LocalLibraryService.swift`) | Add `description: String?` |
| `Repositories/LibraryRepositoryProtocol.swift` | Add artist/album entry CRUD + playlist description update |
| `Repositories/SwiftDataLibraryRepository.swift` | Implement new protocol methods, call LibraryMetadataSync |
| `ViewModels/LibraryViewModel.swift` | Add `artistEntries`, `albumEntries`, save methods |
| `Views/Library/PlaylistDetailView.swift` | Inject header row + background layer, wire artwork callback |

---

## Temporary Limitations

- Artist real artwork: currently shows `person.fill` placeholder. `ArtistEntry` stores `artworkFileName`; UI and persistence are wired. Real artist artwork injection is a future step.
- Orphaned entries: entries with no songs but with user edits are kept in memory and on disk but not surfaced in the sidebar. A future cleanup UI can expose them.
- Album track ordering: tracks are shown in the existing sort order (same as current artist/album filter behavior in `PlaylistDetailView`). Track-number-based ordering is a future enhancement.
- `PlaylistSidecar` description field: schema version stays at `2`. A future schema bump is not needed since the field is optional and `decodeIfPresent` handles old files cleanly.
