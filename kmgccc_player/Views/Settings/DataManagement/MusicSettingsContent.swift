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
                HStack(spacing: 10) {
                    Text(model.mode.dialogDisplayTitle)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(model.mode == .managed ? "音乐复制到资料库" : "音乐留在原位置，资料库保存索引")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            SettingsSection("资料库") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.libraries.isEmpty {
                        previewEmptyState("还没有资料库", systemImage: "externaldrive")
                    } else {
                        ForEach(model.libraries) { row in
                            MusicLibrarySettingsRow(
                                name: row.name,
                                path: row.path,
                                mode: model.mode,
                                isActive: row.isActive,
                                onOpen: {},
                                onReveal: {},
                                onRemove: {}
                            )
                        }
                    }
                }
            }
            if model.mode == .referenced {
                SettingsSection("音乐来源") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.sources.isEmpty {
                            previewEmptyState("尚未添加来源", systemImage: "folder")
                        }
                        ForEach(model.sources) { row in
                            MusicSourceSettingsRow(
                                name: row.name,
                                path: row.path,
                                mode: .directory,
                                status: row.status == "可用" ? .available : .offline,
                                isScanning: row.scanState == .scanning,
                                scanFailed: row.scanState == .failed,
                                onRescan: {},
                                onReconnect: {},
                                onRemove: {}
                            )
                        }
                    }
                }
                SettingsSection("偏好设置") {
                    HStack(spacing: 12) {
                        Text("删除歌曲")
                            .font(.callout)
                        Spacer(minLength: 8)
                        AppDialogCapsuleSlider(
                            segments: ReferencedTrackDeletePolicy.allCases,
                            selection: .constant(model.deletePolicy),
                            label: { $0.dialogDisplayTitle }
                        )
                    }
                }
            }
        }
    }

    private func previewEmptyState(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .environmentObject(ThemeStore.shared)
        .preferredColorScheme(.light)
}

#Preview("音乐设置 · 500pt · 深色") {
    MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
        .frame(width: 500)
        .padding()
        .environmentObject(ThemeStore.shared)
        .preferredColorScheme(.dark)
}

#Preview("音乐设置 · 减少动态") {
    MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
        .frame(width: 500)
        .padding()
        .environmentObject(ThemeStore.shared)
        .transaction { $0.animation = nil }
}
