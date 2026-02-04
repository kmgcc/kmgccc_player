//
//  UIStateViewModel.swift
//  myPlayer2
//
//  TrueMusic - UI State ViewModel
//  Manages UI layout state (navigation, content mode).
//  Sidebar is ALWAYS visible - no toggle provided.
//

import Foundation
import SwiftUI

/// Content mode for main area
enum ContentMode: Equatable {
    case library
    case nowPlaying
}

/// Observable ViewModel for UI layout state.
/// - Sidebar: Always visible (no sidebarVisible property, no toggle)
/// - Lyrics: Toggleable
/// - Content: Switches between library and now playing
@Observable
@MainActor
final class UIStateViewModel {

    // MARK: - Layout Visibility

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

    // MARK: - Actions

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
}
