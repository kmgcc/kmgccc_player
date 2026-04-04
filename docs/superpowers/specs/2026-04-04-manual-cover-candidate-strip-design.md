# Manual Cover Search Candidate Strip Design

**Date:** 2026-04-04
**Scope:** Manual "Find Cover" flow in song info editor only
**Excluded:** Import-time automatic cover search

## Summary

Add a horizontal thumbnail strip to the manual cover search UI that shows all cover candidates from both sacad and NetEase sources. The highest-resolution result remains the default selection, but users can manually choose any candidate from the strip.

## Current State Analysis

### Call Chain (Manual Cover Search)

```
TrackEditSheet.fetchCover()
  └─> CoverDownloadService.downloadCover(artist, album, size: 1200)
       └─> sacad CLI (returns single best result)
  └─> (fallback) NetEaseCoverService.searchAndDownloadCover(artist, album)
       └─> NetEase API search (returns up to 5 albums)
       └─> Downloads first album's cover only

BatchTrackEditSheet.fetchCover()
  └─> Same chain as above, with auto-save after download
```

### Key Files

| File | Role |
|------|------|
| `TrackEditSheet.swift` | Single-track edit UI, artwork section at lines 117-185 |
| `BatchTrackEditSheet.swift` | Batch edit UI, metadata section at lines 297-381 |
| `CoverDownloadService.swift` | sacad CLI wrapper, returns single `Data` |
| `NetEaseCoverService.swift` | NetEase API client, returns single `Data` (first album only) |
| `CoverServiceModels.swift` | Error enums, `CoverSource` enum |

### Current Limitations

1. Both services return single `Data`, not candidate arrays
2. NetEase fetches 5 albums but only uses first match
3. No resolution metadata returned with the data
4. No shared cover picker component between single/batch edit

## Design

### 1. New Model: CoverCandidate

```swift
struct CoverCandidate: Identifiable, Equatable {
    let id: String  // Stable identity: source + source-specific ID
    let imageData: Data
    let resolution: Int  // Larger dimension (e.g., 1200 for 1200x1200)
    let source: CoverSource
    let sourceItemId: String?  // Album ID, URL hash, or source-specific identifier

    init(imageData: Data, source: CoverSource, sourceItemId: String?) {
        // Stable ID: "sacad:<album-artist-hash>" or "netease:<album-id>"
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        self.resolution = Self.computeResolution(from: imageData)
    }

    private static func computeResolution(from data: Data) -> Int {
        guard let image = NSImage(data: data) else { return 0 }
        let rep = image.representations.first
        return max(rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0)
    }
}
```

**Identity Strategy:**
- sacad candidates: ID = `"sacad:<artist-album-normalized>"` (hash of search query)
- NetEase candidates: ID = `"netease:<album-id>"` (actual NetEase album ID from API)
- Stability ensures deduplication works correctly even across re-searches

### 2. Extended Service: NetEaseCoverService

Add new method to return multiple candidates:

```swift
func searchCoverCandidates(artist: String, album: String) async throws -> [CoverCandidate] {
    // Same search logic as existing method
    // But iterate over all albums in result.result.albums
    // Download each album's cover, create CoverCandidate
    // Return array sorted by resolution descending
}
```

Keep existing `searchAndDownloadCover()` unchanged for backward compatibility.

### 3. New Component: CoverCandidateStripView

```swift
struct CoverCandidateStripView: View {
    let candidates: [CoverCandidate]
    let selectedCandidate: CoverCandidate?
    let onSelect: (CoverCandidate) -> Void

    // Layout:
    // - Horizontal ScrollView with LazyHStack
    // - Each thumbnail: 60x60, rounded corners
    // - Resolution badge: bottom-right corner, small font
    // - Selected state: subtle border ring (accent color, 2px)
}
```

Key UI details:
- Thumbnail size: 60×60 pixels (compact)
- Badge format: single number (e.g., "1200") for square images; "1200×800" for non-square
- Badge position: bottom-right, semi-transparent dark background, white text
- Selected indicator: 2px accent-colored border
- Scroll behavior: horizontal only, no pagination

### 4. Shared Logic: CoverSearchCoordinator

Create a helper to centralize merge/sort/default-selection logic:

```swift
@Observable
class CoverSearchCoordinator {
    var candidates: [CoverCandidate] = []
    var selectedForPreview: CoverCandidate?  // Preview selection (not yet saved)
    var isLoading: Bool = false
    var error: String?

    func search(artist: String, album: String) async {
        // 1. Concurrent: sacad + NetEase multi-candidate search
        // 2. Merge results
        // 3. Dedupe by ID first (source + sourceItemId)
        // 4. If same sourceItemId appears from both sources, prefer sacad
        // 5. Sort by resolution descending
        // 6. selectedForPreview = first (highest-res)
    }

    func selectForPreview(_ candidate: CoverCandidate) {
        selectedForPreview = candidate
        // Note: This does NOT persist - caller decides when to save
    }

    func getPreviewImageData() -> Data? {
        selectedForPreview?.imageData
    }
}
```

**Deduplication Strategy:**
1. Primary: Match by `id` (source + sourceItemId) - exact duplicates removed
2. Secondary: If same NetEase album appears twice (edge case), keep one
3. Resolution is NOT used for deduplication - only for sorting/selection

### 5. Integration Layout

#### Single Edit (TrackEditSheet)

Current layout (lines 124-176):
```
HStack(spacing: 16) {
    [100x100 preview]  │  [Button column]
}
```

New layout:
```
HStack(spacing: 16) {
    [100x100 preview]  │  [Button column]  │  [Candidate strip]
}
```

The candidate strip occupies the "blank space" to the right of buttons. It appears only after search completes with results.

#### Batch Edit (BatchTrackEditSheet)

Current layout (lines 302-350):
```
HStack(spacing: 14) {
    [84x84 preview]  │  [Button column]  │  Spacer()
}
```

New layout:
```
HStack(spacing: 14) {
    [84x84 preview]  │  [Button column]  │  [Candidate strip]  │  Spacer()
}
```

Strip appears conditionally when candidates exist.

### 6. Selection vs Apply Semantics

**Two separate concepts:**

| State | Meaning |
|-------|---------|
| `selectedForPreview` | Which candidate is shown in the preview area |
| `artworkData` | Current preview image data (mirrors selectedForPreview.imageData) |
| Track.artworkData | Persisted data after user clicks "Save" |

**Flow:**

1. User clicks thumbnail → `selectedForPreview = candidate` → `artworkData` updates (preview only)
2. User clicks "Save" (single) or auto-save triggers (batch) → `track.artworkData = artworkData` → persistence
3. Preview selection is ephemeral; user can switch freely before saving
4. Canceling dismisses without persisting the preview selection

### 7. Error Handling

- If sacad fails: continue with NetEase candidates only
- If NetEase fails: continue with sacad result only
- If both fail: show existing error message, no strip appears
- Empty candidate list: no strip rendered

## Files Changed

| File | Change |
|------|--------|
| `CoverServiceModels.swift` | Add `CoverCandidate` struct with stable ID |
| `CoverSearchCoordinator.swift` | **NEW** - Shared merge/sort/selection logic |
| `NetEaseCoverService.swift` | Add `searchCoverCandidates()` method returning array |
| `CoverCandidateStripView.swift` | **NEW** - Thumbnail strip component |
| `TrackEditSheet.swift` | Use coordinator, integrate strip into artwork section |
| `BatchTrackEditSheet.swift` | Same changes as TrackEditSheet |

## Verification Checklist

- [ ] Build passes
- [ ] Single edit: strip appears after "Find Cover" completes
- [ ] Batch edit: strip appears after "Find Cover" completes
- [ ] Highest-resolution candidate selected by default (preview only)
- [ ] Clicking thumbnail switches preview image (no auto-save)
- [ ] Save applies the currently previewed cover
- [ ] Strip scrolls horizontally if candidates overflow
- [ ] Resolution badge: single number for square, dimensions for non-square
- [ ] Selected state clearly visible but subtle (border only)
- [ ] No layout breakage at narrow window widths
- [ ] Error case: no candidates → no strip, error message shown
- [ ] CoverCandidate IDs are stable (source + sourceItemId)
- [ ] Deduplication works by ID, not resolution
- [ ] Coordinator logic shared between single and batch edit