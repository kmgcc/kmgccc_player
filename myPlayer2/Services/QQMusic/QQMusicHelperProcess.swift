//
//  QQMusicHelperProcess.swift
//  myPlayer2
//
//  On-demand stdio JSON IPC process manager for the bundled QQMusic helper.
//

import Foundation

nonisolated struct QQMusicArtworkCandidate: Codable, Equatable, Sendable {
    var source: String
    var title: String?
    var artist: String?
    var album: String?
    var artistName: String?
    var singerMid: String?
    var songMid: String?
    var albumMid: String?
    var imageURL: String?
    var duration: Int?
    var confidence: Double?
}

nonisolated enum QQMusicHelperError: LocalizedError, Sendable {
    case helperUnavailable(String)
    case circuitOpen(until: Date)
    case requestWriteFailed(String)
    case requestTimedOut(seconds: TimeInterval)
    case requestFailed(String)
    case invalidResponse(String)
    case processTerminated(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let message):
            return "QQMusic helper unavailable: \(message)"
        case .circuitOpen(let until):
            return "QQMusic helper circuit open until \(until)"
        case .requestWriteFailed(let message):
            return "QQMusic helper request write failed: \(message)"
        case .requestTimedOut(let seconds):
            return "QQMusic helper request timed out after \(Int(seconds)) seconds"
        case .requestFailed(let message):
            return "QQMusic helper request failed: \(message)"
        case .invalidResponse(let message):
            return "QQMusic helper returned invalid response: \(message)"
        case .processTerminated(let code):
            return "QQMusic helper terminated with exit code \(code)"
        case .cancelled:
            return "QQMusic helper request cancelled"
        }
    }
}

