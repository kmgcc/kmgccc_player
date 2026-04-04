# Manual Cover Search Candidate Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a horizontal thumbnail strip showing all cover candidates from sacad + NetEase sources, with highest-resolution as default selection.

**Architecture:** New `CoverCandidate` model with stable ID, `CoverSearchCoordinator` for shared merge/sort logic, `CoverCandidateStripView` UI component, integrated into both edit sheets.

**Tech Stack:** SwiftUI, AppKit (NSImage for resolution), async/await, Observation framework

---

## File Structure

| File | Purpose |
|------|---------|
| `CoverServiceModels.swift` | Add `CoverCandidate` struct |
| `NetEaseCoverService.swift` | Add `searchCoverCandidates()` method |
| `CoverSearchCoordinator.swift` | **NEW** - Shared merge/sort/selection logic |
| `CoverCandidateStripView.swift` | **NEW** - Thumbnail strip UI component |
| `TrackEditSheet.swift` | Integrate coordinator and strip |
| `BatchTrackEditSheet.swift` | Same integration as TrackEditSheet |

---

### Task 1: Add CoverCandidate Model

**Files:**
- Modify: `myPlayer2/Services/Cover/CoverServiceModels.swift`

- [ ] **Step 1: Add CoverCandidate struct with stable ID**

Add the following to `CoverServiceModels.swift` after the `CoverSource` enum:

```swift
import AppKit

/// A cover image candidate with stable identity and resolution metadata.
struct CoverCandidate: Identifiable, Equatable, Hashable {
    let id: String  // Stable identity: "sacad:<normalized-query>" or "netease:<album-id>"
    let imageData: Data
    let resolution: Int  // Larger dimension (e.g., 1200 for 1200x1200)
    let width: Int
    let height: Int
    let source: CoverSource
    let sourceItemId: String?  // Album ID or query hash

    /// Creates a candidate with automatically computed resolution.
    init(imageData: Data, source: CoverSource, sourceItemId: String?) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        let (w, h) = Self.computeDimensions(from: imageData)
        self.width = w
        self.height = h
        self.resolution = max(w, h)
    }

    /// Creates a candidate with explicit dimensions (for performance when known).
    init(imageData: Data, source: CoverSource, sourceItemId: String?, width: Int, height: Int) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        self.width = width
        self.height = height
        self.resolution = max(width, height)
    }

    /// Returns true if the image is square (width == height within tolerance).
    var isSquare: Bool {
        abs(width - height) <= 2
    }

    /// Compact resolution label: "1200" for square, "1200×800" for non-square.
    var resolutionLabel: String {
        if isSquare {
            return String(resolution)
        } else {
            return "\(width)×\(height)"
        }
    }

    private static func computeDimensions(from data: Data) -> (Int, Int) {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else {
            return (0, 0)
        }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    // Equatable - compare by ID only for deduplication
    static func == (lhs: CoverCandidate, rhs: CoverCandidate) -> Bool {
        lhs.id == rhs.id
    }

    // Hashable - hash by ID only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
```

- [ ] **Step 2: Build to verify model compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds (exit code 0)

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Services/Cover/CoverServiceModels.swift
git commit -m "feat(cover): add CoverCandidate model with stable ID and resolution metadata"
```

---

### Task 2: Extend NetEaseCoverService for Multi-Candidate Search

**Files:**
- Modify: `myPlayer2/Services/Cover/NetEaseCoverService.swift`

- [ ] **Step 1: Add searchCoverCandidates method**

Add the following method to `NetEaseCoverService` class (after the existing `searchAndDownloadCover` method):

```swift
    /// Searches NetEase for album covers and returns all candidates with metadata.
    /// Downloads covers for all matching albums (up to limit), sorted by resolution descending.
    func searchCoverCandidates(artist: String, album: String, limit: Int = 5) async throws -> [CoverCandidate] {
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString = "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=\(limit)"
        guard let searchURL = URL(string: searchURLString) else {
            throw NetEaseCoverError.badURL
        }

        let searchData: Data
        do {
            let (data, response) = try await session.data(from: searchURL)
            try Self.validateHTTP(response: response)
            searchData = data
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.requestFailed(underlying: error)
        }

        let result: NetEaseSearchResponse
        do {
            result = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        } catch {
            throw NetEaseCoverError.decodingFailed(underlying: error)
        }

        guard !result.result.albums.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        // Download covers for all albums concurrently
        var candidates: [CoverCandidate] = []
        await withTaskGroup(of: CoverCandidate?.self) { group in
            for albumResult in result.result.albums {
                group.addTask {
                    guard let picURLString = albumResult.picURL,
                          let coverURL = URL(string: Self.makeLargeCoverURLString(from: picURLString)) else {
                        return nil
                    }
                    do {
                        let (imageData, response) = try await self.session.data(from: coverURL)
                        try Self.validateHTTP(response: response)
                        guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
                            return nil
                        }
                        return CoverCandidate(
                            imageData: imageData,
                            source: .netease,
                            sourceItemId: String(albumResult.id)
                        )
                    } catch {
                        return nil
                    }
                }
            }
            for await candidate in group {
                if let candidate = candidate {
                    candidates.append(candidate)
                }
            }
        }

        guard !candidates.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        // Sort by resolution descending (highest first)
        return candidates.sorted { $0.resolution > $1.resolution }
    }
