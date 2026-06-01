//
//  UpdatePackageDownloadManager.swift
//  myPlayer2
//
//  Downloads update packages inside the app and reports compact sidebar progress.
//

import AppKit
import Combine
import Foundation

@MainActor
final class UpdatePackageDownloadManager: ObservableObject {
    static let shared = UpdatePackageDownloadManager()

    @Published private(set) var sidebarProgress: SidebarTaskProgress?

    private var downloadTask: URLSessionDownloadTask?
    private var progressTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var downloadIsActive = false

    private init() {}

    var isDownloading: Bool {
        downloadIsActive
    }

    func startDownload(versionInfo: RemoteVersionInfo) {
        guard !isDownloading else { return }
        guard let url = resolvedDownloadURL(for: versionInfo) else {
            showFailure("下载链接无效，请使用 GitHub Release 备用下载。")
            return
        }

        let version = versionInfo.latestVersion
        let initialName = "kmgccc_player_\(version)"
        downloadIsActive = true
        clearTask?.cancel()
        sidebarProgress = SidebarTaskProgress(
            title: "正在下载更新",
            detail: initialName,
            fractionCompleted: nil,
            state: .running
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await self.downloadPackage(from: url, versionInfo: versionInfo)
                await MainActor.run {
                    self.finishDownload(at: destination)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.clearDownloadState()
                }
            } catch {
                await MainActor.run {
                    self.showFailure(self.userMessage(for: error))
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        clearDownloadState()
    }

    private func resolvedDownloadURL(for versionInfo: RemoteVersionInfo) -> URL? {
        resolveURL(versionInfo.downloadURL)
            ?? resolveURL(versionInfo.releaseURL)
    }

    private func resolveURL(_ rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil else {
            return nil
        }
        return url
    }

    private func downloadPackage(from url: URL, versionInfo: RemoteVersionInfo) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    guard let temporaryURL else {
                        throw UpdatePackageDownloadError.invalidResponse
                    }
                    let destination = try Self.moveDownloadedPackage(
                        temporaryURL: temporaryURL,
                        response: response,
                        versionInfo: versionInfo
                    )
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            Task { @MainActor [weak self, weak task] in
                self?.downloadTask = task
                self?.startProgressPolling(task: task, versionInfo: versionInfo)
            }
            task.resume()
        }
    }

    private func startProgressPolling(task: URLSessionDownloadTask?, versionInfo: RemoteVersionInfo) {
        progressTask?.cancel()
        progressTask = Task { [weak self, weak task] in
            while !Task.isCancelled {
                guard let task else { return }
                let progress = task.progress
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                let fraction = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil
                await MainActor.run {
                    self?.sidebarProgress = SidebarTaskProgress(
                        title: "正在下载更新",
                        detail: self?.downloadDetail(
                            versionInfo: versionInfo,
                            completedBytes: completed,
                            totalBytes: total
                        ) ?? versionInfo.latestVersion,
                        fractionCompleted: fraction,
                        state: .running
                    )
                }
                if progress.isFinished { return }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }

    private func downloadDetail(versionInfo: RemoteVersionInfo, completedBytes: Int64, totalBytes: Int64) -> String {
        if totalBytes > 0 {
            return "\(versionInfo.latestVersion) · \(Self.formatBytes(completedBytes)) / \(Self.formatBytes(totalBytes))"
        }
        return versionInfo.latestVersion
    }

    private func finishDownload(at url: URL) {
        downloadIsActive = false
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        sidebarProgress = SidebarTaskProgress(
            title: "更新已下载",
            detail: url.lastPathComponent,
            fractionCompleted: 1,
            state: .completed
        )
        NSWorkspace.shared.activateFileViewerSelecting([url])
        scheduleClear(after: 4)
    }

    private func showFailure(_ message: String) {
        downloadIsActive = false
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        sidebarProgress = SidebarTaskProgress(
            title: "更新下载失败",
            detail: message,
            fractionCompleted: nil,
            state: .failed
        )
        scheduleClear(after: 6)

        let alert = NSAlert()
        alert.messageText = "更新下载失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func scheduleClear(after seconds: UInt64) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            await MainActor.run {
                self?.sidebarProgress = nil
                self?.clearTask = nil
            }
        }
    }

