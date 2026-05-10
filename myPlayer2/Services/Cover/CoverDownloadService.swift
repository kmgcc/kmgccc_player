//
//  CoverDownloadService.swift
//  myPlayer2
//
//  kmgccc_player - Cover Download Service
//

import AppKit
import Observation
import Foundation

private actor CoverDownloadContinuationState {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@Observable
@MainActor
final class CoverDownloadService: CoverDownloadServiceProtocol {
    private let executablePath: String?
    private let fileManager: FileManager

    init(
        executablePath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.executablePath = executablePath
        self.fileManager = fileManager
    }

    func downloadCover(artist: String, album: String, size: Int) async throws -> Data {
        try Task.checkCancellation()

        let executablePath = executablePath

        let resolvedExecutablePath = try Self.resolvedExecutablePath(
            explicitPath: executablePath,
            fileManager: fileManager
        )

        return try await Task.detached(priority: .userInitiated) { @Sendable in
            try await Self.runSacad(
                artist: artist,
                album: album,
                size: size,
                executablePath: resolvedExecutablePath
            )
        }.value
    }

    nonisolated static func downloadCoverData(
        artist: String,
        album: String,
        size: Int
    ) async throws -> Data {
        let executablePath = try resolvedExecutablePath()
        return try await runSacad(
            artist: artist,
            album: album,
            size: size,
            executablePath: executablePath
        )
    }

    nonisolated static func resolvedExecutablePath(
        explicitPath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        if let explicitPath {
            guard fileManager.isExecutableFile(atPath: explicitPath) else {
                throw CoverDownloadError.executableMissing(path: explicitPath)
            }
            return explicitPath
        }

        guard let executableURL = Bundle.main.resourceURL?
            .appendingPathComponent("Tools/sacad/sacad") else {
            throw CoverDownloadError.executableMissing(path: "Tools/sacad/sacad")
        }

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CoverDownloadError.executableMissing(path: executableURL.path)
        }

        return executableURL.path
    }

    nonisolated private static func runSacad(
        artist: String,
        album: String,
        size: Int,
        executablePath: String
    ) async throws -> Data {
        let fileManager = FileManager.default

        if Task.isCancelled {
            throw CoverDownloadError.cancelled
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("temp_\(UUID().uuidString).jpg")

        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [artist, album, String(size), tempURL.path]

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let state = CoverDownloadContinuationState(continuation)
                    process.terminationHandler = { process in
                        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        guard process.terminationStatus == 0 else {
                            let stderrText = String(data: stderrData, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await state.resume(
                                    .failure(
                                        CoverDownloadError.processFailed(
                                            exitCode: process.terminationStatus,
                                            message: stderrText?.isEmpty == false
                                                ? stderrText!
                                                : "sacad exited with an error"
                                        )
                                    )
                                )
                            }
                            return
                        }
                        Task {
                            await state.resume(.success(()))
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        Task {
                            await state.resume(
                                .failure(
                                    CoverDownloadError.processFailed(
                                        exitCode: -1,
                                        message: error.localizedDescription
                                    )
                                )
                            )
                        }
                    }
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch let error as CoverDownloadError {
            throw error
        } catch is CancellationError {
            if process.isRunning {
                process.terminate()
            }
            throw CoverDownloadError.cancelled
        } catch {
            throw CoverDownloadError.processFailed(
                exitCode: -1,
                message: error.localizedDescription
            )
        }

        guard process.terminationStatus == 0 else {
            throw CoverDownloadError.processFailed(
                exitCode: process.terminationStatus,
                message: "sacad exited with an error"
            )
        }

        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw CoverDownloadError.outputMissing
        }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: tempURL)
        } catch {
            throw CoverDownloadError.outputMissing
        }

        guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
            throw CoverDownloadError.invalidImageData
        }

        return imageData
    }
}