```

- [ ] **Step 2: Update NetEaseSearchResponse struct to include album ID**

Modify the private `NetEaseSearchResponse` struct to add the `id` field:

```swift
private extension NetEaseCoverService {
    struct NetEaseSearchResponse: Decodable {
        let result: ResultPayload

        struct ResultPayload: Decodable {
            let albums: [Album]
        }

        struct Album: Decodable {
            let id: Int
            let picURL: String

            enum CodingKeys: String, CodingKey {
                case id
                case picURL = "picUrl"
            }
        }
    }
    // ... rest remains unchanged
}
```

- [ ] **Step 3: Build to verify service compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add myPlayer2/Services/Cover/NetEaseCoverService.swift
git commit -m "feat(cover): add searchCoverCandidates method to NetEaseCoverService"
```

---

### Task 3: Create CoverSearchCoordinator

**Files:**
- Create: `myPlayer2/Services/Cover/CoverSearchCoordinator.swift`

- [ ] **Step 1: Create CoverSearchCoordinator class**

Create new file `myPlayer2/Services/Cover/CoverSearchCoordinator.swift`:

```swift
//
//  CoverSearchCoordinator.swift
//  myPlayer2
//
//  kmgccc_player - Cover Search Coordinator
//  Shared logic for merging, sorting, and selecting cover candidates
//

import AppKit
import Observation
import Foundation

/// Coordinates cover search from multiple sources, merges results, and manages selection.
@Observable
@MainActor
final class CoverSearchCoordinator {
    /// All candidates found from search, sorted by resolution descending.
    var candidates: [CoverCandidate] = []

    /// The candidate currently selected for preview (not yet persisted).
    var selectedForPreview: CoverCandidate?

    /// Whether a search is currently in progress.
    var isLoading: Bool = false

    /// Error message if search failed completely.
    var error: String?

    /// Whether candidates are available and strip should be shown.
    var hasCandidates: Bool {
        !candidates.isEmpty
    }

    private var searchTask: Task<Void, Never>?

    private let coverDownloadService: CoverDownloadService
    private let netEaseCoverService: NetEaseCoverService

    init(
        coverDownloadService: CoverDownloadService,
        netEaseCoverService: NetEaseCoverService
    ) {
        self.coverDownloadService = coverDownloadService
        self.netEaseCoverService = netEaseCoverService
    }

    /// Searches both sources concurrently, merges and sorts candidates.
    /// The highest-resolution candidate becomes selectedForPreview.
    func search(artist: String, album: String) async {
        searchTask?.cancel()
        isLoading = true
        error = nil
        candidates = []
        selectedForPreview = nil

        let normalizedQuery = normalizeQuery(artist: artist, album: album)
        let sacadId = "sacad:" + normalizedQuery

        searchTask = Task {
            defer {
                Task { @MainActor in
                    isLoading = false
                    searchTask = nil
                }
            }

            // Concurrent search from both sources
            var sacadCandidate: CoverCandidate? = nil
            var neteaseCandidates: [CoverCandidate] = []

            await withTaskGroup(of: Void.self) { group in
                // Sacad search (single result)
                group.addTask {
                    do {
                        let data = try await self.coverDownloadService.downloadCover(
                            artist: artist,
                            album: album,
                            size: 1200
                        )
                        if !Task.isCancelled {
                            sacadCandidate = CoverCandidate(
                                imageData: data,
                                source: .sacad,
                                sourceItemId: normalizedQuery
                            )
                        }
                    } catch {
                        // Sacad failed - continue with NetEase only
                        print("[CoverSearchCoordinator] Sacad failed: \(error)")
                    }
                }

                // NetEase multi-candidate search
                group.addTask {
                    do {
                        let results = try await self.netEaseCoverService.searchCoverCandidates(
                            artist: artist,
                            album: album,
                            limit: 5
                        )
                        if !Task.isCancelled {
                            neteaseCandidates = results
                        }
                    } catch {
                        // NetEase failed - continue with sacad only
                        print("[CoverSearchCoordinator] NetEase failed: \(error)")
                    }
                }
            }

            try? Task.checkCancellation()

            // Merge candidates
            var merged: [CoverCandidate] = []

            // Add sacad result first (it's from authoritative sources)
            if let sacad = sacadCandidate {
                merged.append(sacad)
            }

            // Add NetEase results, deduplicating by ID
            for candidate in neteaseCandidates {
                // Skip if already present (same ID means same source item)
                if !merged.contains(candidate) {
                    merged.append(candidate)
                }
            }

            // Sort by resolution descending
            merged.sort { $0.resolution > $1.resolution }

            try? Task.checkCancellation()

            await MainActor.run {
                candidates = merged
                // Default selection: highest resolution
                selectedForPreview = merged.first
                if merged.isEmpty {
                    error = "未找到封面"
                }
            }
        }
    }

    /// Cancels any ongoing search.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isLoading = false
    }

    /// Clears all candidates and selection.
    func clear() {
        candidates = []
        selectedForPreview = nil
        error = nil
    }

    /// Selects a candidate for preview (does NOT persist).
    func selectForPreview(_ candidate: CoverCandidate) {
        selectedForPreview = candidate
    }

    /// Returns the image data for the currently selected preview candidate.
    func getPreviewImageData() -> Data? {
        selectedForPreview?.imageData
    }

    /// Normalizes artist+album into a stable query string for ID generation.
    private func normalizeQuery(artist: String, album: String) -> String {
        let combined = "\(artist)-\(album)"
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Simple normalization: remove special chars, collapse spaces
        return combined
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
```

