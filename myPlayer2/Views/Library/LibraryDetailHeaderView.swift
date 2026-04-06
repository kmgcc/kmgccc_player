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
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Preference keys are defined in PlaylistDetailView.swift to be shared across views

private struct NormalizedImportedHeaderArtwork {
    let image: NSImage
    let pngData: Data
}

@MainActor
private final class HeaderArtworkPresentationState: ObservableObject {
    @Published private(set) var resolvedArtwork: ResolvedHeaderArtwork?

    private let resolver: DetailHeaderArtworkResolver
    private var activeSelectionIdentity: String?
    private var activeSelectionType: DetailHeaderArtworkSelectionType?
    private var loadTask: Task<Void, Never>?

    init(resolver: DetailHeaderArtworkResolver = .shared) {
        self.resolver = resolver
    }

    deinit {
        loadTask?.cancel()
    }

    func resolve(_ request: DetailHeaderArtworkRequest) {
        loadTask?.cancel()
        activeSelectionIdentity = request.selectionIdentity
        activeSelectionType = request.selectionType

        let immediate = resolver.resolveImmediately(for: request)
        if let immediate {
            accept(immediate, phase: "publish-accepted-immediate")
        }

        guard case .playlist = request, immediate == nil else { return }

        accept(
            ResolvedHeaderArtwork(
                selectionIdentity: request.selectionIdentity,
                selectionType: request.selectionType,
                source: .placeholder,
                image: nil,
                fileURL: nil,
                generationSignature: nil
            ),
            phase: "publish-accepted-pending-placeholder"
        )

        logState(
            "selectionType=\(request.selectionType.rawValue) selectionIdentity=\(request.debugSelectionID) phase=deferred-start pendingSource=placeholder"
        )

        loadTask = Task { [resolver] in
            let resolved = await resolver.resolveDeferredArtwork(for: request)
            await MainActor.run {
                guard let resolved else { return }
                self.accept(resolved, phase: "publish-accepted-deferred")
            }
        }
    }

    func publishImportedArtwork(_ artwork: ResolvedHeaderArtwork) {
        activeSelectionIdentity = artwork.selectionIdentity
        activeSelectionType = artwork.selectionType
        accept(artwork, phase: "publish-accepted-import")
    }

    /// Force publish artwork regardless of priority - used when explicitly switching sources
    func forcePublishArtwork(_ artwork: ResolvedHeaderArtwork) {
        activeSelectionIdentity = artwork.selectionIdentity
        activeSelectionType = artwork.selectionType
        // Clear current first to bypass priority check, then set new
        resolvedArtwork = nil
        resolvedArtwork = artwork
        logState(
            "selectionType=\(artwork.selectionType.rawValue) selectionIdentity=\(artwork.selectionIdentity) source=\(artwork.source.rawValue) phase=force-publish"
        )
    }

    private func accept(_ artwork: ResolvedHeaderArtwork, phase: String) {
        guard activeSelectionIdentity == artwork.selectionIdentity,
              activeSelectionType == artwork.selectionType
        else {
            logState(
                "selectionType=\(artwork.selectionType.rawValue) selectionIdentity=\(artwork.selectionIdentity) source=\(artwork.source.rawValue) filePath=\(artwork.fileURL?.path ?? "nil") publishDropped=stale-result phase=\(phase)"
            )
            return
        }

        if let current = resolvedArtwork,
           current.selectionIdentity == artwork.selectionIdentity,
           current.selectionType == artwork.selectionType,
           current.source.priority > artwork.source.priority
        {
            logState(
                "selectionType=\(artwork.selectionType.rawValue) selectionIdentity=\(artwork.selectionIdentity) source=\(artwork.source.rawValue) filePath=\(artwork.fileURL?.path ?? "nil") publishDropped=higher-priority-current currentSource=\(current.source.rawValue) phase=\(phase)"
            )
            return
        }

        resolvedArtwork = artwork
        logState(
            "selectionType=\(artwork.selectionType.rawValue) selectionIdentity=\(artwork.selectionIdentity) source=\(artwork.source.rawValue) filePath=\(artwork.fileURL?.path ?? "nil") phase=\(phase)"
        )
    }

    private func logState(_ message: String) {
        print("🎨 [HeaderArtworkState] \(message)")
    }
}

