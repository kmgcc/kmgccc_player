import SwiftUI

nonisolated struct MusicSettingsContentModel: Sendable {
    struct LibraryRow: Identifiable, Sendable {
        let id: UUID
        let name: String
        let path: String
        let isActive: Bool
    }
    struct SourceRow: Identifiable, Sendable {
        let id: UUID
        let name: String
        let path: String
        let status: String
        let scanState: ReferencedSourceScanState
    }
    let mode: MusicLibraryMode
    let libraries: [LibraryRow]
    let sources: [SourceRow]
    let deletePolicy: ReferencedTrackDeletePolicy
}

struct MusicSettingsContent: View {
    let model: MusicSettingsContentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("音乐存储方式") {
                Picker("音乐存储方式", selection: .constant(model.mode)) {
                    Text("复制到资料库").tag(MusicLibraryMode.managed)
                    Text("保留原位置").tag(MusicLibraryMode.referenced)
                }
                .pickerStyle(.segmented)
            }
            SettingsSection("资料库") {
                VStack(spacing: 0) {
                    ForEach(Array(model.libraries.enumerated()), id: \.element.id) { index, row in
                        compactRow(name: row.name, path: row.path, status: row.isActive ? "当前" : nil, scanning: false)
                        if index < model.libraries.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
            }
            if model.mode == .referenced {
                SettingsSection("音乐来源") {
                    VStack(spacing: 0) {
                        ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, row in
                            compactRow(
                                name: row.name,
                                path: row.path,
                                status: row.status,
                                scanning: row.scanState == .scanning
                            )
                            if index < model.sources.count - 1 { Divider().padding(.leading, 12) }
                        }
                    }
                }
                SettingsSection("删除歌曲时") {
                    Picker("删除歌曲时", selection: .constant(model.deletePolicy)) {
                        Text("仅从资料库移除").tag(ReferencedTrackDeletePolicy.onlyLibrary)
                        Text("将原文件移到废纸篓").tag(ReferencedTrackDeletePolicy.recycleSource)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
    }

    private func compactRow(name: String, path: String, status: String?, scanning: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if let status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if scanning { ProgressView().controlSize(.small) }
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static var longPathFixture: MusicSettingsContentModel {
        MusicSettingsContentModel(
            mode: .referenced,
            libraries: [
                .init(
                    id: UUID(),
                    name: "跨设备长期保存的中文音乐资料库名称",
                    path: "/Volumes/External Music Archive/Users/example/Music/A very long English path/kmgccc_player Library",
                    isActive: true
                )
            ],
            sources: [
                .init(
                    id: UUID(),
                    name: "现场录音与母带归档",
                    path: "/Volumes/Studio Archive/Projects/2026/Very Long Session Name/Original Audio Files",
                    status: "可用",
                    scanState: .scanning
                )
            ],
            deletePolicy: .onlyLibrary
        )
    }
}

#Preview("音乐设置 · 500pt · 浅色") {
    MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
        .frame(width: 500)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("音乐设置 · 500pt · 深色") {
    MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
        .frame(width: 500)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("音乐设置 · 减少动态") {
    MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
        .frame(width: 500)
        .padding()
        .transaction { $0.animation = nil }
}
