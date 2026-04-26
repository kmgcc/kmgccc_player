# Home "View All" + Full Albums / Artists Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add small "View All" buttons in the Home page Albums/Artists section headers that open dedicated full-list pages (`AllAlbumsView`, `AllArtistsView`) inside the existing main content area, with row-based UI, search, sort, context menu / three-dot menu, and reuse of existing delete confirmation patterns.

**Architecture:**
- Two new `LibrarySelection` cases (`.allAlbums`, `.allArtists`) so the existing dispatcher in `AppKitMainContentPaneRoot` can swap to the new pages without introducing a parallel router.
- Generalize Home navigation push so drill-downs from the new pages still respect the existing back/forward pill (`UIStateViewModel.homeBackStack`).
- New SwiftUI views `AllAlbumsView` / `AllArtistsView` live in `myPlayer2/Views/Library/` and reuse `ArtworkLoader`, `ArtistArtworkGenerator`, `ArtworkPlaceholderView`, and the existing `libraryVM.deleteAlbum` / `libraryVM.deleteArtist` operations together with a confirmation alert mirroring `SidebarView`.

**Tech Stack:** SwiftUI, AppKit (NSImage), existing project services. macOS 26+ Xcode project with **filesystem-synchronized groups** — new `.swift` files in `myPlayer2/...` are picked up automatically (no `pbxproj` edits needed).

**Build verification command** (per project memory):
```bash
xcodebuild -project /Users/kmg/Documents/vscode/player/myPlayer2/kmgccc_player.xcodeproj \
  -target kmgccc_player -configuration Debug -destination 'platform=macOS' build \
  2>&1 | grep "error:" | grep -v "WhatsNewKit" | grep -v "lstat"
```
A clean build yields no output. Ignore SourceKit "Cannot find type X" noise — only `xcodebuild` results are authoritative.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `myPlayer2/ViewModels/LibraryViewModel.swift` | Modify | Add `.allAlbums` / `.allArtists` cases to `LibrarySelection`; extend all internal switches that exhaustively match it |
| `myPlayer2/ViewModels/UIStateViewModel.swift` | Modify | Add generalized `pushSelectionInHomeContext(_:libraryVM:)` so drill-downs from `.allAlbums` / `.allArtists` push correct back-stack entries |
| `myPlayer2/ViewModels/AppSessionHost.swift` | Modify | Extend the existing exhaustive switch over `LibrarySelection` to handle two new cases |
| `myPlayer2/Views/Lyrics/LyricsPanelView.swift` | Modify | Same: extend exhaustive switch for new cases |
| `myPlayer2/Views/Library/PlaylistDetailView.swift` | Modify | Extend `fallbackSelectionIdentity` switch for new cases |
| `myPlayer2/Views/Sidebar/SidebarView.swift` | Modify | Map new cases in the `currentSelection` translator switch (so sidebar highlight does not break) |
| `myPlayer2/AppKit/AppKitMainSplitPanes.swift` | Modify | Dispatch `.allAlbums` → `AllAlbumsView`, `.allArtists` → `AllArtistsView` in the content pane |
| `myPlayer2/Views/Home/HomeAlbumsSection.swift` | Modify | Add small trailing "查看全部" button in section header that calls `uiState.pushSelectionInHomeContext(.allAlbums, libraryVM:)` |
| `myPlayer2/Views/Home/HomeArtistsSection.swift` | Modify | Add same button → `.allArtists` |
| `myPlayer2/Views/Library/AllAlbumsView.swift` | Create | Full albums page: search field, sort menu, lazy row list, row context menu + three-dot menu, deletion confirmation alert |
| `myPlayer2/Views/Library/AllArtistsView.swift` | Create | Full artists page: same skeleton; uses artist entries and `ArtistArtworkGenerator` fallback |

---

## Task 1 — Extend `LibrarySelection` with `.allAlbums` and `.allArtists`

**Files:**
- Modify: `myPlayer2/ViewModels/LibraryViewModel.swift`

