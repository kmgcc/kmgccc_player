//
//  CoverDownloadService.swift
//  myPlayer2
//
//  kmgccc_player - Cover Download Service
//

import AppKit
import Observation
import Foundation

@Observable
@MainActor
final class CoverDownloadService: CoverDownloadServiceProtocol {
    private let executablePath: String
    private let fileManager: FileManager

    init(
        executablePath: String = "/Users/kmg/.cargo/bin/sacad",
        fileManager: FileManager = .default
    ) {
        self.executablePath = executablePath
        self.fileManager = fileManager
    }

    func downloadCover(artist: String, album: String, size: Int) async throws -> Data {
        try Task.checkCancellation()

        let executablePath = executablePath
        let fileManager = fileManager

        return try await Task.detached(priority: .userInitiated) {
            if Task.isCancelled {
                throw CoverDownloadError.cancelled
            }

            guard fileManager.isExecutableFile(atPath: executablePath) else {
                throw CoverDownloadError.executableMissing(path: executablePath)
            }

            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("temp_\(UUID().uuidString).jpg")

            defer {
                try? fileManager.removeItem(at: tempURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [artist, album, String(size), tempURL.path]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw CoverDownloadError.processFailed(
                    exitCode: -1,
                    message: error.localizedDescription
                )
            }

            process.waitUntilExit()

            if Task.isCancelled {
                process.terminate()
                throw CoverDownloadError.cancelled
            }

            guard process.terminationStatus == 0 else {
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CoverDownloadError.processFailed(
                    exitCode: process.terminationStatus,
                    message: stderrText?.isEmpty == false ? stderrText! : "sacad exited with an error"
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
        }.value
    }
}
