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
    private static let visibleDescriptionLineCount = 7
    private static let maxHeaderDescriptionContentLines = 15

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
    @State private var lastArtistAutofillIdentity: String?
    @State private var isShowingArtistInfo = false
    @State private var isShowingAlbumInfo = false

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
                    if hasReadableDescription {
                        descriptionReadView
                    }
                }
                
                Spacer()
                
                headerButtonsView
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .leading)
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
        .task(id: config.artworkIdentity) {
            await handleAutomaticArtistArtworkFillIfNeeded()
        }
        .sheet(isPresented: $isShowingArtistInfo) {
            if case .artist(let entry, _) = config {
                ArtistInfoEditSheet(entry: entry) {
                    onArtworkMutation()
                }
                .presentationSizing(.page)
            }
        }
        .sheet(isPresented: $isShowingAlbumInfo) {
            if case .album(let entry, _) = config {
                AlbumInfoEditSheet(entry: entry) {
                    onArtworkMutation()
                }
                .presentationSizing(.page)
            }
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
                    if canSearchArtistArtwork {
                        artworkActionButton(
                            icon: "magnifyingglass",
                            help: NSLocalizedString("header.search_artist_artwork", comment: ""),
                            action: { handleSearchArtistArtwork() }
                        )
                    }

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
        case .artist(let entry, _):
            let parts = buildArtistMetaParts(entry: entry)
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .album(let entry, let stats):
            let parts = buildAlbumMetaParts(entry: entry, stats: stats)
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func buildArtistMetaParts(entry: ArtistEntry) -> [String] {
        var parts: [String] = []
        parts.append(contentsOf: entry.genreTags.prefix(3))
        if !entry.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(entry.region)
        }
        if !entry.foreignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(entry.foreignName)
        }
        return parts
    }

    private func buildAlbumMetaParts(entry: AlbumEntry, stats: AlbumDerivedStats) -> [String] {
        var parts: [String] = []
        if let year = entry.releaseYear ?? entry.year { parts.append(String(year)) }
        if !entry.albumType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(entry.albumType)
        }
        parts.append(contentsOf: entry.genreTags.prefix(3))
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

    private var headerDescriptionText: String {
        let normalized = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = normalized.components(separatedBy: .newlines)
        guard lines.count > Self.maxHeaderDescriptionContentLines else { return normalized }

        var clippedLines = Array(lines.prefix(Self.maxHeaderDescriptionContentLines))
        if let lastIndex = clippedLines.indices.last {
            let lastLine = clippedLines[lastIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            clippedLines[lastIndex] = lastLine.isEmpty ? "…" : "\(lastLine)…"
        }
        return clippedLines.joined(separator: "\n")
    }

    private var descriptionReadView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(headerDescriptionText)
                .font(.callout)
                .lineSpacing(0)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: headerDescriptionHeight(lineCount: Self.visibleDescriptionLineCount), alignment: .top)
        .scrollClipDisabled(false)
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerDescriptionHeight(lineCount: Int) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return ceil(lineHeight * CGFloat(lineCount) + 1)
    }

    private var hasReadableDescription: Bool {
        !currentDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            if canEditInfoFromArtwork {
                openInfoEditor()
            } else {
                if isEditing { commitEdits() } else { beginEditing() }
            }
        }
        .help(headerEditHelp)
    }

    private var buttonHeight: CGFloat {
        GlassStyleTokens.headerControlHeight
    }

    private var headerEditHelp: String {
        switch config {
        case .artist, .album:
            return "编辑信息"
        case .playlist:
            return isEditing ? "保存" : "编辑"
        }
    }

    private var canEditInfoFromArtwork: Bool {
        switch config {
        case .artist, .album:
            return true
        case .playlist:
            return false
        }
    }

    private func openInfoEditor() {
        switch config {
        case .artist:
            isShowingArtistInfo = true
        case .album:
            isShowingAlbumInfo = true
        case .playlist:
            break
        }
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
                let parsedYear = Int(yearStr)
                updated.year = parsedYear
                updated.releaseYear = parsedYear
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

    private var canSearchArtistArtwork: Bool {
        if case .artist = config {
            return true
        }
        return false
    }

    private func handleSearchArtistArtwork() {
        guard !isArtworkActionInFlight else { return }
        guard case .artist(let entry, _) = config else { return }

        isArtworkActionInFlight = true
        Task {
            let didApply = await libraryVM.replaceArtistArtworkFromProviders(entry)
            await MainActor.run {
                if didApply {
                    onArtworkMutation()
                }
                isArtworkActionInFlight = false
            }
        }
    }

    private func handleAutomaticArtistArtworkFillIfNeeded() async {
        guard case .artist(let entry, _) = config else { return }
        guard entry.artworkFileName == nil, entry.artworkData?.isEmpty != false else { return }

        let autofillIdentity = "\(entry.id.uuidString)-\(entry.updatedAt.timeIntervalSince1970)"
        guard lastArtistAutofillIdentity != autofillIdentity else { return }
        lastArtistAutofillIdentity = autofillIdentity

        let didApply = await libraryVM.autofillArtistArtworkIfMissing(entry)
        if didApply {
            await MainActor.run {
                onArtworkMutation()
            }
        }
    }

    private func handleRegenerateArtwork() {
        guard !isArtworkActionInFlight else { return }

        isArtworkActionInFlight = true

        Task {
            switch config {
            case .playlist(let playlist, let data):
                let tracks = data.tracks
                let snapshots = tracks.map { PlaylistArtworkSnapshot(track: $0) }
                let artworkDataCount = snapshots.filter { $0.artworkData?.isEmpty == false }.count
                let artworkFileURLCount = snapshots.filter { $0.artworkFileURL != nil }.count
                let existingArtworkFileCount = snapshots.filter {
                    guard let url = $0.artworkFileURL else { return false }
                    return FileManager.default.fileExists(atPath: url.path)
                }.count
                let variationSeed = Int.random(in: 0...Int.max)

                guard let image = await PlaylistArtworkGenerator.shared.generateArtwork(
                    playlistID: playlist.id,
                    snapshots: snapshots,
                    variationSeed: variationSeed
                ) else {
                    await MainActor.run {
                        print(
                            "🎨 [HeaderGenerateClick] phase=generator-failed playlistID=\(playlist.id) "
                                + "tracks=\(tracks.count) artworkData=\(artworkDataCount) "
                                + "artworkFileURL=\(artworkFileURLCount) fileExists=\(existingArtworkFileCount)"
                        )
                        isArtworkActionInFlight = false
                    }
                    return
                }

                await MainActor.run {
                    let didSave = LocalLibraryService.shared.regeneratePlaylistArtwork(
                        playlistID: playlist.id,
                        tracks: tracks,
                        image: image
                    )
                    if !didSave {
                        print(
                            "🎨 [HeaderGenerateClick] phase=writeback-failed playlistID=\(playlist.id) "
                                + "tracks=\(tracks.count)"
                        )
                    } else {
                        onArtworkMutation()
                    }
                    isArtworkActionInFlight = false
                }
            case .artist(let entry, _):
                let artistTracks = libraryVM.allTracks.filter {
                    LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist)
                        && $0.availability != .missing
                }
                let artistTrackSources = artistTracks.map { $0.artistArtworkSource() }
                guard let generatedArtwork = await ArtistArtworkGenerator.shared.generateArtwork(
                    artistName: entry.displayName,
                    trackSources: artistTrackSources
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

struct ArtistInfoEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @EnvironmentObject private var themeStore: ThemeStore

    let entry: ArtistEntry
    let onSaved: () -> Void

    @State private var displayName = ""
    @State private var description = ""
    @State private var genreTagsText = ""
    @State private var region = ""
    @State private var foreignName = ""
    @State private var qqMusicSingerMid = ""
    @State private var metadataSource = ""
    @State private var metadataFetchedAt: Date?
    @State private var metadataConfidence: Double?
    @State private var artworkData: Data?
    @State private var isImportingArtwork = false
    @State private var isMetadataLookupInFlight = false
    @State private var metadataMessage: String?
    @State private var isArtworkLookupInFlight = false
    @State private var isArtworkGenerationInFlight = false
    @State private var artworkMessage: String?
    @State private var artworkCandidates: [CoverCandidate] = []
    @State private var selectedArtworkCandidate: CoverCandidate?

    var body: some View {
        metadataEntitySheet(
            title: "编辑艺人信息",
            systemImage: "person.crop.circle",
            canSave: hasChanges,
            onCancel: { dismiss() },
            onSave: save
        ) {
            artworkEditor(
                data: artworkData,
                isLoading: isArtworkLookupInFlight,
                error: artworkMessage,
                candidates: artworkCandidates,
                selectedCandidate: selectedArtworkCandidate,
                chooseImage: { isImportingArtwork = true },
                searchArtwork: { searchArtwork() },
                generateArtworkTitle: "生成封面",
                isGeneratingArtwork: isArtworkGenerationInFlight,
                generateArtwork: { generateArtwork() },
                selectCandidate: { candidate in
                    selectedArtworkCandidate = candidate
                    artworkData = candidate.imageData
                }
            )

            Divider()

            labeledField("艺人名称", prompt: "艺人名称", text: $displayName)
            labeledEditor("介绍", prompt: "添加艺人介绍…", text: $description)
            labeledField("流派 / 标签", prompt: "用逗号分隔", text: $genreTagsText)
            labeledField("地区", prompt: "地区", text: $region)
            labeledField("外文名", prompt: "外文名", text: $foreignName)

            metadataLookupButton(isLoading: isMetadataLookupInFlight, message: metadataMessage) {
                fetchMetadata()
            }

            readonlyMetadataBlock(rows: [
                ("QQMusic Singer MID", qqMusicSingerMid),
                ("来源", metadataSource),
                ("获取时间", metadataFetchedAt.map(formatMetadataDate) ?? ""),
                ("置信度", metadataConfidence.map { String(format: "%.2f", $0) } ?? ""),
            ])
        }
        .tint(themeStore.accentColor)
        .onAppear(perform: load)
        .fileImporter(
            isPresented: $isImportingArtwork,
            allowedContentTypes: [UTType.jpeg, UTType.png, UTType.heic, UTType.tiff],
            allowsMultipleSelection: false
        ) { result in
            importArtwork(result)
        }
    }

    private var hasChanges: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines) != entry.displayName
            || description != entry.description
            || parsedGenreTags(from: genreTagsText) != entry.genreTags
            || region.trimmingCharacters(in: .whitespacesAndNewlines) != entry.region
            || foreignName.trimmingCharacters(in: .whitespacesAndNewlines) != entry.foreignName
            || optionalTrimmed(qqMusicSingerMid) != entry.qqMusicSingerMid
            || optionalTrimmed(metadataSource) != entry.metadataSource
            || metadataFetchedAt != entry.metadataFetchedAt
            || metadataConfidence != entry.metadataConfidence
            || artworkData != entry.artworkData
    }

    private func load() {
        displayName = entry.displayName
        description = entry.description
        genreTagsText = entry.genreTags.joined(separator: ", ")
        region = entry.region
        foreignName = entry.foreignName
        qqMusicSingerMid = entry.qqMusicSingerMid ?? ""
        metadataSource = entry.metadataSource ?? ""
        metadataFetchedAt = entry.metadataFetchedAt
        metadataConfidence = entry.metadataConfidence
        artworkData = entry.artworkData
    }

    private func currentDraft() -> ArtistEntry {
        var draft = entry
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            draft.displayName = trimmedName
        }
        draft.description = description
        draft.genreTags = parsedGenreTags(from: genreTagsText)
        draft.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.foreignName = foreignName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.qqMusicSingerMid = optionalTrimmed(qqMusicSingerMid)
        draft.metadataSource = optionalTrimmed(metadataSource)
        draft.metadataFetchedAt = metadataFetchedAt
        draft.metadataConfidence = metadataConfidence
        draft.artworkData = artworkData
        draft.artworkFileName = artworkData == nil ? nil : "artwork.png"
        return draft
    }

    private func fetchMetadata() {
        isMetadataLookupInFlight = true
        metadataMessage = nil
        Task {
            let draft = currentDraft()
            let updated = await libraryVM.fetchMissingArtistMetadataDraft(draft)
            await MainActor.run {
                isMetadataLookupInFlight = false
                guard let updated else {
                    metadataMessage = hasRecordedMetadataSource
                        ? "QQMusic 未返回介绍/标签等字段"
                        : "没有可补全字段"
                    return
                }
                description = updated.description
                genreTagsText = updated.genreTags.joined(separator: ", ")
                region = updated.region
                foreignName = updated.foreignName
                qqMusicSingerMid = updated.qqMusicSingerMid ?? ""
                metadataSource = updated.metadataSource ?? ""
                metadataFetchedAt = updated.metadataFetchedAt
                metadataConfidence = updated.metadataConfidence
                metadataMessage = "已补全缺失字段"
            }
        }
    }

    private func searchArtwork() {
        isArtworkLookupInFlight = true
        artworkMessage = nil
        artworkCandidates = []
        selectedArtworkCandidate = nil
        Task {
            let candidates = await libraryVM.searchArtistArtworkCandidates(currentDraft())
            await MainActor.run {
                isArtworkLookupInFlight = false
                artworkCandidates = candidates
                artworkMessage = candidates.isEmpty ? "没有找到可用封面" : nil
            }
        }
    }

    private func generateArtwork() {
        guard !isArtworkGenerationInFlight else { return }
        isArtworkGenerationInFlight = true
        artworkMessage = nil
        Task {
            let artistTracks = libraryVM.allTracks.filter {
                LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist)
                    && $0.availability != .missing
            }
            let trackSources = artistTracks.map { $0.artistArtworkSource() }
            let image = await ArtistArtworkGenerator.shared.generateArtwork(
                artistName: entry.displayName,
                trackSources: trackSources
            )
            await MainActor.run {
                isArtworkGenerationInFlight = false
                guard let pngData = image?.pngData() else {
                    artworkMessage = "无法生成封面"
                    return
                }
                artworkData = pngData
                selectedArtworkCandidate = nil
            }
        }
    }

    private var hasRecordedMetadataSource: Bool {
        !qqMusicSingerMid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !metadataSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || metadataFetchedAt != nil
            || metadataConfidence != nil
    }

    private func save() {
        let updated = currentDraft()
        Task {
            await libraryVM.saveArtistEdits(original: entry, updated: updated)
            await MainActor.run {
                onSaved()
                dismiss()
            }
        }
    }

    private func importArtwork(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        guard let imported = normalizedImportedArtwork(from: url) else { return }
        artworkData = imported.pngData
        selectedArtworkCandidate = nil
    }
}

