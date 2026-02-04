//
//  TrackEditSheet.swift
//  myPlayer2
//
//  TrueMusic - Track Metadata Edit Sheet
//  Edit track title, artist, album, artwork, and lyrics.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for editing track metadata.
/// Does NOT write back to audio file - only updates SwiftData model.
struct TrackEditSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let track: Track

    // MARK: - Editable State

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var lyricsText: String = ""
    @State private var artworkData: Data?

    // MARK: - UI State

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Artwork section
                    artworkSection

                    Divider()

                    // Metadata section
                    metadataSection

                    Divider()

                    // Lyrics section
                    lyricsSection
                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 500, height: 650)
        .onAppear {
            loadTrackData()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Edit Track")
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

    // MARK: - Artwork Section

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Artwork", systemImage: "photo")
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
                    Button("Choose Image...") {
                        showingArtworkPicker = true
                    }

                    if artworkData != nil {
                        Button("Remove Artwork") {
                            artworkData = nil
                        }
                        .foregroundStyle(.red)
                    }
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

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Metadata", systemImage: "info.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Track Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // Artist
                VStack(alignment: .leading, spacing: 4) {
                    Text("Artist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Artist Name", text: $artist)
                        .textFieldStyle(.roundedBorder)
                }

                // Album
                VStack(alignment: .leading, spacing: 4) {
                    Text("Album")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Album Name", text: $album)
                        .textFieldStyle(.roundedBorder)
                }

                // Duration (read-only)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(formatDuration(track.duration))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Lyrics Section

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Lyrics (TTML/LRC)", systemImage: "text.quote")
                    .font(.headline)

                Spacer()

                Button("Import...") {
                    showingLyricsPicker = true
                }
                .font(.caption)
            }

            TextEditor(text: $lyricsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("Paste TTML or LRC lyrics, or import from file")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "lrc") ?? .plainText,
                UTType(filenameExtension: "ttml") ?? .xml,
                .plainText,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            Button("Save Changes") {
                saveChanges()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
        }
        .padding()
    }

    // MARK: - Data Handling

    private func loadTrackData() {
        title = track.title
        artist = track.artist
        album = track.album
        lyricsText = track.lyricsText ?? track.ttmlLyricText ?? ""
        artworkData = track.artworkData
    }

    private func saveChanges() {
        track.title = title.isEmpty ? "Unknown Title" : title
        track.artist = artist.isEmpty ? "Unknown Artist" : artist
        track.album = album.isEmpty ? "Unknown Album" : album
        track.lyricsText = lyricsText.isEmpty ? nil : lyricsText
        track.artworkData = artworkData

        do {
            try modelContext.save()
            print("[TrackEditSheet] Saved changes for: \(track.title)")
        } catch {
            print("[TrackEditSheet] Failed to save: \(error)")
        }
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            artworkData = data
            print("[TrackEditSheet] Imported artwork: \(data.count) bytes")
        } catch {
            print("[TrackEditSheet] Failed to import artwork: \(error)")
        }
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            lyricsText = text
            print("[TrackEditSheet] Imported lyrics: \(text.prefix(50))...")
        } catch {
            print("[TrackEditSheet] Failed to import lyrics: \(error)")
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Preview

#Preview("Track Edit Sheet") {
    let track = Track(
        title: "Sample Track",
        artist: "Sample Artist",
        album: "Sample Album",
        duration: 180,
        fileBookmarkData: Data(),
        originalFilePath: "/path/to/file.mp3"
    )

    TrackEditSheet(track: track)
}
