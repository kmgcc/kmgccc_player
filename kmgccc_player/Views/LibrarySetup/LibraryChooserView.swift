import SwiftUI

struct LibraryChooserView: View {
    let libraries: [MusicLibraryBookmark]
    let onOpen: (MusicLibraryBookmark) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 8) {
                if libraries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(themeStore.accentColor)
                        Text("没有已添加的资料库")
                            .font(.headline)
                        Text("关闭后可从设置中打开或新建资料库。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else {
                    ForEach(libraries) { library in
                        Button { onOpen(library) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(themeStore.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(library.lastKnownPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: 220)
    }
}
