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

private struct NormalizedImportedHeaderArtwork {
    let image: NSImage
    let pngData: Data
}

private struct LibraryPresentedAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = ThemeStore.shared.accentColor
}

extension EnvironmentValues {
    var libraryPresentedAccentColor: Color {
        get { self[LibraryPresentedAccentColorKey.self] }
        set { self[LibraryPresentedAccentColorKey.self] = newValue }
    }
}

private struct HeaderArtworkBoundsReporter: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("detailScroll"))
            Color.clear
                .onAppear {
                    LyricsRuntimeProfile.increment("HeaderArtworkBoundsReporter.callback")
                    onChange(frame)
                }
                .onChange(of: frame) { _, newFrame in
                    LyricsRuntimeProfile.increment("HeaderArtworkBoundsReporter.callback")
                    onChange(newFrame)
                }
        }
    }
}

struct LibraryDetailHeaderView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let config: DetailHeaderConfig
    /// Stable identity for artwork crossfade state machine
    let artworkIdentity: String?
    /// Current visible artwork layer (bottom - old or placeholder)
    let currentArtwork: NSImage?
    /// Incoming artwork layer (top - crossfading in)
    let incomingArtwork: NSImage?
    /// Opacity of incoming layer (0 = show current, 1 = show incoming)
    let incomingOpacity: Double
    let onPlay: () -> Void
    let canPlay: Bool
    let onArtworkFrameChange: (CGRect) -> Void
    let onArtworkMutation: () -> Void

    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var editYear = ""
    @State private var isImportingArtwork = false
    @State private var isArtworkActionInFlight = false

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("LibraryDetailHeaderView.body")
        HStack(alignment: .bottom, spacing: 20) {
            artworkColumn
            .frame(width: 220, height: 220)
            .background(
                HeaderArtworkBoundsReporter(onChange: onArtworkFrameChange)
            )

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
            ZStack(alignment: .center) {
                artworkImage
                    .clipShape(artworkClipShape)

                // Loading overlay during regeneration
                if isArtworkActionInFlight {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            HeaderArtworkProgressOverlay()
                        )
                        .clipShape(artworkClipShape)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

            if isEditing {
                HStack(spacing: 8) {
                    if canGenerateArtwork {
                        artworkActionButton(
                            icon: "wand.and.stars",
                            help: NSLocalizedString("header.generate_artwork", comment: ""),
                            action: { handleRegenerateArtwork() }
                        )
                    }

                    if canRestoreDefaultArtwork {
                        artworkActionButton(
                            icon: "arrow.counterclockwise",
                            help: NSLocalizedString("header.restore_default_album_artwork", comment: ""),
                            action: { handleRestoreDefaultArtwork() }
                        )
                    }

                    artworkActionButton(
                        icon: "photo.badge.plus",
                        help: NSLocalizedString("header.import_artwork", comment: ""),
                        action: { isImportingArtwork = true }
                    )
                }
                .padding(8)
            }
        }
    }

    /// Compact artwork action button with Liquid Glass styling
    private func artworkActionButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        HeaderArtworkActionButton(
            icon: icon,
            colorScheme: colorScheme,
            help: help,
            action: action
        )
    }

    @ViewBuilder
    private var artworkImage: some View {
        // Stable container identity prevents SwiftUI from rebuilding the ZStack during crossfade
        ZStack {
            // Bottom layer: current artwork or placeholder (stable identity)
            artworkBaseLayer
                .id("artwork-base-\(artworkIdentity ?? "nil")")

            // Top layer: incoming artwork with crossfade opacity
            if let incomingArtwork {
                Image(nsImage: incomingArtwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(incomingOpacity)
                    // Incoming gets its own identity so it doesn't conflict with base
                    .id("artwork-incoming-\(artworkIdentity ?? "nil")-\(ObjectIdentifier(incomingArtwork).hashValue)")
            }
        }
        // Entire ZStack has stable identity based on artwork identity
        .id("artwork-container-\(artworkIdentity ?? "nil")")
    }

    @ViewBuilder
    private var artworkBaseLayer: some View {
        if let currentArtwork {
            Image(nsImage: currentArtwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            artworkPlaceholder
        }
    }

    @ViewBuilder
    private var artworkPlaceholder: some View {
        let isCircle = config.isCircle
        ArtworkPlaceholderView.header(size: 220, isCircle: isCircle)
    }

    private var artworkClipShape: AnyShape {
        switch config {
        case .artist: AnyShape(Circle())
        default: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Text fields

    private var titleView: some View {
        Group {
            if isEditing {
                TextField("", text: $editTitle, axis: .vertical)
                    .font(.title.weight(.bold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...2)
                    .onSubmit { commitEdits() }
            } else {
                Text(titleString)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)
            }
        }
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
        HeaderPlayButton(
            canPlay: canPlay,
            colorScheme: colorScheme,
            buttonHeight: buttonHeight,
            action: onPlay
        )
    }

    private var editButton: some View {
        HeaderEditButton(
            isEditing: isEditing,
            colorScheme: colorScheme,
            buttonHeight: buttonHeight,
            symbolName: "pencil"
        ) {
            if isEditing { commitEdits() } else { beginEditing() }
        }
    }

    private var buttonHeight: CGFloat {
        GlassStyleTokens.headerControlHeight
    }

    private func beginEditing() {
        editTitle = titleString
        editDescription = currentDescription
        if case .album(let entry, _) = config {
            editYear = entry.year.map { String($0) } ?? ""
        }
        isEditing = true
    }

    private func commitEdits() {
        let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isEditing = false
        let title = trimmedTitle
        let desc = editDescription
        let yearStr = editYear
        Task {
            switch config {
            case .playlist(let playlist, _):
                await libraryVM.savePlaylistEdits(
                    playlist,
                    name: title,
                    description: desc
                )
            case .artist(let entry, _):
                var updated = entry
                updated.displayName = title
                updated.description = desc
                await libraryVM.saveArtistEdits(original: entry, updated: updated)
            case .album(let entry, _):
                var updated = entry
                updated.displayTitle = title
                updated.description = desc
                updated.year = Int(yearStr)
                await libraryVM.saveAlbumEdits(original: entry, updated: updated)
            }
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

            guard let importedArtwork = normalizedImportedArtwork(from: url) else { return }
            Task {
                switch config {
                case .playlist(let playlist, _):
                    await MainActor.run {
                        LocalLibraryService.shared.savePlaylistCustomArtwork(
                            playlistID: playlist.id,
                            image: importedArtwork.image
                        )
                    }
                    await MainActor.run {
                        onArtworkMutation()
                    }
                case .artist(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = importedArtwork.pngData
                    await libraryVM.saveArtistEntry(updated)
                case .album(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = importedArtwork.pngData
                    await libraryVM.saveAlbumEntry(updated)
                }
            }

        case .failure(let error):
            print("Artwork import failed: \(error.localizedDescription)")
        }
    }

    private func normalizedImportedArtwork(from url: URL) -> NormalizedImportedHeaderArtwork? {
        guard let originalImage = NSImage(contentsOf: url) else { return nil }
        let size: CGFloat = 512
        let originalSize = originalImage.size
        let minDimension = min(originalSize.width, originalSize.height)
        let cropRect = NSRect(
            x: (originalSize.width - minDimension) / 2,
            y: (originalSize.height - minDimension) / 2,
            width: minDimension,
            height: minDimension
        )

        let cropped = NSImage(size: NSSize(width: size, height: size))
        cropped.lockFocus()
        originalImage.draw(
            in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
            from: cropRect,
            operation: .copy,
            fraction: 1.0
        )
        cropped.unlockFocus()

        guard let tiff = cropped.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:])
        else { return nil }

        print("🎨 [HeaderArtworkImport] selectionType=\(config.selectionTypeLabel) selectionIdentity=\(config.selectionIdentity) phase=processed-square-import sourcePath=\(url.path)")
        return NormalizedImportedHeaderArtwork(image: cropped, pngData: pngData)
    }

    // MARK: - Artwork regeneration

    private var canGenerateArtwork: Bool {
        switch config {
        case .playlist, .artist:
            return true
        case .album:
            return false
        }
    }

    private var canRestoreDefaultArtwork: Bool {
        if case .album = config {
            return true
        }
        return false
    }

    private func handleRegenerateArtwork() {
        guard !isArtworkActionInFlight else { return }

        isArtworkActionInFlight = true

        Task {
            switch config {
            case .playlist(let playlist, let data):
                let tracks = data.tracks
                let snapshots: [(id: UUID, artworkData: Data?)] = tracks.map {
                    (id: $0.id, artworkData: $0.loadArtworkDataIfNeeded())
                }
                let variationSeed = Int.random(in: 0...Int.max)

                guard let image = await PlaylistArtworkGenerator.shared.generateArtwork(
                    playlistID: playlist.id,
                    snapshots: snapshots,
                    variationSeed: variationSeed
                ) else {
                    await MainActor.run { isArtworkActionInFlight = false }
                    return
                }

                await MainActor.run {
                    LocalLibraryService.shared.regeneratePlaylistArtwork(
                        playlistID: playlist.id,
                        tracks: tracks,
                        image: image
                    )
                    onArtworkMutation()
                    isArtworkActionInFlight = false
                }
            case .artist(let entry, _):
                let artistTracks = libraryVM.allTracks.filter {
                    LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist)
                        && $0.availability != .missing
                }
                guard let generatedArtwork = await ArtistArtworkGenerator.shared.generateArtwork(
                    artistName: entry.displayName,
                    tracks: artistTracks
                ) else {
                    await MainActor.run { isArtworkActionInFlight = false }
                    return
                }

                guard let pngData = generatedArtwork.pngData() else {
                    await MainActor.run { isArtworkActionInFlight = false }
                    return
                }

                var updated = entry
                updated.artworkFileName = "artwork.png"
                updated.artworkData = pngData
                await libraryVM.saveArtistEntry(updated)
                await MainActor.run {
                    isArtworkActionInFlight = false
                }
            case .album:
                await MainActor.run {
                    isArtworkActionInFlight = false
                }
            }
        }
    }

    private func handleRestoreDefaultArtwork() {
        guard !isArtworkActionInFlight else { return }
        guard case .album(let entry, _) = config else { return }

        isArtworkActionInFlight = true
        Task {
            await libraryVM.restoreDefaultAlbumArtwork(entry)
            await MainActor.run {
                onArtworkMutation()
                isArtworkActionInFlight = false
            }
        }
    }

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

private struct HeaderArtworkProgressOverlay: View {
    @Environment(\.libraryPresentedAccentColor) private var presentedAccentColor

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("HeaderArtworkProgressOverlay.body")
        let _ = TintTimelineProbe.noteHeaderConsumer("HeaderArtworkProgressOverlay")
        ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(1.2)
            .tint(presentedAccentColor)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private struct HeaderArtworkActionButton: View {
    @Environment(\.libraryPresentedAccentColor) private var presentedAccentColor

    let icon: String
    let colorScheme: ColorScheme
    let help: String
    let action: () -> Void

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("HeaderArtworkActionButton.body")
        let _ = TintTimelineProbe.noteHeaderConsumer("HeaderArtworkActionButton")
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(presentedAccentColor)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.thinMaterial)
        }
        .background {
            Circle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08))
        }
        .glassEffect(.clear, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        .help(help)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct HeaderPlayButton: View {
    @Environment(\.libraryPresentedAccentColor) private var presentedAccentColor

    let canPlay: Bool
    let colorScheme: ColorScheme
    let buttonHeight: CGFloat
    let action: () -> Void

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("HeaderPlayButton.body")
        let _ = TintTimelineProbe.noteHeaderConsumer("HeaderPlayButton")
        Button(action: action) {
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
                .fill(presentedAccentColor)
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
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct HeaderEditButton: View {
    @Environment(\.libraryPresentedAccentColor) private var presentedAccentColor

    let isEditing: Bool
    let colorScheme: ColorScheme
    let buttonHeight: CGFloat
    let symbolName: String
    let action: () -> Void

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("HeaderEditButton.body")
        let _ = TintTimelineProbe.noteHeaderConsumer("HeaderEditButton")
        Button(action: action) {
            Image(systemName: isEditing ? "checkmark" : symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    isEditing
                        ? .white
                        : presentedAccentColor.opacity(colorScheme == .dark ? 0.96 : 0.88)
                )
                .frame(width: buttonHeight, height: buttonHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if isEditing {
                Circle()
                    .fill(presentedAccentColor)
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
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