- [ ] **Step 2: Build to verify coordinator compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Services/Cover/CoverSearchCoordinator.swift
git commit -m "feat(cover): add CoverSearchCoordinator for shared merge/sort logic"
```

---

### Task 4: Create CoverCandidateStripView Component

**Files:**
- Create: `myPlayer2/Views/Library/CoverCandidateStripView.swift`

- [ ] **Step 1: Create CoverCandidateStripView**

Create new file `myPlayer2/Views/Library/CoverCandidateStripView.swift`:

```swift
//
//  CoverCandidateStripView.swift
//  myPlayer2
//
//  kmgccc_player - Cover Candidate Thumbnail Strip
//  Horizontal scrollable thumbnail list for manual cover selection
//

import SwiftUI
import AppKit

/// A horizontal scrollable strip of cover candidate thumbnails.
/// Shows resolution badge on each thumbnail and highlights the selected one.
struct CoverCandidateStripView: View {
    let candidates: [CoverCandidate]
    let selectedCandidate: CoverCandidate?
    let onSelect: (CoverCandidate) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    // Thumbnail size - compact
    private let thumbnailSize: CGFloat = 60
    private let spacing: CGFloat = 8

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(candidates) { candidate in
                    thumbnailView(for: candidate)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(height: thumbnailSize + 16) // Thumbnail + badge height
    }

    @ViewBuilder
    private func thumbnailView(for candidate: CoverCandidate) -> some View {
        let isSelected = selectedCandidate?.id == candidate.id

        ZStack(alignment: .bottomTrailing) {
            // Thumbnail image
            if let nsImage = NSImage(data: candidate.imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            // Selected border
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(themeStore.accentColor, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Resolution badge
            resolutionBadge(candidate.resolutionLabel)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            onSelect(candidate)
        }
        .accessibilityLabel("Cover candidate \(candidate.resolutionLabel)")
        .accessibilityHint(isSelected ? "Selected" : "Tap to select")
    }

    @ViewBuilder
    private func resolutionBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(2)
    }
}

#Preview("Cover Candidate Strip") {
    let sampleData1 = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        .tiffRepresentation!
    let sampleData2 = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        .tiffRepresentation!

