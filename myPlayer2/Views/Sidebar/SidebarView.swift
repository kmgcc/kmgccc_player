//
//  SidebarView.swift
//  myPlayer2
//
//  TrueMusic - Sidebar View
//  NO custom blur/material - let macOS 26 system render Liquid Glass.
//  Sidebar is always visible (no toggle).
//
//  Supports:
//  - New Playlist creation (creates and selects immediately)
//  - Playlist selection
//  - Settings access
//

import SwiftUI

/// Sidebar view for navigation and playlists.
/// IMPORTANT: Do NOT add .background(material) or NSVisualEffectView here!
/// The NavigationSplitView sidebar column automatically gets system Liquid Glass.
struct SidebarView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    @State private var showSettings = false
    @State private var showingPlaylistSheet = false
    @State private var playlistToEdit: Playlist?  // nil = create new

    var body: some View {
        VStack(spacing: 0) {
            // Main list
            List(
                selection: Binding(
                    get: {
                        if let id = libraryVM.selectedPlaylistId {
                            return SidebarSelection.playlist(id)
                        }
                        return SidebarSelection.allSongs
                    },
                    set: { newValue in
                        handleSelection(newValue)
                    }
                )
            ) {
                // App Header Section
                Section {
                    Label(Constants.appName, systemImage: "music.note.house")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                // Library Section
                Section("Library") {
                    NavigationLink(value: SidebarSelection.allSongs) {
                        Label("All Songs", systemImage: "music.note.list")
                    }
                }

                // Playlists Section
                Section("Playlists") {
                    ForEach(libraryVM.playlists) { playlist in
                        NavigationLink(value: SidebarSelection.playlist(playlist.id)) {
                            Label(playlist.name, systemImage: "music.note.list")
                        }
                        .contextMenu {
                            Button {
                                playlistToEdit = playlist
                                showingPlaylistSheet = true
                            } label: {
                                Label("Edit Playlist", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Task {
                                    await libraryVM.deletePlaylist(playlist)
                                }
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }

                    // New Playlist button
                    Button {
                        playlistToEdit = nil
                        showingPlaylistSheet = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Settings button at bottom
            settingsButton
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            PlaylistEditSheet(playlist: playlistToEdit)
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            HStack {
                Image(systemName: "gearshape")
                Text("Settings")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func handleSelection(_ item: SidebarSelection) {
        switch item {
        case .allSongs:
            libraryVM.selectPlaylist(nil)
            uiState.showLibrary()
        case .playlist(let id):
            if let playlist = libraryVM.playlists.first(where: { $0.id == id }) {
                libraryVM.selectPlaylist(playlist)
                uiState.showLibrary()
            }
        }
    }
}

// MARK: - Sidebar Selection

private enum SidebarSelection: Hashable {
    case allSongs
    case playlist(UUID)
}

// MARK: - Preview

#Preview("Sidebar") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let uiState = UIStateViewModel()

    NavigationSplitView {
        SidebarView()
            .environment(libraryVM)
            .environment(uiState)
    } detail: {
        Text("Detail")
    }
    .frame(width: 600, height: 500)
    .task {
        await libraryVM.load()
    }
}