struct LibraryDetailHeaderView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let config: DetailHeaderConfig
    let onPlay: () -> Void
    let canPlay: Bool

    @State private var isEditing = false
    @State private var editDescription = ""
    @State private var editYear = ""
    @State private var isImportingArtwork = false
    @State private var isRegeneratingArtwork = false
    @StateObject private var artworkPresentation = HeaderArtworkPresentationState()

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
artworkColumn
            .frame(width: 220, height: 220)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: HeaderArtworkBoundsPreferenceKey.self,
                            value: geo.frame(in: .named("detailScroll"))
                        )
                        .preference(
                            key: HeaderArtworkImagePreferenceKey.self,
                            value: artworkPresentation.resolvedArtwork?.image
                        )
                }
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
        .onAppear { artworkPresentation.resolve(config.artworkRequest) }
        .onChange(of: config.artworkIdentity) { _, _ in
            artworkPresentation.resolve(config.artworkRequest)
        }
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
                if isRegeneratingArtwork {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(1.2)
                                .tint(themeStore.accentColor)
                        )
                        .clipShape(artworkClipShape)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

            if isEditing {
                HStack(spacing: 8) {
                    // Regenerate button (left)
                    artworkActionButton(
                        icon: "wand.and.stars",
                        action: { handleRegenerateArtwork() }
                    )

                    // Import button (right)
                    artworkActionButton(
                        icon: "photo.badge.plus",
                        action: { isImportingArtwork = true }
                    )
                }
                .padding(8)
            }
        }
    }

    /// Compact artwork action button with Liquid Glass styling
    private func artworkActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
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
    }

    @ViewBuilder
    private var artworkImage: some View {
        switch config {
        case .playlist:
            Group {
                if let img = artworkPresentation.resolvedArtwork?.image {
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
                if let img = artworkPresentation.resolvedArtwork?.image {
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
        case .album:
            Group {
                if let img = artworkPresentation.resolvedArtwork?.image {
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
                        artworkPresentation.publishImportedArtwork(
                            ResolvedHeaderArtwork(
                                selectionIdentity: config.selectionIdentity,
                                selectionType: .playlist,
                                source: .custom,
                                image: importedArtwork.image,
                                fileURL: LocalLibraryPaths.playlistCustomArtworkURL(for: playlist.id),
                                generationSignature: nil
                            )
                        )
                        // Trigger refresh to ensure halo also updates
                        artworkPresentation.resolve(config.artworkRequest)
                    }
                case .artist(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = importedArtwork.pngData
                    await libraryVM.saveArtistEntry(updated)
                    await MainActor.run {
                        artworkPresentation.publishImportedArtwork(
                            ResolvedHeaderArtwork(
                                selectionIdentity: config.selectionIdentity,
                                selectionType: .artist,
                                source: .custom,
                                image: importedArtwork.image,
                                fileURL: LocalLibraryPaths.artistFolderURL(for: entry.id)
                                    .appendingPathComponent("artwork.png"),
                                generationSignature: nil
                            )
                        )
                    }
                case .album(let entry, _):
                    var updated = entry
                    updated.artworkFileName = "artwork.png"
                    updated.artworkData = importedArtwork.pngData
                    await libraryVM.saveAlbumEntry(updated)
                    await MainActor.run {
                        artworkPresentation.publishImportedArtwork(
                            ResolvedHeaderArtwork(
                                selectionIdentity: config.selectionIdentity,
                                selectionType: .album,
                                source: .custom,
                                image: importedArtwork.image,
                                fileURL: LocalLibraryPaths.albumFolderURL(for: entry.id)
                                    .appendingPathComponent("artwork.png"),
                                generationSignature: nil
                            )
                        )
                    }
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

    private func handleRegenerateArtwork() {
        guard case .playlist(let playlist, let data) = config else { return }
        guard !isRegeneratingArtwork else { return }

        isRegeneratingArtwork = true

        Task {
            let tracks = data.tracks
            let snapshots: [(id: UUID, artworkData: Data?)] = tracks.map {
                (id: $0.id, artworkData: $0.artworkData)
            }

            // Use random seed for varied regeneration (produces different result each time)
            let variationSeed = Int.random(in: 0...Int.max)

            // Generate new artwork from tracks with variation
            guard let image = await PlaylistArtworkGenerator.shared.generateArtwork(
                playlistID: playlist.id,
                snapshots: snapshots,
                variationSeed: variationSeed
            ) else {
                await MainActor.run { isRegeneratingArtwork = false }
                return
            }

            // Persist the generated artwork and set it as active
            await MainActor.run {
                LocalLibraryService.shared.regeneratePlaylistArtwork(
                    playlistID: playlist.id,
                    tracks: tracks,
                    image: image
                )

                // Force immediate UI update with new artwork (bypasses priority check)
                let newArtwork = ResolvedHeaderArtwork(
                    selectionIdentity: config.selectionIdentity,
                    selectionType: .playlist,
                    source: .newlyGenerated,
                    image: image,
                    fileURL: LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlist.id),
                    generationSignature: nil
                )
                artworkPresentation.forcePublishArtwork(newArtwork)

                // Trigger a refresh by resolving again to ensure halo also updates
                artworkPresentation.resolve(config.artworkRequest)

                isRegeneratingArtwork = false
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
