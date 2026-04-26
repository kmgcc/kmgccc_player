//
//  UIStateViewModel.swift
//  myPlayer2
//
//  kmgccc_player - UI State ViewModel
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
        static let lyricsVisible = "ui.lyricsVisible"
        static let lyricsWidth = "ui.lyricsWidth"
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
    var lyricsVisible: Bool = false {
        didSet {
            defaults.set(lyricsVisible, forKey: StorageKey.lyricsVisible)
        }
    }

    /// Temporarily hide the main lyrics panel when another lyrics surface
    /// (e.g. batch editor preview) is actively displayed.
    var lyricsPanelSuppressedByModal: Bool = false

    /// Current lyrics panel width (user-resizable).
    var lyricsWidth: CGFloat = Constants.Layout.lyricsPanelDefaultWidth {
        didSet {
            defaults.set(Double(lyricsWidth), forKey: StorageKey.lyricsWidth)
        }
    }

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

    // MARK: - Home Navigation Context

    /// Back stack for navigation that originated from Home (most recent at end).
    private(set) var homeBackStack: [LibrarySelection] = []

    /// Forward stack for Home-context back/forward (most recent at end).
    private(set) var homeForwardStack: [LibrarySelection] = []

    /// True when the current selection was reached by drilling in from Home.
    var isHomeDrilldown: Bool = false

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

        if defaults.object(forKey: StorageKey.lyricsVisible) != nil {
            lyricsVisible = defaults.bool(forKey: StorageKey.lyricsVisible)
        }

        let savedLyricsWidth = defaults.double(forKey: StorageKey.lyricsWidth)
        if savedLyricsWidth >= Double(Constants.Layout.lyricsPanelMinWidth)
            && savedLyricsWidth <= Double(Constants.Layout.lyricsPanelMaxWidth)
        {
            lyricsWidth = CGFloat(savedLyricsWidth)
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

    /// Force the main window out of Now Playing before presenting fullscreen UI.
    /// This uses a non-animated transaction so the page unmounts immediately and
    /// does not briefly coexist with the fullscreen player.
    @discardableResult
    func dismissNowPlayingForFullscreenPresentation() -> Bool {
        guard contentMode == .nowPlaying else { return false }

        shouldRestoreLibraryScrollOnReturn = true

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            contentMode = .library
        }
        return true
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

    // MARK: - Home Navigation Actions

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

    /// Move back one step within the Home navigation context.
    func goBackInHomeContext(libraryVM: LibraryViewModel) {
        guard let previous = homeBackStack.popLast() else { return }
        homeForwardStack.append(libraryVM.currentSelection)
        libraryVM.currentSelection = previous
        isHomeDrilldown = (previous != .home)
        showLibrary()
    }

    /// Move forward one step within the Home navigation context.
    func goForwardInHomeContext(libraryVM: LibraryViewModel) {
        guard let next = homeForwardStack.popLast() else { return }
        homeBackStack.append(libraryVM.currentSelection)
        libraryVM.currentSelection = next
        isHomeDrilldown = (next != .home)
        showLibrary()
    }

    /// Whether the toolbar pill should be visible (current page is Home or a Home drilldown).
    func shouldShowHomeNavigationPill(libraryVM: LibraryViewModel) -> Bool {
        if libraryVM.currentSelection == .home { return true }
        return isHomeDrilldown
    }

    /// Drop all Home navigation history. Used when the user navigates from the
    /// Sidebar (which exits the Home context entirely).
    func clearHomeNavigationContext() {
        homeBackStack.removeAll()
        homeForwardStack.removeAll()
        isHomeDrilldown = false
    }
}
