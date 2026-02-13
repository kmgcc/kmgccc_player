//
//  TrackEditSheet.swift
//  myPlayer2
//
//  kmgccc_player - Track Metadata Edit Sheet
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
    @Environment(\.openURL) private var openURL
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore

    let track: Track

    // MARK: - Editable State

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var lyricsText: String = ""
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0

    // MARK: - UI State

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

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

                    // Extra scroll breathing room so the LDDC panel (results/preview/errors)
                    // can be comfortably brought into view without fighting the footer.
                    Color.clear.frame(height: 240)
                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 550, height: 750)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            loadTrackData()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("edit.track.title")
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
            Label("edit.track.artwork", systemImage: "photo")
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
                    Button(LocalizedStringKey("edit.track.choose_image")) {
                        showingArtworkPicker = true
                    }

                    if artworkData != nil {
                        Button(LocalizedStringKey("edit.track.remove_artwork")) {
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
            Label("edit.track.metadata", systemImage: "info.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.track_title")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "edit.track.track_title", text: $title
                    )
                    .textFieldStyle(.roundedBorder)
                }

                // Artist
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.artist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "edit.track.artist_name", text: $artist
                    )
                    .textFieldStyle(.roundedBorder)
                }

                // Album
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.album")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("edit.track.album_name", text: $album)
                        .textFieldStyle(.roundedBorder)
                }

                // Duration (read-only)
                VStack(alignment: .leading, spacing: 4) {
                    Text("edit.track.duration")
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
                Label(
                    "edit.track.lyrics", systemImage: "text.quote"
                )
                .font(.headline)

                Spacer()

                Button {
                    openURL(amllDbURL)
                } label: {
                    Label("AMLL DB", systemImage: "arrow.up.right.square")
                }
                .font(.caption)

                Button {
                    openURL(ttmlToolURL)
                } label: {
                    Label("TTML Tool", systemImage: "hammer.fill")
                }
                .font(.caption)

                Button(LocalizedStringKey("edit.track.import_lyrics")) {
                    showingLyricsPicker = true
                }
                .font(.caption)
            }

            Text(
                "AMLL DB 歌词库中的 TTML 专为 AMLL 组件设计，支持对唱歌词、背景歌词等高级特性，来自网络的转换歌词仅为歌词缺失情况下的备选。您也可以使用 AMLL TTML Tool 自己制作歌词使用或贡献到 AMLL DB。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $lyricsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("edit.track.paste_desc")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("edit.track.offset")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button(LocalizedStringKey("edit.track.reset")) {
                        lyricsTimeOffsetMs = 0
                    }
                    .font(.caption)
                }

                Slider(value: $lyricsTimeOffsetMs, in: -5000...5000, step: 100)

                Text(NSLocalizedString("edit.track.offset_desc", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.vertical, 8)

            // LDDC Lyrics Search
            LDDCSearchSection(track: track) { ttml in
                // Update lyrics text and save
                lyricsText = ttml
                track.ttmlLyricText = ttml
                track.lyricsText = nil

                do {
                    try modelContext.save()
                    print("[TrackEditSheet] Applied LDDC lyrics for: \(track.title)")
                    if playerVM.currentTrack?.id == track.id {
                        lyricsVM.ensureAMLLLoaded(
                            track: track,
                            currentTime: playerVM.currentTime,
                            isPlaying: playerVM.isPlaying,
                            reason: "LDDC lyrics applied",
                            forceLyricsReload: true
                        )
                    }
                } catch {
                    print("[TrackEditSheet] Failed to save LDDC lyrics: \(error)")
                }
            }
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
            Button(LocalizedStringKey("edit.track.cancel")) {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            Button(LocalizedStringKey("edit.track.save")) {
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
        lyricsTimeOffsetMs = track.lyricsTimeOffsetMs
    }

    private func saveChanges() {
        track.title =
            title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        track.artist =
            artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        track.album =
            album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : album
        let trimmedLyrics = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLyrics.isEmpty {
            track.lyricsText = nil
            track.ttmlLyricText = nil
        } else if trimmedLyrics.lowercased().contains("<tt") {
            track.ttmlLyricText = trimmedLyrics
            track.lyricsText = nil
        } else {
            track.lyricsText = trimmedLyrics
            track.ttmlLyricText = nil
        }
        track.artworkData = artworkData
        track.lyricsTimeOffsetMs = lyricsTimeOffsetMs

        do {
            try modelContext.save()
            LocalLibraryService.shared.writeSidecar(for: track)
            print("[TrackEditSheet] Saved changes for: \(track.title)")
            if playerVM.currentTrack?.id == track.id {
                lyricsVM.ensureAMLLLoaded(
                    track: track,
                    currentTime: playerVM.currentTime,
                    isPlaying: playerVM.isPlaying,
                    reason: "track info saved",
                    forceLyricsReload: true
                )
            }
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
