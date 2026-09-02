import SwiftUI

/// Duplicate review for library diagnostics. Deleting a track still goes
/// through the session-owned deletion pipeline; the sheet only keeps a small
/// local presentation state so a group with one remaining track stays visible
/// until the user closes and reopens the review.
struct LibraryDuplicateReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @EnvironmentObject private var themeStore: ThemeStore

    let snapshot: LibraryDiagnosticsSnapshot

    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?
    @State private var deletingTrackIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("重复歌曲审查")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
            }
            .padding(20)

            Divider()

            if snapshot.duplicateGroups.isEmpty {
                ContentUnavailableView("没有重复候选", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(snapshot.duplicateGroups) { group in
                    groupRow(group)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 680, height: 660)
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            deleteTracks(tracks)
        }
    }

    private func groupRow(_ group: LibraryDuplicateGroup) -> some View {
        let tracks = group.trackIDs.compactMap { trackID in
            libraryVM.allTracks.first { $0.id == trackID }
        }
        let canDelete = tracks.count > 1

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                if !group.artist.isEmpty {
                    Text("· \(group.artist)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            ForEach(tracks) { track in
                duplicateTrackRow(track, canDelete: canDelete)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func duplicateTrackRow(_ track: Track, canDelete: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: track.availability.isPlayable ? "music.note" : "exclamationmark.triangle")
                .foregroundStyle(
                    track.availability.isPlayable
                        ? themeStore.accentColor
                        : Color.orange
                )
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title.isEmpty ? "未命名歌曲" : track.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(displayPath(for: track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                playbackCoordinator.playTrack(track, inQueueFrom: [track])
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(themeStore.accentColor)
                    .background(themeStore.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放")
            .accessibilityLabel("播放")
            .disabled(!track.availability.isPlayable)

            if canDelete {
                Button {
                    trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.11), in: Circle())
                }
                .buttonStyle(.plain)
                .help("从资料库删除")
                .accessibilityLabel("从资料库删除")
                .disabled(deletingTrackIDs.contains(track.id))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 68)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func deleteTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let ids = Set(tracks.map(\.id))
        deletingTrackIDs.formUnion(ids)
        Task { @MainActor in
            await libraryVM.deleteTracks(tracks)
            deletingTrackIDs.subtract(ids)
        }
    }

    private func displayPath(for track: Track) -> String {
        switch track.mediaLocator {
        case let .managed(path):
            return track.resolvedAudioURL()?.path ?? path
        case let .referenced(locator):
            return locator.lastKnownPath
        }
    }

}
