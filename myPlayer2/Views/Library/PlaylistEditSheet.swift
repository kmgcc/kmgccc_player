//
//  PlaylistEditSheet.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Edit Sheet
//  Create, rename, or delete playlists.
//

import SwiftUI

/// Sheet for creating or editing a playlist.
struct PlaylistEditSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM

    /// Existing playlist to edit, or nil for new playlist.
    let playlist: Playlist?

    /// Mode: create or edit.
    var isCreating: Bool { playlist == nil }

    // MARK: - Editable State

    @State private var name: String = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 24) {
                // Name field
                VStack(alignment: .leading, spacing: 8) {
                    Text("edit.playlist.name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField(
                        "edit.playlist.placeholder", text: $name
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                }

                // Track count (edit mode only)
                if let playlist = playlist {
                    HStack {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.secondary)

                        Text("edit.playlist.tracks_count \(playlist.tracks.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                Spacer()

                // Delete button (edit mode only)
                if !isCreating {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label(
                            "edit.playlist.delete",
                            systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .padding(24)

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 400, height: 300)
        .onAppear {
            if let playlist = playlist {
                name = playlist.name
            }
        }
        .confirmationDialog(
            "edit.playlist.delete_confirm_title",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "edit.playlist.delete_confirm", role: .destructive
            ) {
                deletePlaylist()
            }
            Button("edit.track.cancel", role: .cancel) {}
        } message: {
            Text("edit.playlist.delete_desc")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text(
                isCreating
                    ? "sidebar.new_playlist"
                    : "sidebar.edit_playlist"
            )
            .font(.title2)
            .fontWeight(.bold)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("edit.track.cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            Button(
                isCreating
                    ? "context.new_playlist"
                    : "edit.track.save"
            ) {
                savePlaylist()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    // MARK: - Actions

    private func savePlaylist() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        Task {
            if let playlist = playlist {
                // Update existing
                await libraryVM.renamePlaylist(playlist, name: trimmedName)
            } else {
                // Create new
                let newPlaylist = await libraryVM.createNewPlaylist()
                await libraryVM.renamePlaylist(newPlaylist, name: trimmedName)
            }
            dismiss()
        }
    }

    private func deletePlaylist() {
        guard let playlist = playlist else { return }

        Task {
            await libraryVM.deletePlaylist(playlist)
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview("New Playlist") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)

    PlaylistEditSheet(playlist: nil)
        .environment(libraryVM)
}

#Preview("Edit Playlist") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let playlist = Playlist(name: "My Favorites")

    PlaylistEditSheet(playlist: playlist)
        .environment(libraryVM)
}