Add the two new enum cases and extend every switch in the file that exhaustively matches `LibrarySelection`. Treat both new cases as "non-track listing" — they behave like `.home` for sort/deletion concerns (no track-sort context, not affected by track deletes).

- [ ] **Step 1.1 — Add the cases to the enum**

In `LibraryViewModel.swift` (around line 121), update:

```swift
enum LibrarySelection: Hashable {
    case home
    case allSongs
    case allAlbums
    case allArtists
    case playlist(UUID)
    case artist(String)
    case album(String)
}
```

- [ ] **Step 1.2 — Extend `currentSelection.didSet` switch**

Around line 211, update the switch so the new cases clear the legacy `selectedPlaylistId` / `selectedArtistKey` / `selectedAlbumKey` (same as `.home`):

```swift
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
```

- [ ] **Step 1.3 — Extend `resetSelectionIfNeededAfterDeletingTracks` switch**

Around line 1192, replace:
```swift
case .home, .allSongs:
    return
```
with:
```swift
case .home, .allSongs, .allAlbums, .allArtists:
    return
```

- [ ] **Step 1.4 — Extend `reconcileSelectionAfterLoad` switch**

Around line 1237, replace:
```swift
case .home, .allSongs:
    break
```
with:
```swift
case .home, .allSongs, .allAlbums, .allArtists:
    break
```

- [ ] **Step 1.5 — Extend `currentSelectionIdentity` switch**

Around line 1264, add new identities matching the pattern:
```swift
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
```

- [ ] **Step 1.6 — Build to verify exhaustiveness**

Run the verification command at the top of this plan. Expect new "switch must be exhaustive" errors in `AppSessionHost.swift`, `LyricsPanelView.swift`, `PlaylistDetailView.swift`, `SidebarView.swift`, and `AppKitMainSplitPanes.swift`. Those are addressed in Tasks 2–6.

- [ ] **Step 1.7 — Commit**

```bash
git add myPlayer2/ViewModels/LibraryViewModel.swift
git commit -m "feat(library): add .allAlbums and .allArtists selection cases"
```

---

## Task 2 — Add generalized Home-context navigation push

**Files:**
- Modify: `myPlayer2/ViewModels/UIStateViewModel.swift`

`navigateFromHome` always pushes `.home` onto the back stack. We need to push the *current* selection so a user on `.allAlbums` who taps an album lands on `.album(key)` and Back returns to `.allAlbums`. Add a generalized method and have `navigateFromHome` call into it.

- [ ] **Step 2.1 — Add `pushSelectionInHomeContext` method**

In `UIStateViewModel.swift`, replace the existing `navigateFromHome` (around line 215) with the following two methods:

```swift
/// Push the current selection onto the Home back stack and switch to `target`.
/// Used both when starting drill-down from Home and when drilling further
/// from "All Albums" / "All Artists".
func pushSelectionInHomeContext(_ target: LibrarySelection, libraryVM: LibraryViewModel) {
    homeBackStack.append(libraryVM.currentSelection)
    homeForwardStack.removeAll()
    isHomeDrilldown = (target != .home)
    libraryVM.currentSelection = target
    showLibrary()
}

/// Navigate from Home to a target. Equivalent to `pushSelectionInHomeContext`
/// when the current selection is already `.home`.
func navigateFromHome(to target: LibrarySelection, libraryVM: LibraryViewModel) {
    pushSelectionInHomeContext(target, libraryVM: libraryVM)
}
```

(`navigateFromHome` is preserved for the existing call sites in `HomeAlbumsSection`, `HomeArtistsSection`, and `HomePlaylistsSection`. Behavior for those is unchanged because they are invoked while `currentSelection == .home`.)

- [ ] **Step 2.2 — Build**

Run the verification command. Expected: no new errors from this file.

- [ ] **Step 2.3 — Commit**

```bash
git add myPlayer2/ViewModels/UIStateViewModel.swift
git commit -m "feat(ui-state): generalize Home-context navigation push"
```

---

## Task 3 — Extend exhaustive `LibrarySelection` switches in remaining files

