//
//  AllAlbumsView.swift
//  myPlayer2
//
//  Full Albums page reached from Home → Albums → "查看全部".
//  Lives in the main content area; reuses existing albumEntries,
//  deleteAlbum, and ArtworkLoader pipelines.
//
//  Search and sort are driven by the existing top toolbar, not by any
//  page-level controls. Toolbar search writes into
//  `PlaylistPageController.searchText`; toolbar sort writes into
//  `LibraryViewModel.albumSortKey` / `trackSortOrder`. This view simply
//  reads those values to filter and order its rows.
//

import AppKit
import SwiftUI

// MARK: - Deletion Request

private struct AlbumDeletionRequest: Identifiable {
    let entry: AlbumEntry
    let trackCount: Int
    var id: String { entry.id.uuidString }
}

// MARK: - View

struct AllAlbumsView: View {
    let pageController: PlaylistPageController

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var deletionRequest: AlbumDeletionRequest?
    @State private var editingAlbum: AlbumEntry?

    var body: some View {
        // Resolve once per ThemeStore tick so AlbumListRow receives plain
        // Color params and doesn't need its own ThemeStore subscription.
        let palette = themeStore.appForegroundPalette
        let primary = Color(nsColor: palette.primary)
        let secondary = Color(nsColor: palette.secondary)
        let tertiary = Color(nsColor: palette.tertiary)
        let albums = filteredAlbums
        return list(
            albums,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            let token = FirstUseHitchDiagnostics.begin(
                "AllAlbumsView.onAppear",
                detail: "albums=\(libraryVM.albumEntries.count), tracks=\(libraryVM.allTracks.count)"
            )
            FirstUseHitchDiagnostics.end(token)
        }
        .alert(
            NSLocalizedString("sidebar.delete_album_confirm_title", comment: ""),
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(
                NSLocalizedString("sidebar.delete_album", comment: ""),
                role: .destructive
            ) {
                let entry = request.entry
                deletionRequest = nil
                Task { await libraryVM.deleteAlbum(entry) }
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) { deletionRequest = nil }
        } message: { request in
            Text(
                String(
                    format: NSLocalizedString("sidebar.delete_album_confirm_message", comment: ""),
                    request.entry.displayTitle,
                    request.trackCount
                )
            )
        }
        .sheet(item: $editingAlbum) { entry in
            AlbumInfoEditSheet(entry: entry) {}
                .presentationSizing(.page)
        }
    }

    // MARK: List

    private func list(
        _ albums: [AlbumEntry],
        primary: Color,
        secondary: Color,
        tertiary: Color
    ) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(albums) { album in
                    AlbumListRow(
                        album: album,
                        trackCount: trackCount(for: album),
                        titleColor: primary,
                        subtitleColor: secondary,
                        metaColor: tertiary,
                        onOpen: { open(album) },
                        onEdit: { editingAlbum = album },
                        onDelete: { requestDelete(album) }
                    )
                }
                Color.clear.frame(height: 120) // mini-player headroom
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    // MARK: Data

    private var filteredAlbums: [AlbumEntry] {
        let token = FirstUseHitchDiagnostics.begin(
            "AllAlbumsView.filteredAlbums",
            detail: "albums=\(libraryVM.albumEntries.count)"
        )
        defer { FirstUseHitchDiagnostics.end(token) }

        let trimmed = pageController.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base: [AlbumEntry]
        if trimmed.isEmpty {
            base = libraryVM.albumEntries
        } else {
            base = libraryVM.albumEntries.filter {
                $0.displayTitle.lowercased().contains(trimmed)
                || $0.primaryArtistDisplayName.lowercased().contains(trimmed)
            }
        }
        let ascending = (libraryVM.trackSortOrder == .ascending)
        return base.sorted { lhs, rhs in
            let result: ComparisonResult
            switch libraryVM.albumSortKey {
            case .title:
                result = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            case .artist:
                result = lhs.primaryArtistDisplayName
                    .localizedCaseInsensitiveCompare(rhs.primaryArtistDisplayName)
            case .trackCount:
                result = compareInt(lhs.trackCount, rhs.trackCount)
            case .totalDuration:
                result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            case .updatedAt:
                result = compareDate(lhs.updatedAt, rhs.updatedAt)
            }
            if result == .orderedSame {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                    == .orderedAscending
            }
            return ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func trackCount(for album: AlbumEntry) -> Int {
        // albumEntries.trackCount is derived at sync time but may be 0 if disk
        // sidecar is fresher than derived stats. Recompute defensively.
        if album.trackCount > 0 { return album.trackCount }
        return libraryVM.allTracks.lazy
            .filter { $0.albumGroupKey == album.canonicalKey }
            .count
    }

    private func open(_ album: AlbumEntry) {
        libraryVM.selectedAlbumName = album.displayTitle
        uiState.pushSelectionInHomeContext(
            .album(album.canonicalKey),
            libraryVM: libraryVM
        )
    }

    private func requestDelete(_ album: AlbumEntry) {
        deletionRequest = AlbumDeletionRequest(
            entry: album,
            trackCount: trackCount(for: album)
        )
    }

    private func compareInt(_ a: Int, _ b: Int) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDouble(_ a: Double, _ b: Double) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    private func compareDate(_ a: Date, _ b: Date) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}

// MARK: - Row

private struct AlbumListRow: View {
    let album: AlbumEntry
    let trackCount: Int
    var titleColor: Color = .primary
    var subtitleColor: Color = .secondary
    var metaColor: Color = Color.secondary.opacity(0.7)
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 60
    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 14) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering
                      ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Button(action: onEdit) {
                Label("编辑专辑", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        }
        .task { await loadArtwork() }
    }

    private var artworkView: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholderView(
                    size: artworkSize,
                    cornerRadius: cornerRadius,
                    clipShape: .continuous,
                    iconSize: 22,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 4, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
            Text(album.primaryArtistDisplayName)
                .font(.system(size: 12))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(trackCount) 首歌曲")
                if album.totalDuration > 0 {
                    Text("·")
                    Text(formattedDuration(album.totalDuration))
                }
                if let year = album.year, year > 0 {
                    Text("·")
                    Text(String(year))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(metaColor)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Button(action: onEdit) {
                Label("编辑专辑", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(subtitleColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .opacity(isHovering ? 1 : 0.4)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }

    private func loadArtwork() async {
        var data = album.artworkData
        if data == nil || data!.isEmpty {
            let key = album.canonicalKey
            if let firstTrack = libraryVM.allTracks.first(where: { $0.albumGroupKey == key }) {
                data = await firstTrack.loadArtworkDataOffMainIfNeeded()
            }
        }
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: album.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 132, height: 132)
        )
        image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 132, height: 132)
        )
    }
}
