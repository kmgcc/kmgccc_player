//
//  LibraryDetailHeaderView.swift
//  myPlayer2
//
//  Unified detail-page header for playlist, artist, and album selections.
//  Shows large artwork on the left, text metadata in the center, edit button on the right.
//  Edit mode exposes description and (for album) year fields.
//  The header is a plain view — not inside a List — so no listRow modifiers are needed.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryDetailHeaderView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let config: DetailHeaderConfig
    let onArtworkChange: (NSImage?) -> Void
    let onPlay: () -> Void
    let canPlay: Bool

    @State private var isEditing = false
    @State private var editDescription = ""
    @State private var editYear = ""
    @State private var generatedArtwork: NSImage?
    @State private var artworkGenTask: Task<Void, Never>?
    @State private var isImportingArtwork = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            artworkColumn
                .frame(width: 220, height: 220)

            VStack(alignment: .leading, spacing: 5) {
                titleView
                subtitleView
                metadataView
                Spacer().frame(height: 2)
                if isEditing {
                    descriptionEditor
                    if case .album = config { yearEditor }
                } else {
                    descriptionReadView
                }
                
                Spacer()
                
                headerButtonsView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .onAppear { refreshArtwork() }
        .onChange(of: config.identity) { refreshArtwork() }
        .fileImporter(
            isPresented: $isImportingArtwork,
            allowedContentTypes: [UTType.jpeg, UTType.png, UTType.heic, UTType.tiff],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result: result)
        }
    }

    // MARK: - Artwork column

    @ViewBuilder
    private var artworkColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            artworkImage
                .clipShape(artworkClipShape)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

            if isEditing {
                Button { isImportingArtwork = true } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: 5)
            }
        }
    }

    @ViewBuilder
    private var artworkImage: some View {
        switch config {
        case .playlist:
            Group {
                if let img = generatedArtwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
        case .artist:
            Group {
                if let img = generatedArtwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Circle().fill(.secondary.opacity(0.12))
                        Image(systemName: "person.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .album(_, stats: let stats):
            Group {
                if let img = stats.artworkImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .overlay(
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
        }
    }

    private var artworkClipShape: AnyShape {
        switch config {
        case .artist: AnyShape(Circle())
        default: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Text fields

    private var titleView: some View {
        Text(titleString)
            .font(.title)
            .fontWeight(.bold)
            .lineLimit(2)
    }

    private var titleString: String {
        switch config {
        case .playlist(let p, _): return p.name
        case .artist(let e, _): return e.displayName
        case .album(let e, _): return e.displayTitle
        }
    }

    private var subtitleView: some View {
        Text(subtitleString)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var subtitleString: String {
        switch config {
        case .playlist(_, let data):
            let n = data.tracks.count
            return n == 1 ? "1 首歌曲" : "\(n) 首歌曲"
        case .artist(_, let stats):
            return "\(stats.trackCount) 首歌曲 · \(stats.albumCount) 张专辑"
        case .album(_, let stats):
            return stats.artistName
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        switch config {
        case .playlist(_, let data):
            let dur = data.tracks.reduce(0) { $0 + $1.duration }
            Text(formatDuration(dur))
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .artist:
            EmptyView()
        case .album(let entry, let stats):
            let parts = buildAlbumMetaParts(entry: entry, stats: stats)
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func buildAlbumMetaParts(entry: AlbumEntry, stats: AlbumDerivedStats) -> [String] {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        let n = stats.trackCount
        parts.append(n == 1 ? "1 首歌曲" : "\(n) 首歌曲")
        parts.append(formatDuration(stats.totalDuration))
        return parts
    }

    // MARK: - Description

    private var currentDescription: String {
        switch config {
        case .playlist(_, let data): return data.description
        case .artist(let e, _): return e.description
        case .album(let e, _): return e.description
        }
    }

    private var descriptionReadView: some View {
        Text(currentDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var descriptionEditor: some View {
        TextField("添加描述…", text: $editDescription, axis: .vertical)
            .font(.callout)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var yearEditor: some View {
        HStack(spacing: 6) {
            Text("年份")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $editYear)
                .font(.callout)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .onSubmit { commitEdits() }
        }
    }

    // MARK: - Header Buttons

    private var headerButtonsView: some View {
        HStack(spacing: 10) {
            playButton
            editButton
        }
    }

    private var playButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.95 : 0.90))
                Text("播放")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.95 : 0.90))
            }
            .padding(.horizontal, 16)
            .frame(height: buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .background {
            Capsule()
                .fill(themeStore.accentColor)
        }
        .background {
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08))
        }
        .glassEffect(.clear, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .clipShape(Capsule())
    }

    private var editButton: some View {
        Button {
            if isEditing { commitEdits() } else { beginEditing() }
        } label: {
            Image(systemName: isEditing ? "checkmark" : "pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEditing ? .white : themeStore.accentColor.opacity(colorScheme == .dark ? 0.96 : 0.88))
                .frame(width: buttonHeight, height: buttonHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if isEditing {
                Circle()
                    .fill(themeStore.accentColor)
            }
        }
        .background {
            Circle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08))
        }
        .glassEffect(.clear, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .clipShape(Circle())
    }

    private var buttonHeight: CGFloat {
        GlassStyleTokens.headerControlHeight
    }

    private func beginEditing() {
        editDescription = currentDescription
        if case .album(let entry, _) = config {
            editYear = entry.year.map { String($0) } ?? ""
        }
        isEditing = true
    }

    private func commitEdits() {
        isEditing = false
        let desc = editDescription
        let yearStr = editYear
        Task {
            switch config {
            case .playlist(let playlist, _):
                await libraryVM.savePlaylistDescription(playlist, description: desc)
            case .artist(let entry, _):
                var updated = entry
                updated.description = desc
                await libraryVM.saveArtistEntry(updated)
            case .album(let entry, _):
                var updated = entry
                updated.description = desc
                updated.year = Int(yearStr)
                await libraryVM.saveAlbumEntry(updated)
            }
        }
    }

    // MARK: - Artwork loading

    private func refreshArtwork() {
        artworkGenTask?.cancel()
        // Capture identity token; stale async results are dropped if identity changed.
        let token = config.identity
        switch config {
        case .playlist(let playlist, let data):
            artworkGenTask = Task {
                let img = await PlaylistArtworkGenerator.shared.artwork(
                    for: playlist, tracks: data.tracks)
                guard !Task.isCancelled, config.identity == token else { return }
                generatedArtwork = img
                onArtworkChange(img)
            }
        case .artist(let entry, _):
            // Load from persisted artworkData immediately (synchronous — no stale risk).
            if let data = entry.artworkData, let img = NSImage(data: data) {
                generatedArtwork = img
                onArtworkChange(img)
            } else {
                generatedArtwork = nil
                onArtworkChange(nil)
            }
        case .album(_, let stats):
            generatedArtwork = nil
            onArtworkChange(stats.artworkImage)
        }
    }

    // MARK: - Artwork import

    private func handleArtworkImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            guard let nsImage = NSImage(contentsOf: url) else { return }
            guard let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:])
            else { return }

            // Update display immediately for all cases.
            generatedArtwork = nsImage
            onArtworkChange(nsImage)

            Task {
                switch config {
                case .playlist(let playlist, let data):
                    let signature = await computePlaylistSignature(tracks: data.tracks)
                    await MainActor.run {
                        LocalLibraryService.shared.savePlaylistArtwork(
                            playlistID: playlist.id,
                            image: nsImage,
                            signature: signature
                        )
                    }
                    await PlaylistArtworkGenerator.shared.invalidate(playlistID: playlist.id)
                case .artist(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = pngData
                    await libraryVM.saveArtistEntry(updated)
                    // Refresh the blurred background with the now-persisted artwork.
                    onArtworkChange(nsImage)
                case .album(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = pngData
                    await libraryVM.saveAlbumEntry(updated)
                }
            }
            
        case .failure(let error):
            print("Artwork import failed: \(error.localizedDescription)")
        }
    }
    
    private func computePlaylistSignature(tracks: [Track]) async -> String {
        let sortedIDs = tracks.map(\.id.uuidString).sorted().joined()
        return String(PlaylistArtworkGenerator.stableHash(for: sortedIDs))
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
