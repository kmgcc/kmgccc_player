//
//  AllAlbumsView.swift
//  myPlayer2
//
//  Full Albums page reached from Home → Albums → "查看全部".
//  Lives in the main content area; reuses existing albumEntries,
//  deleteAlbum, and ArtworkLoader pipelines.
//

import AppKit
import SwiftUI

// MARK: - Sort Key

enum AlbumSortKey: String, CaseIterable, Identifiable {
    case title
    case artist
    case trackCount
    case totalDuration
    case updatedAt

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .title:         return "标题"
        case .artist:        return "艺人"
        case .trackCount:    return "歌曲数"
        case .totalDuration: return "总时长"
        case .updatedAt:     return "最近更新"
        }
    }
}

// MARK: - Deletion Request

private struct AlbumDeletionRequest: Identifiable {
    let entry: AlbumEntry
    let trackCount: Int
    var id: String { entry.id.uuidString }
}

// MARK: - View

struct AllAlbumsView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    @State private var searchText: String = ""
    @State private var sortKey: AlbumSortKey = .title
    @State private var sortAscending: Bool = true
    @State private var deletionRequest: AlbumDeletionRequest?

    var body: some View {
        let albums = filteredAlbums
        return VStack(spacing: 0) {
            header(albums.count)
            Divider().opacity(0.5)
            list(albums)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    }

    // MARK: Header

    private func header(_ count: Int) -> some View {
        HStack(spacing: 12) {
            Text("所有专辑")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)

            Text("\(count)")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()

            searchField
                .frame(maxWidth: 240)

            sortMenu
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索专辑或艺人", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortKey.allCases) { key in
                Button {
                    if sortKey == key {
                        sortAscending.toggle()
                    } else {
                        sortKey = key
                        sortAscending = true
                    }
                } label: {
                    HStack {
                        Text(key.localizedTitle)
                        if sortKey == key {
                            Spacer()
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
    }

    // MARK: List

    private func list(_ albums: [AlbumEntry]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 4) {
                ForEach(albums) { album in
                    AlbumListRow(
                        album: album,
                        trackCount: trackCount(for: album),
                        onOpen: { open(album) },
                        onDelete: { requestDelete(album) }
                    )
                }
                Color.clear.frame(height: 120) // mini-player headroom
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    // MARK: Data

    private var filteredAlbums: [AlbumEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [AlbumEntry]
        if trimmed.isEmpty {
            base = libraryVM.albumEntries
        } else {
            base = libraryVM.albumEntries.filter {
                $0.displayTitle.lowercased().contains(trimmed)
                || $0.primaryArtistDisplayName.lowercased().contains(trimmed)
            }
        }
        return base.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortKey {
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
            return sortAscending
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
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 76
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 16) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                    iconSize: 26,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 5, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(album.primaryArtistDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
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
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
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
                data = await Task.detached { firstTrack.loadArtworkDataIfNeeded() }.value
            }
        }
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: album.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 168, height: 168)
        )
        image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 168, height: 168)
        )
    }
}