struct AlbumInfoEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @EnvironmentObject private var themeStore: ThemeStore

    let entry: AlbumEntry
    let onSaved: () -> Void

    @State private var displayTitle = ""
    @State private var description = ""
    @State private var releaseYearText = ""
    @State private var releaseDateText = ""
    @State private var albumType = ""
    @State private var genreTagsText = ""
    @State private var language = ""
    @State private var labelOrCompany = ""
    @State private var qqMusicAlbumMid = ""
    @State private var metadataSource = ""
    @State private var metadataFetchedAt: Date?
    @State private var metadataConfidence: Double?
    @State private var artworkData: Data?
    @State private var isImportingArtwork = false
    @State private var isMetadataLookupInFlight = false
    @State private var metadataMessage: String?
    @State private var isArtworkGenerationInFlight = false
    @State private var coverCoordinator: CoverSearchCoordinator?

    var body: some View {
        metadataEntitySheet(
            title: "编辑专辑信息",
            systemImage: "rectangle.stack",
            canSave: hasChanges,
            onCancel: { dismiss() },
            onSave: save
        ) {
            artworkEditor(
                data: artworkData,
                isLoading: coverCoordinator?.isLoading == true,
                error: coverCoordinator?.error,
                candidates: coverCoordinator?.candidates ?? [],
                selectedCandidate: coverCoordinator?.selectedForPreview,
                chooseImage: { isImportingArtwork = true },
                searchArtwork: { searchArtwork() },
                generateArtworkTitle: "使用歌曲封面",
                isGeneratingArtwork: isArtworkGenerationInFlight,
                generateArtwork: { restoreDefaultArtworkIntoDraft() },
                selectCandidate: { candidate in
                    coverCoordinator?.selectForPreview(candidate)
                    artworkData = candidate.imageData
                }
            )

            Divider()

            labeledField("专辑名称", prompt: "专辑名称", text: $displayTitle)
            labeledEditor("介绍", prompt: "添加专辑介绍…", text: $description)
            labeledField("发行年份", prompt: "YYYY", text: $releaseYearText)
            labeledField("发行日期", prompt: "YYYY-MM-DD", text: $releaseDateText)
            labeledField("专辑类型", prompt: "专辑类型", text: $albumType)
            labeledField("流派 / 标签", prompt: "用逗号分隔", text: $genreTagsText)
            labeledField("语言", prompt: "语言", text: $language)
            labeledField("厂牌 / 公司", prompt: "厂牌或公司", text: $labelOrCompany)

            metadataLookupButton(isLoading: isMetadataLookupInFlight, message: metadataMessage) {
                fetchMetadata()
            }

            readonlyMetadataBlock(rows: [
                ("QQMusic Album MID", qqMusicAlbumMid),
                ("来源", metadataSource),
                ("获取时间", metadataFetchedAt.map(formatMetadataDate) ?? ""),
                ("置信度", metadataConfidence.map { String(format: "%.2f", $0) } ?? ""),
            ])
        }
        .tint(themeStore.accentColor)
        .onAppear {
            load()
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
        }
        .onDisappear {
            coverCoordinator?.cancelSearch()
        }
        .fileImporter(
            isPresented: $isImportingArtwork,
            allowedContentTypes: [UTType.jpeg, UTType.png, UTType.heic, UTType.tiff],
            allowsMultipleSelection: false
        ) { result in
            importArtwork(result)
        }
    }

    private var hasChanges: Bool {
        displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) != entry.displayTitle
            || description != entry.description
            || Int(releaseYearText.trimmingCharacters(in: .whitespacesAndNewlines)) != entry.releaseYear
            || parseEditingDate(releaseDateText) != entry.releaseDate
            || albumType.trimmingCharacters(in: .whitespacesAndNewlines) != entry.albumType
            || parsedGenreTags(from: genreTagsText) != entry.genreTags
            || language.trimmingCharacters(in: .whitespacesAndNewlines) != entry.language
            || labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines) != entry.labelOrCompany
            || optionalTrimmed(qqMusicAlbumMid) != entry.qqMusicAlbumMid
            || optionalTrimmed(metadataSource) != entry.metadataSource
            || metadataFetchedAt != entry.metadataFetchedAt
            || metadataConfidence != entry.metadataConfidence
            || artworkData != entry.artworkData
    }

    private func load() {
        displayTitle = entry.displayTitle
        description = entry.description
        releaseYearText = entry.releaseYear.map(String.init) ?? entry.year.map(String.init) ?? ""
        releaseDateText = formatDateForEditing(entry.releaseDate)
        albumType = entry.albumType
        genreTagsText = entry.genreTags.joined(separator: ", ")
        language = entry.language
        labelOrCompany = entry.labelOrCompany
        qqMusicAlbumMid = entry.qqMusicAlbumMid ?? ""
        metadataSource = entry.metadataSource ?? ""
        metadataFetchedAt = entry.metadataFetchedAt
        metadataConfidence = entry.metadataConfidence
        artworkData = entry.artworkData
    }

    private func currentDraft() -> AlbumEntry {
        var draft = entry
        let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let releaseYear = Int(releaseYearText.trimmingCharacters(in: .whitespacesAndNewlines))
        if !trimmedTitle.isEmpty {
            draft.displayTitle = trimmedTitle
        }
        draft.description = description
        draft.year = releaseYear
        draft.releaseYear = releaseYear
        draft.releaseDate = parseEditingDate(releaseDateText)
        draft.albumType = albumType.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.genreTags = parsedGenreTags(from: genreTagsText)
        draft.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.labelOrCompany = labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.qqMusicAlbumMid = optionalTrimmed(qqMusicAlbumMid)
        draft.metadataSource = optionalTrimmed(metadataSource)
        draft.metadataFetchedAt = metadataFetchedAt
        draft.metadataConfidence = metadataConfidence
        draft.artworkData = artworkData
        draft.artworkFileName = artworkData == nil ? nil : "artwork.png"
        return draft
    }

    private func fetchMetadata() {
        isMetadataLookupInFlight = true
        metadataMessage = nil
        Task {
            let draft = currentDraft()
            let updated = await libraryVM.fetchMissingAlbumMetadataDraft(draft)
            await MainActor.run {
                isMetadataLookupInFlight = false
                guard let updated else {
                    metadataMessage = "没有可补全字段"
                    return
                }
                description = updated.description
                releaseYearText = updated.releaseYear.map(String.init) ?? updated.year.map(String.init) ?? ""
                releaseDateText = formatDateForEditing(updated.releaseDate)
                albumType = updated.albumType
                genreTagsText = updated.genreTags.joined(separator: ", ")
                language = updated.language
                labelOrCompany = updated.labelOrCompany
                qqMusicAlbumMid = updated.qqMusicAlbumMid ?? ""
                metadataSource = updated.metadataSource ?? ""
                metadataFetchedAt = updated.metadataFetchedAt
                metadataConfidence = updated.metadataConfidence
                metadataMessage = "已补全缺失字段"
            }
        }
    }

    private func searchArtwork() {
        Task {
            await coverCoordinator?.search(
                artist: entry.primaryArtistDisplayName,
                album: entry.displayTitle,
                title: nil,
                duration: nil
            )
        }
    }

    private func restoreDefaultArtworkIntoDraft() {
        guard !isArtworkGenerationInFlight else { return }
        isArtworkGenerationInFlight = true
        metadataMessage = nil
        Task {
            let track = libraryVM.allTracks.first { $0.albumGroupKey == entry.canonicalKey }
            let fallback = await track?.loadArtworkDataOffMainIfNeeded()
            await MainActor.run {
                isArtworkGenerationInFlight = false
                guard let fallback, !fallback.isEmpty else {
                    metadataMessage = "没有可用的歌曲封面"
                    return
                }
                artworkData = fallback
                coverCoordinator?.clear()
                metadataMessage = "已使用歌曲封面，保存后生效"
            }
        }
    }

    private func save() {
        let updated = currentDraft()
        Task {
            await libraryVM.saveAlbumEdits(original: entry, updated: updated)
            await MainActor.run {
                onSaved()
                dismiss()
            }
        }
    }

    private func importArtwork(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        guard let imported = normalizedImportedArtwork(from: url) else { return }
        artworkData = imported.pngData
        coverCoordinator?.clear()
    }
}

