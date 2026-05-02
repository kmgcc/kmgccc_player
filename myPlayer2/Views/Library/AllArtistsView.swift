//
//  AllArtistsView.swift
//  myPlayer2
//
//  Full Artists page reached from Home → Artists → "查看全部".
//  Lives in the main content area; reuses existing artistEntries,
//  deleteArtist, and ArtistArtworkGenerator pipelines.
//
//  Search and sort are driven by the existing top toolbar, not by any
//  page-level controls. Toolbar search writes into
//  `PlaylistPageController.searchText`; toolbar sort writes into
//  `LibraryViewModel.artistSortKey` / `trackSortOrder`. This view simply
//  reads those values to filter and order its rows.
//

import AppKit
import SwiftUI

// MARK: - Deletion Request

private struct ArtistDeletionRequest: Identifiable {
    let entry: ArtistEntry
    let trackCount: Int
    var id: String { entry.id.uuidString }
}

// MARK: - View

struct AllArtistsView: View {
    let pageController: PlaylistPageController

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    @State private var deletionRequest: ArtistDeletionRequest?

    var body: some View {
        let artists = filteredArtists
        return list(artists)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(
            NSLocalizedString("sidebar.delete_artist_confirm_title", comment: ""),
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(
                NSLocalizedString("sidebar.delete_artist", comment: ""),
                role: .destructive
            ) {
                let entry = request.entry
                deletionRequest = nil
                Task { await libraryVM.deleteArtist(entry) }
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) { deletionRequest = nil }
        } message: { request in
            Text(
                String(
                    format: NSLocalizedString("sidebar.delete_artist_confirm_message", comment: ""),
                    request.entry.displayName,
                    request.trackCount
                )
            )
        }
    }

    // MARK: List

    private func list(_ artists: [ArtistEntry]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(artists) { artist in
                    ArtistListRow(
                        artist: artist,
                        trackCount: trackCount(for: artist),
                        albumCount: albumCount(for: artist),
                        onOpen: { open(artist) },
                        onDelete: { requestDelete(artist) }
                    )
                }
                Color.clear.frame(height: 120) // mini-player headroom
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    // MARK: Data

    private var filteredArtists: [ArtistEntry] {
        let trimmed = pageController.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base: [ArtistEntry]
        if trimmed.isEmpty {
            base = libraryVM.artistEntries
        } else {
            base = libraryVM.artistEntries.filter {
                $0.displayName.lowercased().contains(trimmed)
            }
        }
        let ascending = (libraryVM.trackSortOrder == .ascending)
        return base.sorted { lhs, rhs in
            let result: ComparisonResult
            switch libraryVM.artistSortKey {
            case .name:
                result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            case .trackCount:
                result = compareInt(lhs.trackCount, rhs.trackCount)
            case .albumCount:
                result = compareInt(lhs.albumCount, rhs.albumCount)
            case .totalDuration:
                result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            case .updatedAt:
                result = compareDate(lhs.updatedAt, rhs.updatedAt)
            }
            if result == .orderedSame {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
            return ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func trackCount(for artist: ArtistEntry) -> Int {
        if artist.trackCount > 0 { return artist.trackCount }
        let canonical = artist.canonicalName
        return libraryVM.allTracks.lazy
            .filter { LibraryNormalization.containsArtist(canonical, in: $0.artist) }
            .count
    }

    private func albumCount(for artist: ArtistEntry) -> Int {
        if artist.albumCount > 0 { return artist.albumCount }
        let canonical = artist.canonicalName
        let albums = libraryVM.allTracks.lazy
            .filter { LibraryNormalization.containsArtist(canonical, in: $0.artist) }
            .compactMap { $0.albumGroupKey }
        return Set(albums).count
    }

    private func open(_ artist: ArtistEntry) {
        uiState.pushSelectionInHomeContext(
            .artist(artist.canonicalName),
            libraryVM: libraryVM
        )
    }

    private func requestDelete(_ artist: ArtistEntry) {
        deletionRequest = ArtistDeletionRequest(
            entry: artist,
            trackCount: trackCount(for: artist)
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

private struct ArtistListRow: View {
    let artist: ArtistEntry
    let trackCount: Int
    let albumCount: Int
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 60

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
                Label("打开艺人", systemImage: "person.crop.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除艺人", systemImage: "trash")
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
                    cornerRadius: artworkSize / 2,
                    clipShape: .circle,
                    iconSize: 22,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(Circle())
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 4, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artist.displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(trackCount) 首歌曲")
                if albumCount > 0 {
                    Text("·")
                    Text("\(albumCount) 张专辑")
                }
                if artist.totalDuration > 0 {
                    Text("·")
                    Text(formattedDuration(artist.totalDuration))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开艺人", systemImage: "person.crop.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除艺人", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
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
        if let data = artist.artworkData, !data.isEmpty {
            let checksum = ArtworkLoader.checksum(for: data)
            let key = ArtworkLoader.cacheKey(
                trackID: artist.id,
                checksum: checksum,
                targetPixelSize: CGSize(width: 132, height: 132)
            )
            image = await ArtworkLoader.loadImage(
                artworkData: data,
                cacheKey: key,
                targetPixelSize: CGSize(width: 132, height: 132)
            )
            return
        }
        let canonical = artist.canonicalName
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.containsArtist(canonical, in: $0.artist)
        }
        image = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: artist.displayName,
            tracks: tracks
        )
    }
}
