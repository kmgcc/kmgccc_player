import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
enum AutomationInteraction {

    static func expandPath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    /// The picker is owned by the App. A raw path is accepted without another
    /// panel only when an existing Source root or the user-selected trusted
    /// audio root already covers it.
    static func requestSourceURL(
        mode: ReferencedSourceMode,
        requestedPath: String?
    ) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = mode == .directory
        panel.canChooseFiles = mode == .file
        panel.allowsMultipleSelection = false
        panel.title = mode == .directory ? "选择音乐文件夹" : "选择音乐文件"
        panel.prompt = "添加来源"
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedURL.hasDirectoryPath
                ? requestedURL
                : requestedURL.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    /// Artwork input is always authorized by an App-owned open panel. A
    /// caller-provided path is only used to choose the panel's initial folder;
    /// it is never treated as sandbox authorization by itself.
    static func requestArtworkURL(requestedPath: String?) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "选择封面"
        panel.prompt = "使用封面"
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            let requestedIsDirectory = (try? requestedURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedIsDirectory
                ? requestedURL
                : requestedURL.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    static func requestExportDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "导出歌曲"
        panel.prompt = "选择文件夹"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Library lifecycle operations use the same App-owned picker boundary as
    /// Source creation. A requested path is only a navigation hint; the
    /// selected URL is still authorized by the App and retained until the
    /// lifecycle transaction has captured its own bookmark.
    static func requestLibraryDirectory(
        requestedPath: String?,
        title: String,
        prompt: String,
        allowsCreatingDirectories: Bool
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowsCreatingDirectories
        panel.title = title
        panel.prompt = prompt
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            let requestedIsDirectory = (try? requestedURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedIsDirectory
                ? requestedURL
                : requestedURL.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    static func confirmDestructiveOperation(title: String, message: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