private func metadataEntitySheet<Content: View>(
    title: String,
    systemImage: String,
    canSave: Bool,
    onCancel: @escaping () -> Void,
    onSave: @escaping () -> Void,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(spacing: 0) {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.title2.bold())
            Spacer()
            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                onCancel()
            }
        }
        .padding()

        Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                clearCurrentTextInputFocus()
            }
        }

        Divider()

        HStack {
            Button("取消") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .keyboardShortcut(.escape)

            Spacer()
            Button("保存") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .keyboardShortcut(.return)
            .disabled(!canSave)
        }
        .padding()
    }
    .frame(width: 560, height: 720)
}

private func artworkEditor(
    data: Data?,
    isLoading: Bool,
    error: String?,
    candidates: [CoverCandidate],
    selectedCandidate: CoverCandidate?,
    chooseImage: @escaping () -> Void,
    searchArtwork: @escaping () -> Void,
    generateArtworkTitle: String?,
    isGeneratingArtwork: Bool,
    generateArtwork: (() -> Void)?,
    selectCandidate: @escaping (CoverCandidate) -> Void
) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Label("封面", systemImage: "photo")
            .font(.headline)

        HStack(spacing: 16) {
            ZStack {
                Group {
                    if let data, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if isLoading || isGeneratingArtwork {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("选择图片", action: chooseImage)
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                Button("查找封面", action: searchArtwork)
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(isLoading)

                if let generateArtworkTitle, let generateArtwork {
                    Button(generateArtworkTitle, action: generateArtwork)
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                        .disabled(isGeneratingArtwork)
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !candidates.isEmpty {
                CoverCandidateStripView(
                    candidates: candidates,
                    selectedCandidate: selectedCandidate,
                    onSelect: selectCandidate
                )
            }
        }
    }
}

private func metadataLookupButton(
    isLoading: Bool,
    message: String?,
    action: @escaping () -> Void
) -> some View {
    HStack {
        Button {
            action()
        } label: {
            Label("查找元数据", systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .clipShape(Capsule())
        .disabled(isLoading)

        if isLoading {
            ProgressView()
                .controlSize(.small)
        }

        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private func labeledField(_ label: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
    }
}

private func labeledEditor(_ label: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.body)
                .lineSpacing(4)
                .padding(8)
                .frame(height: 148)
                .scrollContentBackground(.hidden)
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(prompt)
                    .foregroundStyle(.tertiary)
                    .font(.body)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .padding(.trailing, 18)
    }
}

private func readonlyMetadataBlock(rows: [(String, String)]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text("来源信息")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        ForEach(rows, id: \.0) { label, value in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .frame(width: 142, alignment: .leading)
                    .foregroundStyle(.tertiary)
                Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未记录" : value)
                    .textSelection(.enabled)
            }
        }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
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

    return NormalizedImportedHeaderArtwork(image: cropped, pngData: pngData)
}

private func parsedGenreTags(from text: String) -> [String] {
    var seen = Set<String>()
    return text
        .split { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" }
        .compactMap { part in
            let tag = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
}

private func optionalTrimmed(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func formatDateForEditing(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func parseEditingDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: trimmed)
}

private func formatMetadataDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
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
