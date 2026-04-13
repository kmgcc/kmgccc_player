//
//  PlaylistEditSheet.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Edit Sheet
//  Create, rename, or delete playlists.
//

import SwiftUI

/// Sheet for creating a new playlist.
struct PlaylistEditSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM

    // MARK: - Editable State

    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 18) {
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

                Spacer()
            }
            .padding(24)

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 400, height: 300)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("sidebar.new_playlist")
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

            Button("context.new_playlist") {
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
            _ = await libraryVM.createPlaylist(name: trimmedName)
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview("New Playlist") {
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)

    PlaylistEditSheet()
        .environment(libraryVM)
}
