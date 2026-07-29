import SwiftUI

struct LibraryChooserView: View {
    let libraries: [MusicLibraryBookmark]
    let onOpen: (MusicLibraryBookmark) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                Button { onOpen(library) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(library.displayName).lineLimit(1).truncationMode(.middle)
                        Text(library.lastKnownPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                if index < libraries.count - 1 { Divider() }
            }
        }
    }
}