**Files:**
- Modify: `myPlayer2/ViewModels/AppSessionHost.swift`
- Modify: `myPlayer2/Views/Lyrics/LyricsPanelView.swift`
- Modify: `myPlayer2/Views/Library/PlaylistDetailView.swift`
- Modify: `myPlayer2/Views/Sidebar/SidebarView.swift`

Each file has a switch over `LibrarySelection` that the compiler now flags as non-exhaustive. Treat the two new cases the same as `.home` — they have no playable track context.

- [ ] **Step 3.1 — `AppSessionHost.swift` (around line 399)**

Read the file at line 395–415 first to see the exact shape. Then in the switch, fold the new cases into the existing `.home` branch (typically a `return nil` / `return .none` style branch):

```swift
case .home, .allAlbums, .allArtists:
    // existing .home body
```

If `.home` is not currently grouped with anything else, restructure to share the same body. Use the file's existing style for the change.

- [ ] **Step 3.2 — `LyricsPanelView.swift` (around line 191)**

Read lines 185–210. Extend:
```swift
case .home, .allAlbums, .allArtists:
    // existing .home body
```

- [ ] **Step 3.3 — `PlaylistDetailView.swift` `fallbackSelectionIdentity` (around line 158)**

Add the two cases explicitly (do not collapse — identities must be distinct strings):

```swift
private var fallbackSelectionIdentity: String {
    switch libraryVM.currentSelection {
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
```

- [ ] **Step 3.4 — `SidebarView.swift` (around line 548)**

Read lines 540–560 first. The `currentSelection` translator maps a `LibrarySelection` to a `SidebarSelection`. The new cases have no sidebar row, so map them to `.home` (so no sidebar row is highlighted, matching Home behavior):

```swift
switch libraryVM.currentSelection {
case .home, .allAlbums, .allArtists:
    return .home
case .allSongs:
    return .allSongs
case .playlist(let id):
    return .playlist(id)
case .artist(let key):
    return .artist(key)
case .album(let key):
    return .album(key)
}
```

- [ ] **Step 3.5 — Build**

Run the verification command. Expect one remaining exhaustiveness error in `AppKitMainSplitPanes.swift` (handled in Task 4) — actually that file uses `==` on `.home`, not a switch, so it may pass already. Confirm there are no errors.

- [ ] **Step 3.6 — Commit**

```bash
git add myPlayer2/ViewModels/AppSessionHost.swift \
        myPlayer2/Views/Lyrics/LyricsPanelView.swift \
        myPlayer2/Views/Library/PlaylistDetailView.swift \
        myPlayer2/Views/Sidebar/SidebarView.swift
git commit -m "chore: extend LibrarySelection switches for allAlbums/allArtists"
```

---

## Task 4 — Dispatch new selections in main content pane

**Files:**
- Modify: `myPlayer2/AppKit/AppKitMainSplitPanes.swift`

The dispatcher currently has two branches (`.home` → `HomeView`, otherwise → `PlaylistDetailView`). Change to a switch.

- [ ] **Step 4.1 — Replace the if/else with a switch (around line 95)**

Read lines 90–115 first. Replace:

```swift
if libraryVM.currentSelection == .home {
    HomeView()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-home")
} else {
    PlaylistDetailView(pageController: pageController)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-library")
}
```

with:

```swift
switch libraryVM.currentSelection {
case .home:
    HomeView()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-home")
case .allAlbums:
    AllAlbumsView()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-all-albums")
case .allArtists:
    AllArtistsView()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-all-artists")
case .allSongs, .playlist, .artist, .album:
    PlaylistDetailView(pageController: pageController)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id("appkit-main-library")
}
```

- [ ] **Step 4.2 — Confirm `shouldShowPlaylistHeaderBackground`**

Around line 407 the guard already excludes `.home`. Update it to also exclude the two new cases:

