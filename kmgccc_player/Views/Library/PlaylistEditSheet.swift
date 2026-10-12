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
        AppPopupFrame(
            title: String(localized: "sidebar.new_playlist"), systemImage: "music.note.list",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: AppPopupStyle().titleBodySpacing) {
                Text("edit.playlist.name").foregroundStyle(.secondary)
                TextField("edit.playlist.placeholder", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        } footer: {
            AppPopupActionGroup {
                Button("edit.track.cancel") { dismiss() }
                    .buttonStyle(AppDialogGlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("context.new_playlist", action: savePlaylist)
                    .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: AppPopupStyle().width)
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
    let libraryVM = LibraryViewModel.preview(repository: repository)

    PlaylistEditSheet()
        .environment(libraryVM)
        .environmentObject(ThemeStore.shared)
}