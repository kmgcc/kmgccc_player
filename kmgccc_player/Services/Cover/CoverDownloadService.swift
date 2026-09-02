//
//  CoverDownloadService.swift
//  myPlayer2
//
//  kmgccc_player - Cover Download Service
//

import AppKit
import Observation
import Foundation

nonisolated private struct CoverDownloadProcessResult: Sendable {
    var exitStatus: Int32?
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

nonisolated private final class CoverDownloadOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytesPerStream = 1 * 1024 * 1024
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, toStdout: Bool) {
        lock.lock()
        if toStdout {
            append(data, to: &stdout)
        } else {
            append(data, to: &stderr)
        }
        lock.unlock()
    }

    private func append(_ data: Data, to buffer: inout Data) {
        let available = maximumBytesPerStream - buffer.count
        guard available > 0 else { return }
        buffer.append(data.prefix(available))
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

nonisolated private final class CoverDownloadProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CoverDownloadProcessResult?
    private var continuation: CheckedContinuation<CoverDownloadProcessResult, Never>?

    func wait() async -> CoverDownloadProcessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: CoverDownloadProcessResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
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
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CoverDownloadError.cancelled
        }

        let executablePath = executablePath

        let resolvedExecutablePath = try Self.resolvedExecutablePath(
            explicitPath: executablePath,
            fileManager: fileManager
        )

        return try await Self.runSacad(
            artist: artist,
            album: album,
            size: size,
            executablePath: resolvedExecutablePath
        )
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await runBoundedProcess(
            process,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            timeout: 30
        )

        if Task.isCancelled {
            throw CoverDownloadError.cancelled
        }
        guard let result else {
            throw CoverDownloadError.processFailed(
                exitCode: -1,
                message: "failed to launch sacad"
            )
        }
        if result.timedOut {
            throw CoverDownloadError.processFailed(
                exitCode: -1,
                message: "sacad timed out after 30 seconds"
            )
        }
        guard result.exitStatus == 0 else {
            let stderrText = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoverDownloadError.processFailed(
                exitCode: result.exitStatus ?? -1,
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
    }

    nonisolated private static func runBoundedProcess(
        _ process: Process,
        stdout: FileHandle,
        stderr: FileHandle,
        timeout: TimeInterval
    ) async -> CoverDownloadProcessResult? {
        let collector = CoverDownloadOutputCollector()
        let state = CoverDownloadProcessState()
        let stdoutReadLock = NSLock()
        let stderrReadLock = NSLock()
        stdout.readabilityHandler = { handle in
            stdoutReadLock.lock()
            let data = handle.availableData
            stdoutReadLock.unlock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data, toStdout: true)
            }
        }
        stderr.readabilityHandler = { handle in
            stderrReadLock.lock()
            let data = handle.availableData
            stderrReadLock.unlock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data, toStdout: false)
            }
        }
        process.terminationHandler = { process in
            // A descendant can retain the pipe after sacad exits. Rely on the
            // ongoing drain instead of synchronously waiting for EOF here.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                stdout.readabilityHandler = nil
                stderr.readabilityHandler = nil
                let output = collector.snapshot()
                state.finish(
                    CoverDownloadProcessResult(
                        exitStatus: process.terminationStatus,
                        stdout: output.stdout,
                        stderr: output.stderr,
                        timedOut: false
                    )
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            return nil
        }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard process.isRunning else { return }
            terminate(process)
            let output = collector.snapshot()
            state.finish(
                CoverDownloadProcessResult(
                    exitStatus: nil,
                    stdout: output.stdout,
                    stderr: output.stderr,
                    timedOut: true
                )
            )
        }
        let result = await withTaskCancellationHandler {
            await state.wait()
        } onCancel: {
            timeoutTask.cancel()
            terminate(process)
            let output = collector.snapshot()
            state.finish(
                CoverDownloadProcessResult(
                    exitStatus: nil,
                    stdout: output.stdout,
                    stderr: output.stderr,
                    timedOut: true
                )
            )
        }
        timeoutTask.cancel()
        return result
    }

    nonisolated private static func terminate(_ process: Process, grace: TimeInterval = 1) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