```swift
private var shouldShowPlaylistHeaderBackground: Bool {
    let selection = appSession.libraryVM?.currentSelection ?? .allSongs
    let isPlaylistContext: Bool
    switch selection {
    case .home, .allAlbums, .allArtists:
        isPlaylistContext = false
    case .allSongs, .playlist, .artist, .album:
        isPlaylistContext = true
    }
    return appSession.uiState.contentMode == .library
        && isPlaylistContext
        && playlistPageController.rendersHeaderBackgroundInWindowLayer
        && playlistPageController.isHeaderEffectsEnabled
        && (playlistPageController.haloCurrentImage != nil || playlistPageController.haloIncomingImage != nil)
        && !fullscreenWindowManager.usesFullscreenPlayerUI
}
```

- [ ] **Step 4.3 — Build**

Now expect compile errors: `Cannot find 'AllAlbumsView' / 'AllArtistsView' in scope`. That's expected — Tasks 5 and 6 create them. **Skip the commit until Task 6** (or do one big commit after Task 6).

---

## Task 5 — Create `AllAlbumsView`

**Files:**
- Create: `myPlayer2/Views/Library/AllAlbumsView.swift`

A spacious row-based list with search and sort, mirroring playlist visual rhythm but with larger artwork. Each row exposes a context menu and a trailing three-dot menu, both backed by `libraryVM.deleteAlbum` with a confirmation alert (mirrors `SidebarView` pattern).

**Reuses (verify in current code before assuming):**
- `libraryVM.albumEntries: [AlbumEntry]` — populated during library load
- `libraryVM.allTracks` — for fallback artwork
- `libraryVM.deleteAlbum(_:)` — existing safe deletion that removes all tracks under that album key with proper cleanup
- `ArtworkLoader.checksum / cacheKey / loadImage` — same artwork pipeline as Home
- `ArtworkPlaceholderView` — same placeholder used elsewhere
- `uiState.pushSelectionInHomeContext(.album(key), libraryVM:)` — drill-down keeps Home back-stack working

- [ ] **Step 5.1 — Create the file with the full implementation**

Write `myPlayer2/Views/Library/AllAlbumsView.swift`:

