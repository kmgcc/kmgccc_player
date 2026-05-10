//
//  HomeArtistsSection.swift
//  myPlayer2
//
//  Horizontal scrolling artist circles for the Home page.
//
//  Section title aligns inside the center column; the carousel viewport
//  spans the full window width with the first circle anchored at the
//  center column's left edge.
//

import AppKit
import SwiftUI

struct HomeArtistsSection: View {
    let artists: [ArtistEntry]
    var mode: HomeLayoutMode = .wide
    let centerLeftPad: CGFloat
    let centerRightPad: CGFloat

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @State private var deletionRequest: HomeArtistDeletionRequest?
    @State private var editingArtist: ArtistEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
            carousel
        }
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
        .sheet(item: $editingArtist) { entry in
            ArtistInfoEditSheet(entry: entry) {}
                .presentationSizing(.page)
        }
    }

    @ViewBuilder
    private var carousel: some View {
        HorizontalFadeScrollContainer(
            spacing: rowSpacing,
            fadeWidth: 0,
            verticalPadding: 22,
            leadingScrollPadding: centerLeftPad + 4,
            trailingScrollPadding: max(4, centerRightPad - 8),
            showsEdgeFade: false,
            showsScrollButtons: true,
            scrollButtonLeadingInset: centerLeftPad + 8,
            scrollButtonTrailingInset: max(12, centerRightPad + 8)
        ) {
            ForEach(artists) { artist in
                HomeArtistCircle(
                    artist: artist,
                    mode: mode,
                    onOpen: { open(artist) },
                    onPlay: { play(artist) },
                    onEdit: { editingArtist = artist },
                    onDelete: { requestDelete(artist) }
                )
            }
        }
    }

    private var circleSize: CGFloat {
        switch mode {
        case .wide:    return 136
        case .medium:  return 120
        case .compact: return 104
        case .narrow:  return 90
        }
    }

    private var rowSpacing: CGFloat {
        switch mode {
        case .wide:    return 16
        case .medium:  return 12
        case .compact: return 10
        case .narrow:  return 10
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("艺人")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
            viewAllButton
        }
    }

    private var viewAllButton: some View {
        Button {
            uiState.pushSelectionInHomeContext(
                .allArtists,
                libraryVM: libraryVM
            )
        } label: {
            HStack(spacing: 2) {
                Text("查看全部")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func open(_ artist: ArtistEntry) {
        uiState.navigateFromHome(
            to: .artist(artist.canonicalName),
            libraryVM: libraryVM
        )
    }

    private func play(_ artist: ArtistEntry) {
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.containsArtist(artist.canonicalName, in: $0.artist)
        }
        playbackCoordinator.playRandomTracks(
            tracks,
            libraryQueueSource: .librarySelection("home-artist-\(artist.canonicalName)")
        )
    }

    private func requestDelete(_ artist: ArtistEntry) {
        deletionRequest = HomeArtistDeletionRequest(
            entry: artist,
            trackCount: artist.trackCount
        )
    }
}

private struct HomeArtistDeletionRequest: Identifiable {
    let entry: ArtistEntry
    let trackCount: Int
    var id: UUID { entry.id }
}

// MARK: - Artist circle

private struct HomeArtistCircle: View {
    let artist: ArtistEntry
    let mode: HomeLayoutMode
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @State private var image: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var circleSize: CGFloat {
        switch mode {
        case .wide:    return 136
        case .medium:  return 120
        case .compact: return 104
        case .narrow:  return 90
        }
    }

    private var titleFontSize: CGFloat {
        switch mode {
        case .wide, .medium: return 14
        case .compact:       return 13
        case .narrow:        return 12
        }
    }

    var body: some View {
        VStack(spacing: mode == .narrow ? 8 : 12) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholderView(
                        size: circleSize,
                        clipShape: .circle,
                        iconSize: 28,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: circleSize, height: circleSize)
            .clipShape(Circle())

            VStack(spacing: 3) {
                Text(artist.displayName)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: circleSize + (mode == .narrow ? 26 : 32))
        .homeUnifiedGlassCard(
            cornerRadius: 18,
            colorScheme: colorScheme,
            isFloating: true
        )
        .overlay(
            // Cheap hover indicator: stroke overlay only on the current card.
            // Avoids the previous `scaleEffect + animation`, which forced the
            // card's glass material to re-composite at a new scale every time
            // the cursor crossed a card during scroll. With ~30 cards across
            // Artists+Albums, that compositing storm was a real per-frame
            // GPU+CPU hit during outer vertical scroll.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isHovering ? 0.18 : 0),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onPlay) {
                Label("播放该艺人", systemImage: "play.fill")
            }

            Button(action: onOpen) {
                Label("打开艺人", systemImage: "person.crop.circle")
            }
            Button(action: onEdit) {
                Label("编辑艺人", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("删除艺人", systemImage: "trash")
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        if let data = artist.artworkData, !data.isEmpty {
            let checksum = ArtworkLoader.checksum(for: data)
            let key = ArtworkLoader.cacheKey(
                trackID: artist.id,
                checksum: checksum,
                targetPixelSize: CGSize(width: 256, height: 256)
            )
            let loaded = await ArtworkLoader.loadImage(
                artworkData: data,
                cacheKey: key,
                targetPixelSize: CGSize(width: 256, height: 256)
            )
            image = loaded
            return
        }

        let canonicalName = artist.canonicalName
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.containsArtist(canonicalName, in: $0.artist)
        }
        let trackSources = tracks.map { $0.artistArtworkSource() }
        let generated = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: artist.displayName,
            trackSources: trackSources
        )
        image = generated
    }
}
