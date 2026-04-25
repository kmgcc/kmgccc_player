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
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("音乐资料库位置")
                    .font(.headline)

                Text(currentPath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentPath)

                HStack(spacing: 12) {
                    Button("更改位置…") {
                        chooseNewLocation()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    Button("在访达中显示") {
                        showInFinder()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    Button("恢复默认位置") {
                        showRestoreConfirmAlert = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(isDefaultPath)
                }
            }
            .padding(12)
        }
        .alert("更改资料库位置？", isPresented: $showChangeConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .none) {
                if let url = pendingURL {
                    LibraryLocationStore.setLibraryRootURL(url)
                }
            }
        } message: {
            Text("确认将音乐资料库位置更改为 \(pendingURL?.path ?? "") 吗？应用将重新加载资料库。")
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

    private func chooseNewLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择新的音乐资料库文件夹"
        panel.prompt = "选择"

        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            self.pendingURL = url
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