    private func clearDownloadState() {
        downloadIsActive = false
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        sidebarProgress = nil
    }

    private func userMessage(for error: Error) -> String {
        if let downloadError = error as? UpdatePackageDownloadError {
            return downloadError.localizedDescription
        }
        return error.localizedDescription
    }

    private nonisolated static func moveDownloadedPackage(
        temporaryURL: URL,
        response: URLResponse?,
        versionInfo: RemoteVersionInfo
    ) throws -> URL {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdatePackageDownloadError.invalidResponse
        }

        try validateInstallerResponse(httpResponse)

        let fileName = resolvedFileName(response: httpResponse, versionInfo: versionInfo)
        let destination = try uniqueDownloadsURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private nonisolated static func validateInstallerResponse(_ response: HTTPURLResponse) throws {
        let finalURL = response.url
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let fileName = contentDispositionFileName(from: response)
            ?? finalURL?.lastPathComponent
            ?? ""
        let suffix = URL(fileURLWithPath: fileName).pathExtension.lowercased()

        if suffix == "dmg" || suffix == "zip" {
            return
        }
        if contentType.contains("application/x-apple-diskimage")
            || contentType.contains("application/zip")
            || contentType.contains("application/octet-stream") {
            return
        }
        if contentType.contains("text/html") {
            throw UpdatePackageDownloadError.githubReleasePage
        }
        throw UpdatePackageDownloadError.notInstaller
    }

    private nonisolated static func resolvedFileName(
        response: HTTPURLResponse,
        versionInfo: RemoteVersionInfo
    ) -> String {
        if let headerName = contentDispositionFileName(from: response),
           isAllowedPackageFileName(headerName) {
            return sanitizedFileName(headerName)
        }

        if let urlName = response.url?.lastPathComponent,
           isAllowedPackageFileName(urlName) {
            return sanitizedFileName(urlName)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let suffix = contentType.contains("application/zip") ? "zip" : "dmg"
        return sanitizedFileName("kmgccc_player_\(versionInfo.latestVersion).\(suffix)")
    }

    private nonisolated static func contentDispositionFileName(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Disposition") else { return nil }

        if let encodedRange = header.range(of: #"filename\*=UTF-8''([^;]+)"#, options: .regularExpression) {
            let value = String(header[encodedRange])
                .replacingOccurrences(of: "filename*=UTF-8''", with: "")
            return value.removingPercentEncoding
        }

        if let range = header.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
            let value = String(header[range])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value
        }
        return nil
    }

    private nonisolated static func isAllowedPackageFileName(_ fileName: String) -> Bool {
        let suffix = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return suffix == "dmg" || suffix == "zip"
    }

    private nonisolated static func sanitizedFileName(_ fileName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = fileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? "kmgccc_player_update.dmg" : sanitized
    }

    private nonisolated static func uniqueDownloadsURL(fileName: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let baseURL = downloads.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = downloads.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw UpdatePackageDownloadError.cannotCreateDestination
    }

    private nonisolated static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum UpdatePackageDownloadError: LocalizedError {
    case invalidResponse
    case githubReleasePage
    case notInstaller
    case cannotCreateDestination

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器没有返回可下载的安装包。"
        case .githubReleasePage:
            return "当前后端下载跳转到了 GitHub Release 页面，请使用 GitHub Release 备用下载。"
        case .notInstaller:
            return "下载结果不是 .dmg 或 .zip 安装包，请使用 GitHub Release 备用下载。"
        case .cannotCreateDestination:
            return "无法在 Downloads 文件夹创建保存文件。"
        }
    }
}
