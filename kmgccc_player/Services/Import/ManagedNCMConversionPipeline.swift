//
//  ManagedNCMConversionPipeline.swift
//  kmgccc_player
//
//  §16 extraction: managed-mode NCM conversion moved verbatim out of
//  FileImportService. Owns the LibraryOperationCoordinator `.ncmConversion`
//  wrap and its checkpoints exactly as before.
//

import Foundation

internal struct NCMConversionTaskOutput: Sendable {
    let sourceURL: URL
    let displayName: String
    let result: NCMConversionResult?
    let errorDescription: String?
}

/// Same semantics as FileImportService's helper: a dialog-level cancel request
/// is promoted into the token so every worker observes it.
private func isImportCancellationRequested(
    _ progressController: BatchImportProgressDialogController,
    _ cancellationToken: ImportCancellationToken
) async -> Bool {
    if progressController.isCancellationRequested {
        await cancellationToken.requestCancel()
        return true
    }
    return await cancellationToken.isCancelled || Task.isCancelled
}

@MainActor
final class ManagedNCMConversionPipeline {
    private let operationCoordinator: LibraryOperationCoordinator

    init(operationCoordinator: LibraryOperationCoordinator) {
        self.operationCoordinator = operationCoordinator
    }

    /// Convert NCM files and return conversion results with metadata.
    func convertNCMFiles(
        _ ncmFiles: [URL],
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> [NCMConversionTaskOutput] {
        do {
            return try await operationCoordinator.run(as: .ncmConversion) {
                await self.performNCMFiles(
                    ncmFiles,
                    progressController: progressController,
                    session: session,
                    cancellationToken: cancellationToken
                )
            }
        } catch {
            // Session shutdown deliberately cancels the coordinator. The
            // caller already owns the import cancellation path; do not leave a
            // detached converter running or turn a normal library switch into
            // a persistent import failure.
            Log.debug("NCM conversion skipped by library lifecycle: \(error)", category: .import)
            return []
        }
    }

    private func performNCMFiles(
        _ ncmFiles: [URL],
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> [NCMConversionTaskOutput] {
        guard !ncmFiles.isEmpty else { return [] }

        progressController.update(
            stage: .convertingNCM,
            progress: FileImportService.progress(for: .convertingNCM, completed: 0, total: ncmFiles.count),
            detail: "准备转换 \(ncmFiles.count) 个 NCM 文件",
            completedCount: 0,
            totalCount: ncmFiles.count
        )

        var results: [NCMConversionTaskOutput] = []
        var iterator = ncmFiles.makeIterator()
        let maxConcurrent = PerAudioFileImportTask.ncmConcurrency(for: ncmFiles.count)
        var completedCount = 0
        var failureCount = 0
        let outputDirectoryURL = session.stagingDirectoryURL
            .appendingPathComponent("NCM", isDirectory: true)

        await withTaskGroup(of: NCMConversionTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, ncmFiles.count) {
                guard let sourceURL = iterator.next() else { break }
                progressController.updateItem(
                    id: sourceURL.path,
                    stage: .ncmConversion,
                    status: .active,
                    detail: "正在解密并转换 NCM 文件"
                )
                group.addTask {
                    await Self.runNCMConversionTask(
                        sourceURL: sourceURL,
                        outputDirectoryURL: outputDirectoryURL,
                        cancellationToken: cancellationToken
                    )
                }
            }

            while let output = await group.next() {
                completedCount += 1
                results.append(output)
                operationCoordinator.recordCheckpoint("NCM 转换 \(completedCount)/\(ncmFiles.count)")
                let cancelled = await isImportCancellationRequested(progressController, cancellationToken)
                if output.result != nil {
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        title: output.result?.metadata.title,
                        artist: output.result?.metadata.artistName,
                        stage: .ncmConversion,
                        status: cancelled ? .cancelled : .success,
                        detail: cancelled ? "用户已取消" : "NCM 转换完成，等待导入"
                    )
                } else {
                    failureCount += 1
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        stage: .ncmConversion,
                        status: cancelled ? .cancelled : .failed,
                        detail: cancelled ? "用户已取消" : "NCM 转换失败",
                        issueMessage: output.errorDescription
                    )
                }

                let detail =
                    failureCount == 0
                    ? "已转换 \(completedCount) / \(ncmFiles.count)"
                    : "已处理 \(completedCount) / \(ncmFiles.count)，失败 \(failureCount) 个"
                progressController.update(
                    stage: .convertingNCM,
                    progress: FileImportService.progress(
                        for: .convertingNCM,
                        completed: completedCount,
                        total: ncmFiles.count
                    ),
                    detail: detail,
                    completedCount: completedCount,
                    totalCount: ncmFiles.count
                )

                if cancelled {
                    group.cancelAll()
                    continue
                }

                if let sourceURL = iterator.next() {
                    progressController.updateItem(
                        id: sourceURL.path,
                        stage: .ncmConversion,
                        status: .active,
                        detail: "正在解密并转换 NCM 文件"
                    )
                    group.addTask {
                        await Self.runNCMConversionTask(
                            sourceURL: sourceURL,
                            outputDirectoryURL: outputDirectoryURL,
                            cancellationToken: cancellationToken
                        )
                    }
                }
            }
        }

        return results
    }

    nonisolated private static func runNCMConversionTask(
        sourceURL: URL,
        outputDirectoryURL: URL,
        cancellationToken: ImportCancellationToken
    ) async -> NCMConversionTaskOutput {
        do {
            try await cancellationToken.checkCancellation()
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
            let converter = NCMConverter()
            let result = try await converter.convert(
                from: sourceURL,
                outputDir: outputDirectoryURL,
                fetchCover: true,
                progressHandler: nil
            )
            try await cancellationToken.checkCancellation()
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: result,
                errorDescription: nil
            )
        } catch is CancellationError {
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: nil,
                errorDescription: "已取消"
            )
        } catch {
            Log.warning("NCM conversion failed for \(sourceURL.lastPathComponent): \(error)", category: .import)
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: nil,
                errorDescription: error.localizedDescription
            )
        }
    }
}