```swift
//
//  AllAlbumsView.swift
//  myPlayer2
//
//  Full Albums page reached from Home → Albums → "查看全部".
//  Lives in the main content area; reuses existing albumEntries,
//  deleteAlbum, and ArtworkLoader pipelines.
//

import AppKit
import SwiftUI

// MARK: - Sort Key

enum AlbumSortKey: String, CaseIterable, Identifiable {
    case title
    case artist
    case trackCount
    case totalDuration
    case updatedAt

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .title:         return "标题"
        case .artist:        return "艺人"
        case .trackCount:    return "歌曲数"
        case .totalDuration: return "总时长"
        case .updatedAt:     return "最近更新"
        }
    }
}

// MARK: - Deletion Request

private struct AlbumDeletionRequest: Identifiable {
    let entry: AlbumEntry
    let trackCount: Int
    var id: String { entry.id.uuidString }
}

// MARK: - View

struct AllAlbumsView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    @State private var searchText: String = ""
    @State private var sortKey: AlbumSortKey = .title
    @State private var sortAscending: Bool = true
    @State private var deletionRequest: AlbumDeletionRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            "删除专辑",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button("删除", role: .destructive) {
                let entry = request.entry
                deletionRequest = nil
                Task { await libraryVM.deleteAlbum(entry) }
            }
            Button("取消", role: .cancel) { deletionRequest = nil }
        } message: { request in
            Text("将从资料库中删除「\(request.entry.displayTitle)」及其 \(request.trackCount) 首歌曲。此操作无法撤销。")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("所有专辑")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)

            Text("\(filteredAlbums.count)")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()

            searchField
                .frame(maxWidth: 240)

            sortMenu
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索专辑或艺人", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortKey.allCases) { key in
                Button {
                    if sortKey == key {
                        sortAscending.toggle()
                    } else {
                        sortKey = key
                        sortAscending = true
                    }
                } label: {
                    HStack {
                        Text(key.localizedTitle)
                        if sortKey == key {
                            Spacer()
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
    }

    // MARK: List

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 4) {
                ForEach(filteredAlbums) { album in
                    AlbumListRow(
                        album: album,
                        trackCount: trackCount(for: album),
                        onOpen: { open(album) },
                        onDelete: { requestDelete(album) }
                    )
                }
                Color.clear.frame(height: 120) // mini-player headroom
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    // MARK: Data

    private var filteredAlbums: [AlbumEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [AlbumEntry]
        if trimmed.isEmpty {
            base = libraryVM.albumEntries
        } else {
            base = libraryVM.albumEntries.filter {
                $0.displayTitle.lowercased().contains(trimmed)
                || $0.primaryArtistDisplayName.lowercased().contains(trimmed)
            }
        }
        return base.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortKey {
            case .title:
                result = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            case .artist:
                result = lhs.primaryArtistDisplayName
                    .localizedCaseInsensitiveCompare(rhs.primaryArtistDisplayName)
            case .trackCount:
                result = compareInt(lhs.trackCount, rhs.trackCount)
            case .totalDuration:
                result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            case .updatedAt:
                result = compareDate(lhs.updatedAt, rhs.updatedAt)
            }
            if result == .orderedSame {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                    == .orderedAscending
            }
            return sortAscending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func trackCount(for album: AlbumEntry) -> Int {
        // albumEntries.trackCount is derived at sync time but may be 0 if disk
        // sidecar is fresher than derived stats. Recompute defensively.
        if album.trackCount > 0 { return album.trackCount }
        return libraryVM.allTracks.lazy
            .filter { $0.albumGroupKey == album.canonicalKey }
            .count
    }

    private func open(_ album: AlbumEntry) {
        libraryVM.selectedAlbumName = album.displayTitle
        uiState.pushSelectionInHomeContext(
            .album(album.canonicalKey),
            libraryVM: libraryVM
        )
    }

    private func requestDelete(_ album: AlbumEntry) {
        deletionRequest = AlbumDeletionRequest(
            entry: album,
            trackCount: trackCount(for: album)
        )
    }

    private func compareInt(_ a: Int, _ b: Int) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDouble(_ a: Double, _ b: Double) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDate(_ a: Date, _ b: Date) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}

// MARK: - Row

private struct AlbumListRow: View {
    let album: AlbumEntry
    let trackCount: Int
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 76
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 16) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering
                      ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        }
        .task { await loadArtwork() }
    }

    private var artworkView: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholderView(
                    size: artworkSize,
                    cornerRadius: cornerRadius,
                    clipShape: .continuous,
                    iconSize: 26,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 5, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(album.primaryArtistDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(trackCount) 首歌曲")
                if album.totalDuration > 0 {
                    Text("·")
                    Text(formattedDuration(album.totalDuration))
                }
                if let year = album.year, year > 0 {
                    Text("·")
                    Text(String(year))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .opacity(isHovering ? 1 : 0.4)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    private func loadArtwork() async {
        var data = album.artworkData
        if data == nil || data!.isEmpty {
            let key = album.canonicalKey
            if let firstTrack = libraryVM.allTracks.first(where: { $0.albumGroupKey == key }) {
                data = await Task.detached { firstTrack.loadArtworkDataIfNeeded() }.value
            }
        }
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: album.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 168, height: 168)
        )
        image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 168, height: 168)
        )
    }
}
```

- [ ] **Step 5.2 — Build**

Run the verification command. Expected: only the `AllArtistsView` "Cannot find" error remains (covered in Task 6).