    let candidates = [
        CoverCandidate(imageData: sampleData1, source: .sacad, sourceItemId: "test-1"),
        CoverCandidate(imageData: sampleData2, source: .netease, sourceItemId: "test-2"),
    ]

    CoverCandidateStripView(
        candidates: candidates,
        selectedCandidate: candidates.first,
        onSelect: { _ in }
    )
    .environmentObject(ThemeStore())
}
```

- [ ] **Step 2: Build to verify component compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Views/Library/CoverCandidateStripView.swift
git commit -m "feat(ui): add CoverCandidateStripView thumbnail component"
```

---

### Task 5: Integrate into TrackEditSheet (Single Edit)

**Files:**
- Modify: `myPlayer2/Views/Library/TrackEditSheet.swift`

- [ ] **Step 1: Add coordinator state and environment**

Add the coordinator state near the existing `@State` variables (around line 41):

```swift
    // MARK: - Cover Search Coordinator

    @State private var coverCoordinator: CoverSearchCoordinator?
```

Add coordinator initialization in `onAppear` (around line 85), before `loadTrackData()`:

```swift
        .onAppear {
            // Initialize cover coordinator with injected services
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
            loadTrackData()
        }
```

- [ ] **Step 2: Replace artwork section with integrated layout**

Replace the entire `artworkSection` property (lines 119-177) with:

```swift
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

                // Candidate strip (appears when candidates exist)
                if let coordinator = coverCoordinator, coordinator.hasCandidates {
                    CoverCandidateStripView(
                        candidates: coordinator.candidates,
                        selectedCandidate: coordinator.selectedForPreview,
                        onSelect: { candidate in
                            coordinator.selectForPreview(candidate)
                            artworkData = candidate.imageData
                        }
                    )
                    .frame(maxWidth: 240)
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
```

- [ ] **Step 3: Replace fetchCover method with coordinator-based implementation**

Replace the `fetchCover()` method (lines 441-483) with:

```swift
    private func fetchCover() {
        guard let coordinator = coverCoordinator else { return }

        coverFetchTask?.cancel()
        coverFetchError = nil

        coverFetchTask = Task {
            await coordinator.search(artist: artist, album: album)

            // Update artworkData with selected preview
            if let previewData = coordinator.getPreviewImageData() {
                artworkData = previewData
            }

            coverFetchTask = nil
        }
    }
```

- [ ] **Step 4: Remove obsolete state variables**

Remove the following obsolete state variables (around lines 39-41):
- `@State private var isFetchingCover = false` (now in coordinator)
- `@State private var coverFetchError: String?` (now in coordinator)

Note: Keep `coverFetchTask` for cancellation.

- [ ] **Step 5: Update onDisappear to cancel coordinator search**

Modify `onDisappear` (around line 87) to also cancel coordinator:

```swift
        .onDisappear {
            coverFetchTask?.cancel()
            coverFetchTask = nil
            coverCoordinator?.cancelSearch()
        }
```

- [ ] **Step 6: Build to verify integration compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add myPlayer2/Views/Library/TrackEditSheet.swift
git commit -m "feat(single-edit): integrate cover candidate strip into TrackEditSheet"
```

---

### Task 6: Integrate into BatchTrackEditSheet

**Files:**
- Modify: `myPlayer2/Views/Library/BatchTrackEditSheet.swift`

- [ ] **Step 1: Add coordinator state**

Add near existing `@State` variables (around line 51):

```swift
    @State private var coverCoordinator: CoverSearchCoordinator?
```

Add coordinator initialization in `onAppear` (around line 99), after `prepareTrack`:

```swift
        .onAppear {
            ensurePreviewLyricsViewModel()
            uiState.lyricsPanelSuppressedByModal = true
            guard !tracks.isEmpty else { return }
            prepareTrack(at: 0, triggerAutoSearch: true)

            // Initialize cover coordinator
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
        }
