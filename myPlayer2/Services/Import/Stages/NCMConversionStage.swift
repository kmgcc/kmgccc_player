//
//  NCMConversionStage.swift
//  myPlayer2
//

import Foundation

@MainActor
enum NCMConversionStage {
    static func convert(
        _ ncmFiles: [URL],
        progressController: BatchImportProgressDialogController
    ) async -> [NCMConversionTaskOutput] {
        guard !ncmFiles.isEmpty else { return [] }

        progressController.update(
            stage: .convertingNCM,
            progress: BatchImportStage.progress(for: .convertingNCM, completed: 0, total: ncmFiles.count),
            detail: "准备转换 \(ncmFiles.count) 个 NCM 文件",
            completedCount: 0,
            totalCount: ncmFiles.count
        )

        var results: [NCMConversionTaskOutput] = []
        var iterator = ncmFiles.makeIterator()
        let maxConcurrent = ImportConcurrencyPolicy.ncmConversion(for: ncmFiles.count)
        var completedCount = 0
        var failureCount = 0

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
                    await runNCMConversionTask(sourceURL: sourceURL)
                }
            }

            while let output = await group.next() {
                completedCount += 1
                results.append(output)
                if output.result != nil {
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        title: output.result?.metadata.title,
                        artist: output.result?.metadata.artistName,
                        stage: .ncmConversion,
                        status: .success,
                        detail: "NCM 转换完成，等待导入"
                    )
                } else {
                    failureCount += 1
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        stage: .ncmConversion,
                        status: .failed,
                        detail: "NCM 转换失败",
                        issueMessage: output.errorDescription
                    )
                }

                let detail =
                    failureCount == 0
                    ? "已转换 \(completedCount) / \(ncmFiles.count)"
                    : "已处理 \(completedCount) / \(ncmFiles.count)，失败 \(failureCount) 个"
                progressController.update(
                    stage: .convertingNCM,
                    progress: BatchImportStage.progress(
                        for: .convertingNCM,
                        completed: completedCount,
                        total: ncmFiles.count
                    ),
                    detail: detail,
                    completedCount: completedCount,
                    totalCount: ncmFiles.count
                )

                if let sourceURL = iterator.next() {
                    progressController.updateItem(
                        id: sourceURL.path,
                        stage: .ncmConversion,
                        status: .active,
                        detail: "正在解密并转换 NCM 文件"
                    )
                    group.addTask {
                        await runNCMConversionTask(sourceURL: sourceURL)
                    }
                }
            }
        }

        return results
    }
    nonisolated private static func runNCMConversionTask(sourceURL: URL) async -> NCMConversionTaskOutput {
        do {
            let converter = NCMConverter()
            let result = try await converter.convert(
                from: sourceURL,
                fetchCover: true,
                progressHandler: nil
            )
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: result,
                errorDescription: nil
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