- [ ] **Step 5.3 — Commit (with Task 6's view to keep build green)**

Defer the commit until after Task 6 so a single buildable commit lands. Skip git commands for now.

---

## Task 6 — Create `AllArtistsView`

**Files:**
- Create: `myPlayer2/Views/Library/AllArtistsView.swift`

Mirrors `AllAlbumsView` structure. Uses `libraryVM.artistEntries`, `libraryVM.deleteArtist`, and the `ArtistArtworkGenerator` fallback (same as Home).

- [ ] **Step 6.1 — Create the file**

Write `myPlayer2/Views/Library/AllArtistsView.swift`:

```swift
//
//  AllArtistsView.swift
//  myPlayer2
//
//  Full Artists page reached from Home → Artists → "查看全部".
//  Lives in the main content area; reuses existing artistEntries,
//  deleteArtist, and ArtistArtworkGenerator pipelines.
//

import AppKit
import SwiftUI

// MARK: - Sort Key

enum ArtistSortKey: String, CaseIterable, Identifiable {
    case name
    case albumCount
    case trackCount
    case totalDuration
    case updatedAt

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .name:          return "名称"
        case .albumCount:    return "专辑数"
        case .trackCount:    return "歌曲数"
        case .totalDuration: return "总时长"
        case .updatedAt:     return "最近更新"
        }
    }
}

// MARK: - Deletion Request

private struct ArtistDeletionRequest: Identifiable {
    let entry: ArtistEntry
    let trackCount: Int
    var id: String { entry.id.uuidString }
}

// MARK: - View

struct AllArtistsView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    @State private var searchText: String = ""
    @State private var sortKey: ArtistSortKey = .name
    @State private var sortAscending: Bool = true
    @State private var deletionRequest: ArtistDeletionRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            "删除歌手",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button("删除", role: .destructive) {
                let entry = request.entry
                deletionRequest = nil
                Task { await libraryVM.deleteArtist(entry) }
            }
            Button("取消", role: .cancel) { deletionRequest = nil }
        } message: { request in
            Text("将从资料库中删除「\(request.entry.displayName)」及其 \(request.trackCount) 首歌曲。此操作无法撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("所有歌手")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)

            Text("\(filteredArtists.count)")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()

            searchField
                .frame(maxWidth: 240)

            sortMenu
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索歌手", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ArtistSortKey.allCases) { key in
                Button {
                    if sortKey == key {
                        sortAscending.toggle()
                    } else {
                        sortKey = key
                        sortAscending = true
                    }
                } label: {
                    HStack {
                        Text(key.localizedTitle)
                        if sortKey == key {
                            Spacer()
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 4) {
                ForEach(filteredArtists) { artist in
                    ArtistListRow(
                        artist: artist,
                        trackCount: trackCount(for: artist),
                        onOpen: { open(artist) },
                        onDelete: { requestDelete(artist) }
                    )
                }
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    private var filteredArtists: [ArtistEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [ArtistEntry]
        if trimmed.isEmpty {
            base = libraryVM.artistEntries
        } else {
            base = libraryVM.artistEntries.filter {
                $0.displayName.lowercased().contains(trimmed)
            }
        }
        return base.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortKey {
            case .name:
                result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            case .albumCount:
                result = compareInt(lhs.albumCount, rhs.albumCount)
            case .trackCount:
                result = compareInt(lhs.trackCount, rhs.trackCount)
            case .totalDuration:
                result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            case .updatedAt:
                result = compareDate(lhs.updatedAt, rhs.updatedAt)
            }
            if result == .orderedSame {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
            return sortAscending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func trackCount(for artist: ArtistEntry) -> Int {
        if artist.trackCount > 0 { return artist.trackCount }
        let key = artist.canonicalName
        return libraryVM.allTracks.lazy
            .filter { LibraryNormalization.normalizeArtist($0.artist) == key }
            .count
    }

    private func open(_ artist: ArtistEntry) {
        uiState.pushSelectionInHomeContext(
            .artist(artist.canonicalName),
            libraryVM: libraryVM
        )
    }

    private func requestDelete(_ artist: ArtistEntry) {
        deletionRequest = ArtistDeletionRequest(
            entry: artist,
            trackCount: trackCount(for: artist)
        )
    }

    private func compareInt(_ a: Int, _ b: Int) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDouble(_ a: Double, _ b: Double) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDate(_ a: Date, _ b: Date) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}

// MARK: - Row

private struct ArtistListRow: View {
    let artist: ArtistEntry
    let trackCount: Int
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 76

    var body: some View {
        HStack(spacing: 16) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering
                      ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(action: onOpen) {
                Label("打开歌手", systemImage: "person.crop.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除歌手", systemImage: "trash")
            }
        }
        .task { await loadArtwork() }
    }

    private var artworkView: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholderView(
                    size: artworkSize,
                    clipShape: .circle,
                    iconSize: 24,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(Circle())
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 5, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(artist.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(artist.albumCount) 张专辑")
                Text("·")
                Text("\(trackCount) 首歌曲")
                if artist.totalDuration > 0 {
                    Text("·")
                    Text(formattedDuration(artist.totalDuration))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开歌手", systemImage: "person.crop.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除歌手", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .opacity(isHovering ? 1 : 0.4)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    private func loadArtwork() async {
        if let data = artist.artworkData, !data.isEmpty {
            let checksum = ArtworkLoader.checksum(for: data)
            let key = ArtworkLoader.cacheKey(
                trackID: artist.id,
                checksum: checksum,
                targetPixelSize: CGSize(width: 168, height: 168)
            )
            image = await ArtworkLoader.loadImage(
                artworkData: data,
                cacheKey: key,
                targetPixelSize: CGSize(width: 168, height: 168)
            )
            return
        }

        let canonical = artist.canonicalName
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.normalizeArtist($0.artist) == canonical
        }
        image = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: artist.displayName,
            tracks: tracks
        )
    }
}
```

- [ ] **Step 6.2 — Build**

Run the verification command. Expected: clean build (no errors after filtering WhatsNewKit/lstat noise).

- [ ] **Step 6.3 — Commit Tasks 4–6 together**

```bash
git add myPlayer2/AppKit/AppKitMainSplitPanes.swift \
        myPlayer2/Views/Library/AllAlbumsView.swift \
        myPlayer2/Views/Library/AllArtistsView.swift
git commit -m "feat(library): add AllAlbumsView and AllArtistsView pages"
```

---

## Task 7 — Wire "View All" buttons in Home Albums/Artists section headers

**Files:**
- Modify: `myPlayer2/Views/Home/HomeAlbumsSection.swift`
- Modify: `myPlayer2/Views/Home/HomeArtistsSection.swift`

A small subtle trailing button labeled `查看全部 ›`.

- [ ] **Step 7.1 — Update `HomeAlbumsSection.sectionHeader`**

Replace the current `sectionHeader` (around line 46 of `HomeAlbumsSection.swift`):

```swift
private var sectionHeader: some View {
    HStack(alignment: .firstTextBaseline) {
        Text("专辑")
            .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
            .tracking(-0.3)
        Spacer()
        viewAllButton
    }
}

private var viewAllButton: some View {
    Button {
        uiState.pushSelectionInHomeContext(.allAlbums, libraryVM: libraryVM)
    } label: {
        HStack(spacing: 2) {
            Text("查看全部")
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("查看全部专辑")
}
```

- [ ] **Step 7.2 — Update `HomeArtistsSection.sectionHeader`**

Same pattern in `HomeArtistsSection.swift` (around line 45). Title text stays `"歌手"`. Button target is `.allArtists`. Tooltip `"查看全部歌手"`.

```swift
private var sectionHeader: some View {
    HStack(alignment: .firstTextBaseline) {
        Text("歌手")
            .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
            .tracking(-0.3)
        Spacer()
        viewAllButton
    }
}

private var viewAllButton: some View {
    Button {
        uiState.pushSelectionInHomeContext(.allArtists, libraryVM: libraryVM)
    } label: {
        HStack(spacing: 2) {
            Text("查看全部")
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("查看全部歌手")
}
```

- [ ] **Step 7.3 — Build**

Run the verification command. Expect a clean build.

- [ ] **Step 7.4 — Commit**

```bash
git add myPlayer2/Views/Home/HomeAlbumsSection.swift \
        myPlayer2/Views/Home/HomeArtistsSection.swift
git commit -m "feat(home): add 'View All' buttons to Albums and Artists sections"
```

---

## Task 8 — Manual smoke verification

These are GUI checks the engineer must perform after a clean build. The project has no automated test target, so the verification ladder is build → manual.

- [ ] **Step 8.1 — Build clean**

Run the verification command. Confirm zero errors after the `WhatsNewKit`/`lstat` filter.

- [ ] **Step 8.2 — Run the app and verify**

Launch in Xcode (or `open kmgccc_player.xcodeproj` then ⌘R). Check:

1. Home page renders. Albums section shows "查看全部 ›" on the right.
2. Artists section shows the same.
3. Click "查看全部" on Albums → main pane swaps to All Albums page; toolbar Home back-pill is visible; clicking ‹ Back returns to Home.
4. Type in the search field → list filters live.
5. Open the sort menu → cycling a sort key reorders rows; reselecting toggles ascending/descending.
6. Click a row → drills into that album's detail page; ‹ Back returns to All Albums (NOT to Home).
7. Right-click a row → context menu has "删除专辑". Trailing ⋯ button shows the same menu.
8. Trigger delete → confirmation alert appears; Cancel leaves the album in place; Delete removes the album and all its tracks; the page updates.
9. Repeat the same steps on the Artists section / All Artists page.
10. From All Artists, drill into an artist, ‹ Back twice returns through All Artists → Home.

- [ ] **Step 8.3 — If any step fails, file the diagnosis inline**

Do **not** suppress the issue or "patch around it." If a delete leaves stale rows, the underlying `libraryVM.delete*` path or `albumEntries` refresh trigger should be the diagnostic target — investigate before patching the new view.

- [ ] **Step 8.4 — Final report**

Report (per spec section 9):
1. Modified / created files (already enumerated in commits above).
2. Navigation: new `LibrarySelection` cases dispatched in `AppKitMainSplitPanes`; new `pushSelectionInHomeContext` so drill-down depth ≥ 2 still respects the Home back-stack.
3. Search & sort: in-view `TextField` + SwiftUI `Menu` with `arrow.up.arrow.down` icon, mirroring the toolbar sort affordance but operating on `albumEntries` / `artistEntries` instead of tracks. Live filter; reselecting the same key toggles ascending.
4. Delete behavior: reuses existing `libraryVM.deleteAlbum(_:)` / `libraryVM.deleteArtist(_:)` — *not* a new code path. Confirmation alert mirrors the Sidebar pattern. The underlying repository methods already cascade to the album/artist's tracks with playback cleanup, cache invalidation, and selection reconciliation, so no new "safe placeholder" was needed.

---

## Self-Review Checklist

Run these against the final plan before execution:

- [x] **Spec coverage:**
  - §1 Home section "View All" buttons → Task 7.
  - §2 Dedicated full Albums/Artists pages → Tasks 5, 6.
  - §3 Album row design (artwork, title, artist, count, duration, year, ⋯, fallback artwork pipeline reuse) → Task 5.
  - §4 Artist row design (artist image w/ fallback generator, name, album count, song count, duration, ⋯) → Task 6.
  - §5 Sorting and search → Tasks 5, 6 (`searchField` + `sortMenu`).
  - §6 Navigation/selection model → Tasks 1, 2, 3, 4.
  - §7 Visual style (spacious rows, subtle hover, soft, lazy) → Tasks 5, 6 (`LazyVStack`, hover background, no heavy blur).
  - §8 Performance → Tasks 5, 6 (`LazyVStack`, `ArtworkLoader` cache, `Task.detached` for first-track artwork).
  - §9 Build & report → Task 8.
- [x] **No placeholders:** every step has the actual code or exact replacement.
- [x] **Type consistency:** `pushSelectionInHomeContext` introduced in Task 2 is used in Tasks 5, 6, 7. `AlbumSortKey`/`ArtistSortKey`/`AlbumDeletionRequest`/`ArtistDeletionRequest` are defined alongside the views that use them.
- [x] **Filesystem-synchronized groups:** confirmed — no `pbxproj` edit step required.
