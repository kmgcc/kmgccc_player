//
//  LibraryLocationSettingsSection.swift
//  myPlayer2
//
//  kmgccc_player - Library Location Settings Section
//

import SwiftUI
import AppKit

/// Settings section for configuring the music library root path.
struct LibraryLocationSettingsSection: View {
    @Environment(LibraryViewModel.self) private var libraryVM

    @State private var showChangeConfirmAlert = false
    @State private var showRestoreConfirmAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var pendingURL: URL?

    private var currentPath: String {
        LibraryLocationStore.activeLibraryRootURL.path
    }

    private var isDefaultPath: Bool {
        LibraryLocationStore.activeLibraryRootURL == LibraryLocationStore.defaultLibraryRootURL
    }

    var body: some View {
        SettingsSection("音乐资料库位置") {
            VStack(alignment: .leading, spacing: 12) {
                Text(currentPath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentPath)

                HStack(spacing: 12) {
                    Button("更改位置") {
                        chooseNewLocation()
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Button("在访达中显示") {
                        showInFinder()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    Button(libraryVM.loadingPhase.isLoading ? "正在扫描" : "重新扫描资料库") {
                        Task {
                            await libraryVM.reloadLibrary()
                        }
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(libraryVM.loadingPhase.isLoading)

                    Button("恢复默认位置") {
                        showRestoreConfirmAlert = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(isDefaultPath)
                }
            }
        }
        .alert("更改资料库位置？", isPresented: $showChangeConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .none) {
                if let url = pendingURL {
                    LibraryLocationStore.setLibraryRootURL(url)
                }
            }
        } message: {
            Text("将把音乐资料库存放在所选文件夹下的 “kmgccc_player Library” 子文件夹中。APP 会重新加载该位置中的歌曲、播放列表、专辑和艺人信息。")
        }
        .alert("恢复默认位置？", isPresented: $showRestoreConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .none) {
                LibraryLocationStore.resetToDefault()
            }
        } message: {
            Text("确认将音乐资料库恢复到默认位置吗？应用将重新加载资料库。")
        }
        .alert("操作失败", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Actions

    // MARK: - Parent → Active Root

    private static let libraryFolderName = "kmgccc_player Library"

    /// Convert a user-selected parent directory into the actual library root.
    /// If the user already selected a folder named exactly `libraryFolderName`, use it as-is.
    private func resolvedLibraryRoot(from selectedURL: URL) -> URL {
        let lastComponent = selectedURL.lastPathComponent
        if lastComponent == Self.libraryFolderName {
            return selectedURL
        }
        return selectedURL.appendingPathComponent(Self.libraryFolderName, isDirectory: true)
    }

    private func chooseNewLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择音乐资料库的存放位置"
        panel.prompt = "选择"

        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            self.pendingURL = self.resolvedLibraryRoot(from: url)
            self.showChangeConfirmAlert = true
        }
    }

    private func showInFinder() {
        let url = LibraryLocationStore.activeLibraryRootURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                errorMessage = "无法创建资料库目录：\(error.localizedDescription)"
                showErrorAlert = true
                return
            }
        }

        NSWorkspace.shared.open(url)
    }
}
