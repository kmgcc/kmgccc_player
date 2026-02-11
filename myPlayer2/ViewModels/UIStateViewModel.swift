//
//  UIStateViewModel.swift
//  myPlayer2
//
//  TrueMusic - UI State ViewModel
//  Manages UI layout state (navigation, content mode).
//  Sidebar can be collapsed and restored.
//

import Foundation
import SwiftUI

/// Content mode for main area
enum ContentMode: Equatable {
    case library
    case nowPlaying
}

/// Observable ViewModel for UI layout state.
/// - Sidebar: Toggleable with width memory
/// - Lyrics: Toggleable
/// - Content: Switches between library and now playing
@Observable
@MainActor
final class UIStateViewModel {

    private enum StorageKey {
        static let sidebarVisible = "ui.sidebarVisible"
        static let sidebarLastWidth = "ui.sidebarLastWidth"
    }

    private let defaults = UserDefaults.standard

    // MARK: - Layout Visibility

    /// Whether the sidebar is currently visible.
    var sidebarVisible: Bool = true {
        didSet {
            defaults.set(sidebarVisible, forKey: StorageKey.sidebarVisible)
        }
    }

    /// Last known visible sidebar width (used when restoring).
    var sidebarLastWidth: CGFloat = Constants.Layout.sidebarDefaultWidth {
        didSet {
            defaults.set(Double(sidebarLastWidth), forKey: StorageKey.sidebarLastWidth)
        }
    }

    /// Whether the lyrics panel is visible (toggleable).
    var lyricsVisible: Bool = true

    /// Current lyrics panel width (user-resizable).
    var lyricsWidth: CGFloat = Constants.Layout.lyricsPanelDefaultWidth

    // MARK: - Content Mode

    /// Current content mode (library or now playing)
    var contentMode: ContentMode = .library

    // MARK: - Navigation State

    /// Currently selected playlist (if any).
    var selectedPlaylist: Playlist?

    // MARK: - Library Position Snapshot (for round-trip from Now Playing)

    /// Playlist ID when user entered Now Playing from library.
    var lastLibraryPlaylistID: UUID?

    /// Last known top scroll anchor track ID in library list.
    var lastLibraryScrollTrackID: UUID?

    /// Whether the user has moved away from the default top position.
    var libraryHasUserScrolled: Bool = false

    /// One-shot flag to request restoring library scroll after leaving Now Playing.
    var shouldRestoreLibraryScrollOnReturn: Bool = false

    init() {
        if defaults.object(forKey: StorageKey.sidebarVisible) != nil {
            sidebarVisible = defaults.bool(forKey: StorageKey.sidebarVisible)
        }

        let savedWidth = defaults.double(forKey: StorageKey.sidebarLastWidth)
        if savedWidth >= Double(Constants.Layout.sidebarMinWidth)
            && savedWidth <= Double(Constants.Layout.sidebarMaxWidth)
        {
            sidebarLastWidth = CGFloat(savedWidth)
        }
    }

    // MARK: - Actions

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            sidebarVisible.toggle()
        }
    }

    func updateSidebarWidth(_ width: CGFloat) {
        let clamped = min(
            max(width, Constants.Layout.sidebarMinWidth),
            Constants.Layout.sidebarMaxWidth
        )
        if abs(clamped - sidebarLastWidth) > 0.5 {
            sidebarLastWidth = clamped
        }
    }

    func toggleLyrics() {
        withAnimation(.easeInOut(duration: 0.25)) {
            lyricsVisible.toggle()
        }
    }

    func showNowPlaying() {
        withAnimation(.easeInOut(duration: 0.3)) {
            contentMode = .nowPlaying
        }
    }

    func showLibrary() {
        withAnimation(.easeInOut(duration: 0.3)) {
            contentMode = .library
        }
    }

    /// Called continuously by library list to keep the latest visible anchor snapshot.
    func rememberLibraryContext(
        playlistID: UUID?,
        scrollTrackID: UUID?,
        userScrolled: Bool
    ) {
        lastLibraryPlaylistID = playlistID
        lastLibraryScrollTrackID = scrollTrackID
        libraryHasUserScrolled = userScrolled
    }

    /// Return from now playing to library and request one-time position restore.
    func returnToLibraryFromNowPlaying() {
        shouldRestoreLibraryScrollOnReturn = true
        showLibrary()
    }

    /// Consume one-time restore request for the matching playlist.
    /// Returns nil when no restore is needed, so list falls back to default top.
    func consumeLibraryRestoreTarget(for playlistID: UUID?) -> UUID? {
        guard shouldRestoreLibraryScrollOnReturn else { return nil }
        shouldRestoreLibraryScrollOnReturn = false

        guard playlistID == lastLibraryPlaylistID, libraryHasUserScrolled else {
            return nil
        }
        return lastLibraryScrollTrackID
    }
}
