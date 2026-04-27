//
//  HomeCarouselUnderlayState.swift
//  myPlayer2
//
//  Singleton state shared between Home carousel sections (Albums / Artists)
//  and the non-interactive `HomeCarouselUnderlayView` mounted in the AppKit
//  root window beneath the split view.
//
//  Architecture (one-way push, no two-way coupling):
//
//  ┌───────────────────────────┐  push snapshot   ┌───────────────────────────┐
//  │ HomeAlbumsSection /       │ ───────────────▶ │ HomeCarouselUnderlayState │
//  │ HomeArtistsSection        │                  │  .shared                  │
//  │ (real ScrollView,         │                  │ albums / artists / geom   │
//  │  source of truth)         │                  └─────────────┬─────────────┘
//  └───────────────────────────┘                                │ read-only
//                                                               ▼
//                                                  ┌───────────────────────────┐
//                                                  │ HomeCarouselUnderlayView  │
//                                                  │ (window underlay,         │
//                                                  │  hit-testing disabled)    │
//                                                  └───────────────────────────┘
//
//  - Sections own the actual horizontal scrolling and hover/tap interaction.
//  - The underlay only renders side-strip continuations; it does NOT scroll
//    independently and does NOT own gesture state.
//  - Equality checks before assignment avoid spamming SwiftUI re-renders when
//    nothing meaningful changed (e.g. identical scroll-offset replays).
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class HomeCarouselUnderlayState {
    static let shared = HomeCarouselUnderlayState()

    enum ClipShape: Equatable, Hashable {
        case roundedRect(radius: CGFloat)
        case circle
    }

    enum Item: Equatable, Hashable, Identifiable {
        case album(id: UUID, artwork: Data?)
        case artist(id: UUID, artwork: Data?)

        var id: UUID {
            switch self {
            case .album(let id, _): return id
            case .artist(let id, _): return id
            }
        }

        var artwork: Data? {
            switch self {
            case .album(_, let data): return data
            case .artist(_, let data): return data
            }
        }
    }

    /// One row's measured layout + items, expressed in window-content
    /// coordinates (matching SwiftUI's `.global` for views hosted in the
    /// AppKit root content view).
    struct RowSnapshot: Equatable {
        var isActive: Bool
        var items: [Item]
        var rowMinXInWindow: CGFloat
        var rowMinYInWindow: CGFloat
        var rowHeight: CGFloat
        var cardWidth: CGFloat
        var cardHeight: CGFloat
        var spacing: CGFloat
        var leadingScrollPadding: CGFloat
        var verticalPadding: CGFloat
        var horizontalScrollOffset: CGFloat
        var clipShape: ClipShape

        static let empty = RowSnapshot(
            isActive: false,
            items: [],
            rowMinXInWindow: 0,
            rowMinYInWindow: 0,
            rowHeight: 0,
            cardWidth: 0,
            cardHeight: 0,
            spacing: 0,
            leadingScrollPadding: 0,
            verticalPadding: 0,
            horizontalScrollOffset: 0,
            clipShape: .roundedRect(radius: 12)
        )
    }

    struct Geometry: Equatable {
        var windowWidth: CGFloat
        var centerMinXInWindow: CGFloat
        var centerMaxXInWindow: CGFloat

        static let empty = Geometry(
            windowWidth: 0,
            centerMinXInWindow: 0,
            centerMaxXInWindow: 0
        )

        var hasValidLayout: Bool {
            windowWidth > 1 && centerMaxXInWindow > centerMinXInWindow + 1
        }
    }

    var albums: RowSnapshot = .empty
    var artists: RowSnapshot = .empty
    var geometry: Geometry = .empty

    /// Loaded artwork shared between the real Home cards and the underlay.
    ///
    /// The real `HomeAlbumCard` / `HomeArtistCircle` already runs the full
    /// loading pipeline (track fallback for albums, generated artwork for
    /// artists). After loading they push the resolved `NSImage` here so the
    /// underlay can render the SAME pixels — never gray placeholders, never
    /// a duplicated decoder pipeline that would diverge from the real card.
    var imageCache: [UUID: NSImage] = [:]

    private init() {}

    // MARK: - Albums mutators

    func setAlbumsActive(_ active: Bool) {
        guard albums.isActive != active else { return }
        var next = albums
        next.isActive = active
        if !active {
            next = .empty
        }
        albums = next
    }

    func updateAlbums(_ snapshot: RowSnapshot) {
        guard albums != snapshot else { return }
        albums = snapshot
    }

    func updateAlbumsHorizontalOffset(_ offset: CGFloat) {
        guard abs(albums.horizontalScrollOffset - offset) > 0.05 else { return }
        var next = albums
        next.horizontalScrollOffset = offset
        albums = next
    }

    func updateAlbumsRowOrigin(minX: CGFloat, minY: CGFloat) {
        guard
            abs(albums.rowMinXInWindow - minX) > 0.05
                || abs(albums.rowMinYInWindow - minY) > 0.05
        else { return }
        var next = albums
        next.rowMinXInWindow = minX
        next.rowMinYInWindow = minY
        albums = next
    }

    // MARK: - Artists mutators

    func setArtistsActive(_ active: Bool) {
        guard artists.isActive != active else { return }
        var next = artists
        next.isActive = active
        if !active {
            next = .empty
        }
        artists = next
    }

    func updateArtists(_ snapshot: RowSnapshot) {
        guard artists != snapshot else { return }
        artists = snapshot
    }

    func updateArtistsHorizontalOffset(_ offset: CGFloat) {
        guard abs(artists.horizontalScrollOffset - offset) > 0.05 else { return }
        var next = artists
        next.horizontalScrollOffset = offset
        artists = next
    }

    func updateArtistsRowOrigin(minX: CGFloat, minY: CGFloat) {
        guard
            abs(artists.rowMinXInWindow - minX) > 0.05
                || abs(artists.rowMinYInWindow - minY) > 0.05
        else { return }
        var next = artists
        next.rowMinXInWindow = minX
        next.rowMinYInWindow = minY
        artists = next
    }

    // MARK: - Geometry mutators

    func updateGeometry(_ next: Geometry) {
        guard geometry != next else { return }
        geometry = next
    }

    func setWindowWidth(_ width: CGFloat) {
        guard abs(geometry.windowWidth - width) > 0.05 else { return }
        var next = geometry
        next.windowWidth = width
        geometry = next
    }

    func setCenterRange(minX: CGFloat, maxX: CGFloat) {
        guard
            abs(geometry.centerMinXInWindow - minX) > 0.05
                || abs(geometry.centerMaxXInWindow - maxX) > 0.05
        else { return }
        var next = geometry
        next.centerMinXInWindow = minX
        next.centerMaxXInWindow = maxX
        geometry = next
    }

    // MARK: - Image cache

    /// Called by real Home cards once they finish their normal loading
    /// pipeline. Idempotent: identical references are skipped.
    func setLoadedImage(_ image: NSImage, for id: UUID) {
        if let existing = imageCache[id], existing === image { return }
        var next = imageCache
        next[id] = image
        imageCache = next
    }

    func loadedImage(for id: UUID) -> NSImage? {
        imageCache[id]
    }
}
