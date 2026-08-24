import AppKit
import SwiftUI

/// Read-only duplicate review. It intentionally has no delete button: a
/// duplicate candidate is a hint, not proof that either Track or external
/// audio may be removed.
struct LibraryDuplicateReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @EnvironmentObject private var themeStore: ThemeStore

    let snapshot: LibraryDiagnosticsSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("重复歌曲审查")
                        .font(.title2.weight(.semibold))
                    Text("这里只展示候选项，不会自动删除歌曲或外部文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(themeStore.accentColor)
            }
            .padding(20)

            Divider()

            if snapshot.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    "没有重复候选",
                    systemImage: "checkmark.circle",
                    description: Text("当前资料库没有发现相同物理文件或高度相同的歌曲信息。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(snapshot.duplicateGroups) { group in
                    groupRow(group)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 640, height: 620)
    }

    private func groupRow(_ group: LibraryDuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(group.reason.displayName)
                    .font(.caption)
                    .foregroundStyle(
                        group.reason == .samePhysicalFile ? Color.orange : Color.secondary
                    )
                Spacer(minLength: 0)
                Text("\(group.trackIDs.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !group.artist.isEmpty {
                Text(group.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(group.trackIDs, id: \.self) { trackID in
                if let track = libraryVM.allTracks.first(where: { $0.id == trackID }) {
                    HStack(spacing: 8) {
                        Image(systemName: track.availability.isPlayable ? "music.note" : "exclamationmark.triangle")
                            .foregroundStyle(
                                track.availability.isPlayable
                                    ? themeStore.accentColor
                                    : Color.orange
                            )
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .lineLimit(1)
                            Text(displayPath(for: track))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button {
                            reveal(track)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("在访达中显示")
                        .disabled(!hasFile(at: displayPath(for: track)))
                    }
                } else {
                    Text("歌曲已不在当前快照中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func displayPath(for track: Track) -> String {
        switch track.mediaLocator {
        case let .managed(path):
            return track.resolvedAudioURL()?.path ?? path
        case let .referenced(locator):
            return locator.lastKnownPath
        }
    }

    private func hasFile(at path: String) -> Bool {
        FinderRevealHelper.fileExists(atPath: path)
    }

    private func reveal(_ track: Track) {
        FinderRevealHelper.reveal(path: displayPath(for: track))
    }
}
