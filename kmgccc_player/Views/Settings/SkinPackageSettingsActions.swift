import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only panel and selection state lives here; installation is owned by SkinPackageStore.
struct SkinPackageSettingsActions: View {
    let skin: any NowPlayingSkin
    @Environment(SkinManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @State private var showsRemoval = false
    @State private var isWorking = false
    @State private var pendingArchive: URL?
    @State private var showsConflict = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            Button("导入", action: chooseArchive)
            Button("导出", action: chooseExport)
                .disabled((skin as? PackagedSkin)?.isExportable != true)
            Button("重载", action: reload)
            Button("删除", role: .destructive) { showsRemoval = true }
                .disabled((skin as? PackagedSkin)?.isExportable != true)
            if isWorking { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
        .disabled(isWorking)
        .confirmationDialog("已有此皮肤", isPresented: $showsConflict, titleVisibility: .visible) {
            Button("替换") { importPending(.replace) }
            Button("另存副本") { importPending(.copy) }
            Button("取消", role: .cancel) { pendingArchive = nil }
        }
        .confirmationDialog("删除此皮肤？", isPresented: $showsRemoval, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: remove)
            Button("取消", role: .cancel) {}
        } message: { Text("正在使用的皮肤将切回内置皮肤") }
        .alert("皮肤包", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() {
        do { try manager.catalog.reload(skin.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func remove() {
        do { try manager.removePackage(skin.id, settings: settings) }
        catch { errorMessage = error.localizedDescription }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pendingArchive = url
            isWorking = true
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false }
                do {
                    let manifest = try await manager.catalog.packages.inspect(url)
                    if let existing = manager.catalog.registeredSkin(for: manifest.descriptor.id) as? PackagedSkin,
                       case .installed = existing.origin {
                        showsConflict = true
                    } else {
                        _ = try await manager.catalog.packages.importPackage(url, disposition: .copy)
                        pendingArchive = nil
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func importPending(_ disposition: SkinPackageImportDisposition) {
        guard let url = pendingArchive else { return }
        isWorking = true
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false; pendingArchive = nil }
            do { _ = try await manager.catalog.packages.importPackage(url, disposition: disposition) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(skin.name).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isWorking = true
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; isWorking = false }
                do { try await manager.catalog.packages.exportPackage(skin, to: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
}