actor QQMusicHelperProcess {
    static let shared = QQMusicHelperProcess()

    private struct LaunchCandidate {
        let executableURL: URL
        let currentDirectoryURL: URL
        let environment: [String: String]
    }

    private struct PendingRequest {
        let method: String
        let startedAt: Date
        let continuation: CheckedContinuation<QQMusicHelperResponse, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct QQMusicHelperRequest<Params: Encodable>: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    private struct QQMusicHelperResponse: Decodable, Sendable {
        let id: String?
        let ok: Bool
        let candidates: [QQMusicArtworkCandidate]?
        let error: String?
    }

    private struct ArtistArtworkParams: Encodable, Sendable {
        let name: String
        let limit: Int
    }

    private struct TrackArtworkParams: Encodable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Int?
        let limit: Int
    }

    private struct AlbumArtworkParams: Encodable, Sendable {
        let album: String
        let artist: String
        let limit: Int
    }

    private let requestTimeout: TimeInterval = 15
    private let idleTimeout: TimeInterval = 60
    private let failureWindow: TimeInterval = 120
    private let circuitOpenDuration: TimeInterval = 300
    private let failureThreshold = 3
    private let recentLogLimit = 8_000

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var recentStderr = ""
    private var pendingRequests: [String: PendingRequest] = [:]
    private var idleShutdownTask: Task<Void, Never>?
    private var recentFailureDates: [Date] = []
    private var circuitOpenUntil: Date?
    private var circuitLastReason = ""
    private var lastActivity = Date()
    private var lastLaunchDiagnostics = ""

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func searchArtistArtwork(name: String, limit: Int = 5) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_artist_artwork",
            params: ArtistArtworkParams(name: name, limit: limit)
        )
    }

    func searchTrackArtwork(
        title: String,
        artist: String,
        album: String,
        duration: Int?,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_track_artwork",
            params: TrackArtworkParams(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                limit: limit
            )
        )
    }

    func searchAlbumArtwork(
        album: String,
        artist: String,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_album_artwork",
            params: AlbumArtworkParams(album: album, artist: artist, limit: limit)
        )
    }

    func terminate() {
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> [QQMusicArtworkCandidate] {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        let query = querySummary(params)
        Log.info("[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(query)", category: .import)

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)", category: .import)
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.requestFailed(message)
        }

        let candidates = response.candidates ?? []
        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let topConfidence = candidates.compactMap(\.confidence).max() ?? 0
        Log.info("[QQMusicHelperProcess] response id=\(id) method=\(method) candidates=\(candidates.count) topConfidence=\(String(format: "%.2f", topConfidence)) durationMs=\(durationMs)", category: .import)
        return candidates
    }

    private func enqueueRequest<Params: Encodable & Sendable>(
        id: String,
        method: String,
        params: Params,
        continuation: CheckedContinuation<QQMusicHelperResponse, Error>
    ) {
        guard let stdinHandle else {
            continuation.resume(
                throwing: QQMusicHelperError.helperUnavailable("stdin pipe is not available")
            )
            return
        }

        let timeout = requestTimeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.failPendingRequest(
                id: id,
                error: QQMusicHelperError.requestTimedOut(seconds: timeout)
            )
        }

        pendingRequests[id] = PendingRequest(
            method: method,
            startedAt: Date(),
            continuation: continuation,
            timeoutTask: timeoutTask
        )

        do {
            let payload = QQMusicHelperRequest(id: id, method: method, params: params)
            var data = try encoder.encode(payload)
            data.append(0x0A)
            try stdinHandle.write(contentsOf: data)
            markActivity()
        } catch {
            timeoutTask.cancel()
            pendingRequests.removeValue(forKey: id)
            recordFailure(reason: "request write failed: \(error.localizedDescription)")
            continuation.resume(
                throwing: QQMusicHelperError.requestWriteFailed(error.localizedDescription)
            )
        }
    }

    private func ensureRunning() async throws {
        if let process, process.isRunning, stdinHandle != nil {
            markActivity()
            return
        }

        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(-1))

        guard let candidate = findLaunchCandidate() else {
            recordFailure(reason: "helper unavailable")
            throw QQMusicHelperError.helperUnavailable(
                lastLaunchDiagnostics.isEmpty
                    ? "binary missing"
                    : lastLaunchDiagnostics
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = candidate.executableURL
        process.arguments = []
        process.currentDirectoryURL = candidate.currentDirectoryURL
        process.environment = candidate.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task {
                await self?.handleStdout(text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task {
                await self?.appendStderr(text)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(terminatedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            let reason = "launch failed: \(error.localizedDescription)"
            recordFailure(reason: reason)
            Log.warning("[QQMusicHelperProcess] \(reason) path=\(candidate.executableURL.path)", category: .import)
            throw QQMusicHelperError.helperUnavailable(reason)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutBuffer = ""
        recentStderr = ""
        markActivity()
        Log.info("[QQMusicHelperProcess] started path=\(candidate.executableURL.path)", category: .import)
    }

    private func handleStdout(_ text: String) {
        stdoutBuffer.append(text)
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...newlineRange.lowerBound)
            guard !line.isEmpty else { continue }
            handleResponseLine(line)
        }
    }

    private func handleResponseLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let response: QQMusicHelperResponse
        do {
            response = try decoder.decode(QQMusicHelperResponse.self, from: data)
        } catch {
            recordFailure(reason: "JSON IPC invalid response")
            Log.warning("[QQMusicHelperProcess] JSON IPC invalid response reason=\(error)", category: .import)
            return
        }

        guard let id = response.id,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            Log.warning("[QQMusicHelperProcess] JSON IPC unknown response id=\(response.id ?? "nil")", category: .import)
            return
        }

        pending.timeoutTask.cancel()
        markActivity()
        pending.continuation.resume(returning: response)
    }

    private func handleTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let status = terminatedProcess.terminationStatus
        let stderr = recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr.isEmpty ? "process terminated code=\(status)" : "process terminated code=\(status) stderr=\(stderr)"
        Log.warning("[QQMusicHelperProcess] \(reason)", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(status))
        recordFailure(reason: reason)
    }

    private func failPendingRequest(id: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
        recordFailure(reason: String(describing: error))
    }

    private func failAllPendingRequests(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func stopProcess(failingPendingWith error: Error) {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        failAllPendingRequests(with: error)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = ""
    }

    private func markActivity() {
        lastActivity = Date()
        scheduleIdleShutdown()
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 60) * 1_000_000_000))
            } catch {
                return
            }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard pendingRequests.isEmpty else {
            scheduleIdleShutdown()
            return
        }
        guard Date().timeIntervalSince(lastActivity) >= idleTimeout else {
            scheduleIdleShutdown()
            return
        }
        Log.info("[QQMusicHelperProcess] idle timeout; stopping helper", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func appendStderr(_ text: String) {
        recentStderr.append(text)
        if recentStderr.count > recentLogLimit {
            recentStderr = String(recentStderr.suffix(recentLogLimit))
        }
    }

    private func recordFailure(reason: String) {
        let now = Date()
        recentFailureDates = recentFailureDates.filter {
            now.timeIntervalSince($0) <= failureWindow
        }
        recentFailureDates.append(now)
        circuitLastReason = reason
        if recentFailureDates.count >= failureThreshold {
            circuitOpenUntil = now.addingTimeInterval(circuitOpenDuration)
            Log.warning("[QQMusicHelperProcess] circuit open until=\(circuitOpenUntil!) reason=\(reason)", category: .import)
            stopProcess(failingPendingWith: QQMusicHelperError.requestFailed("circuit opened"))
        }
    }

    private func recordSuccess() {
        recentFailureDates.removeAll()
        circuitOpenUntil = nil
        circuitLastReason = ""
    }

    private func checkCircuitBreaker() throws {
        guard let until = circuitOpenUntil else { return }
        if Date() < until {
            Log.warning("[QQMusicHelperProcess] circuit open until=\(until) reason=\(circuitLastReason)", category: .import)
            throw QQMusicHelperError.circuitOpen(until: until)
        }
        circuitOpenUntil = nil
        recentFailureDates.removeAll()
        circuitLastReason = ""
    }

    private func findLaunchCandidate() -> LaunchCandidate? {
        let binaryURL = bundledBinaryURL()
        Log.info("[QQMusicHelperProcess] binary path=\(binaryURL.path)", category: .import)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: binaryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            lastLaunchDiagnostics = "binary missing: \(binaryURL.path)"
            Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
            return nil
        }

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            lastLaunchDiagnostics = "binary not executable: \(binaryURL.path)"
            Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
            return nil
        }

        lastLaunchDiagnostics = ""
        return LaunchCandidate(
            executableURL: binaryURL,
            currentDirectoryURL: binaryURL.deletingLastPathComponent(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func bundledBinaryURL() -> URL {
        let resources = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: Bundle.main.resourcePath ?? "", isDirectory: true)
        return resources
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: false)
    }

    private func querySummary<Params: Encodable>(_ params: Params) -> String {
        guard let data = try? encoder.encode(params),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "{}"
        }
        let pairs = object
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let text = pairs.joined(separator: ",")
        return text.count > 240 ? String(text.prefix(240)) : text
    }
}