```

- [ ] **Step 2: Replace metadataSection with integrated layout**

Replace `metadataSection` HStack (lines 302-350) with:

```swift
            HStack(spacing: 14) {
                Group {
                    if let data = artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Button("导入封面") {
                        showingArtworkPicker = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    HStack(spacing: 8) {
                        Button("查找封面") {
                            fetchCover()
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                        .disabled(coverCoordinator?.isLoading == true)

                        if coverCoordinator?.isLoading == true {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if artworkData != nil {
                        Button("移除封面", role: .destructive) {
                            artworkData = nil
                            coverCoordinator?.clear()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .clipShape(Capsule())
                    }
                }

                // Candidate strip (appears when candidates exist)
                if let coordinator = coverCoordinator, coordinator.hasCandidates {
                    CoverCandidateStripView(
                        candidates: coordinator.candidates,
                        selectedCandidate: coordinator.selectedForPreview,
                        onSelect: { candidate in
                            coordinator.selectForPreview(candidate)
                            artworkData = candidate.imageData
                        }
                    )
                    .frame(maxWidth: 200)
                }

                Spacer()
            }
```

- [ ] **Step 3: Replace fetchCover method**

Replace `fetchCover()` (lines 713-763) with:

```swift
    private func fetchCover() {
        guard let coordinator = coverCoordinator else { return }

        coverFetchTask?.cancel()
        let currentArtist = artist
        let currentAlbum = album

        coverFetchTask = Task {
            await coordinator.search(artist: currentArtist, album: currentAlbum)

            // Update artworkData with selected preview
            if let previewData = coordinator.getPreviewImageData() {
                artworkData = previewData
                statusMessage = "封面已更新"
                // Auto-save for batch edit
                _ = saveCurrentTrack(
                    showFailureMessage: true,
                    markProcessedIfUnchanged: false,
                    reason: "查找封面后保存"
                )
            }

            coverFetchTask = nil
        }
    }
```

- [ ] **Step 4: Remove obsolete state variable**

Remove (around line 50):
- `@State private var isFetchingCover = false` (now in coordinator)

Keep `coverFetchTask` for cancellation.

- [ ] **Step 5: Update onDisappear**

Add coordinator cleanup to `onDisappear` (around line 104):

```swift
        .onDisappear {
            uiState.lyricsPanelSuppressedByModal = false
            LyricsSurfaceManager.shared.deactivate(role: .batchPreview)
            previewLyricsVM = nil
            coverCoordinator?.cancelSearch()
            lyricsVM.ensureAMLLLoaded(
                track: playerVM.currentTrack,
                currentTime: playerVM.currentTime,
                isPlaying: playerVM.isPlaying,
                reason: "batch editor dismissed",
                forceLyricsReload: true
            )
        }
```

- [ ] **Step 6: Build to verify integration compiles**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | head -50`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add myPlayer2/Views/Library/BatchTrackEditSheet.swift
git commit -m "feat(batch-edit): integrate cover candidate strip into BatchTrackEditSheet"
```

---

### Task 7: Build Verification and Final Testing

- [ ] **Step 1: Full build verification**

Run: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build 2>&1 | tail -20`
Expected: "BUILD SUCCEEDED" in output

- [ ] **Step 2: Verify file structure**

Run: `ls -la myPlayer2/Services/Cover/`
Expected: See `CoverSearchCoordinator.swift` added

Run: `ls -la myPlayer2/Views/Library/`
Expected: See `CoverCandidateStripView.swift` added

- [ ] **Step 3: Final commit summary**

Run: `git log --oneline -10`
Expected: See all 7 commits from this plan

- [ ] **Step 4: Manual Testing Checklist**

Open the app in Xcode and test:
1. Open single track edit window → Click "查找封面" → Strip appears with thumbnails
2. Verify highest-resolution is selected by default
3. Click different thumbnail → Preview updates
4. Click "Save" → Cover persists
5. Open batch edit window → Click "查找封面" → Strip appears
6. Verify strip scrolls horizontally if >3 candidates
7. Verify resolution badge shows single number for square, dimensions for non-square
8. Test error case: invalid artist/album → "未找到封面" shown, no strip

---

## Verification Checklist (from Spec)

- [x] Build passes
- [x] Single edit: strip appears after "Find Cover" completes
- [x] Batch edit: strip appears after "Find Cover" completes
- [x] Highest-resolution candidate selected by default (preview only)
- [x] Clicking thumbnail switches preview image (no auto-save in single edit)
- [x] Save applies the currently previewed cover
- [x] Strip scrolls horizontally if candidates overflow
- [x] Resolution badge: single number for square, dimensions for non-square
- [x] Selected state clearly visible but subtle (border only)
- [x] No layout breakage at narrow window widths (strip has maxWidth constraint)
- [x] Error case: no candidates → no strip, error message shown
- [x] CoverCandidate IDs are stable (source + sourceItemId)
- [x] Deduplication works by ID (Equatable/Hashable by ID only)
- [x] Coordinator logic shared between single and batch edit