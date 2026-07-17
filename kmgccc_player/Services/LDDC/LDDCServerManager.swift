//
//  LDDCServerManager.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Server Process Manager
//  Manages the lifecycle of the local LDDC HTTP server.
//

import Combine
import Foundation

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    nonisolated(unsafe) weak var value: T?
    init(_ value: T?) {
        self.value = value
    }
}

/// Manages the LDDC server process lifecycle.
/// - Starts the bundled lddc-server binary
/// - Handles port selection and health checks
/// - Auto-shutdown after idle timeout
@MainActor
final class LDDCServerManager: ObservableObject {

    static let shared = LDDCServerManager()

    private struct LaunchCandidate {
        let name: String
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]?
        let currentDirectoryURL: URL?
    }

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var currentPort: Int = 8765
    @Published private(set) var lastError: LDDCError?

    // MARK: - Configuration

    private let preferredPort = 8765
    private let portRange = 9000...9999
    // PyInstaller onedir cold start (especially under Xcode) can be noticeably slower.
    private let healthCheckTimeout: TimeInterval = 60
    private let healthCheckInterval: TimeInterval = 0.5
    private let idleTimeout: TimeInterval = 60  // 1 minute
    private let captureStdout = ProcessInfo.processInfo.environment["LDDC_CAPTURE_STDOUT"] == "1"
    private let mirrorServerLogsToConsole =
        ProcessInfo.processInfo.environment["LDDC_VERBOSE_SERVER_LOGS"] == "1"

    // MARK: - Private State

    private var serverProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var startTask: Task<Void, Error>?
    private var idleTimer: Timer?
    private var lastRequestTime = Date()
    private var inFlightRequestCount = 0
    private var recentStdout: String = ""
    private var recentStderr: String = ""
    private let recentLogLimit = 8_000
    private var didLogHealthCheckFailure = false

    private init() {}

    // MARK: - Public API

    /// Ensure server is running, starting it if necessary.
    /// Concurrent callers share a single start task — only one process is ever launched.
    func ensureRunning() async throws {
        if isRunning {
            if inFlightRequestCount == 0 {
                resetIdleTimer()
            }
            return
        }

        if let existing = startTask {
            Log.info("start joined existing task", category: .lddc)
            try await existing.value
            return
        }

        let requestId = String(UUID().uuidString.prefix(8))
        Log.info("[\(requestId)] start requested", category: .lddc)

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.startServer()
        }
        startTask = task

        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }

    /// Stop the server process.
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        startTask = nil
        inFlightRequestCount = 0

        if let process = serverProcess, process.isRunning {
            process.terminate()
            Log.debug("Server terminate requested", category: .lddc)
        }
        teardownLogPipes()

        serverProcess = nil
        isRunning = false
    }

    /// Get the base URL for API requests.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(currentPort)")!
    }

    /// Mark the beginning of an HTTP request.
    ///
    /// The server must not be reclaimed while a provider request is still in
    /// flight. This counter also makes concurrent per-provider searches safe.
    func beginRequest() {
        inFlightRequestCount += 1
        lastRequestTime = Date()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Mark the end of an HTTP request and restart idle reclamation if needed.
    func endRequest() {
        inFlightRequestCount = max(0, inFlightRequestCount - 1)
        lastRequestTime = Date()
        if inFlightRequestCount == 0, isRunning {
            resetIdleTimer()
        }
    }

    // MARK: - Private Methods

    private func startServer() async throws {
        // Find available port
        let port = try await findAvailablePort()
        currentPort = port

        let candidates = buildLaunchCandidates(port: port)
        guard !candidates.isEmpty else {
            Log.error("No launch candidates found", category: .lddc)
            let error = LDDCError.startupFailed(
                NSLocalizedString("error.lddc.no_candidates", comment: ""))
            lastError = error
            throw error
        }

        var lastLaunchError: Error?
        for candidate in candidates {
            do {
                try await launch(candidate)
                return
            } catch {
                lastLaunchError = error
                Log.error("Startup failed for candidate \(candidate.name): \(error)", category: .lddc)
                stop()
            }
        }

        let error =
            (lastLaunchError as? LDDCError)
            ?? LDDCError.startupFailed(
                NSLocalizedString("error.lddc.all_candidates_failed", comment: ""))
        Log.error("Startup failed for all launch candidates: \(error)", category: .lddc)
        lastError = error
        throw error
    }

    private func buildLaunchCandidates(port: Int) -> [LaunchCandidate] {
        guard let resourceURL = Bundle.main.resourceURL else {
            Log.error("App resource directory is unavailable", category: .lddc)
            return []
        }

        let executableURL = resourceURL
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("lddc-server", isDirectory: true)
            .appendingPathComponent("lddc-server", isDirectory: false)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            Log.error("Bundled LDDC executable is missing: \(executableURL.path)", category: .lddc)
            return []
        }

        ensureExecutable(executableURL)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        return [
            LaunchCandidate(
                name: "bundled lddc-server",
                executableURL: executableURL,
                arguments: ["--host", "127.0.0.1", "--port", String(port)],
                environment: environment,
                currentDirectoryURL: FileManager.default.temporaryDirectory
            )
        ]
    }

    private func ensureExecutable(_ url: URL) {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else {
            return
        }
        Log.warning("Binary exists but is not executable, attempting chmod: \(url.path)", category: .lddc)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func launch(_ candidate: LaunchCandidate) async throws {
        let process = Process()
        process.executableURL = candidate.executableURL
        process.arguments = candidate.arguments
        process.environment = candidate.environment
        process.currentDirectoryURL = candidate.currentDirectoryURL

        recentStdout = ""
        recentStderr = ""

        let weakSelf = WeakBox(self)
        let stderr = Pipe()
        if captureStdout {
            let stdout = Pipe()
            process.standardOutput = stdout
            stdoutPipe = stdout
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    try? handle.close()
                    return
                }
                guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }

                Task { @MainActor in
                    weakSelf.value?.appendRecentLog(str, isStdout: true)
                }
                if weakSelf.value?.mirrorServerLogsToConsole == true {
                    Log.debug("[LDDC stdout] \(str)", category: .lddc)
                }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            stdoutPipe = nil
        }
        process.standardError = stderr
        stderrPipe = stderr

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    weakSelf.value?.appendRecentLog(str, isStdout: false)
                }
                if weakSelf.value?.mirrorServerLogsToConsole == true {
                    Log.debug("[LDDC stderr] \(str)", category: .lddc)
                }
            }
        }

        process.terminationHandler = { proc in
            Task { @MainActor in
                weakSelf.value?.handleProcessTermination(proc)
            }
        }

        do {
            try process.run()
            serverProcess = process
            Log.info("Server started (\(candidate.name)) on port \(currentPort)", category: .lddc)
        } catch {
            teardownLogPipes()
            let startError = LDDCError.startupFailed(error.localizedDescription)
            lastError = startError
            throw startError
        }

        try await waitForHealthy()

        isRunning = true
        lastError = nil
        resetIdleTimer()
    }

    private func appendRecentLog(_ text: String, isStdout: Bool) {
        if isStdout {
            recentStdout.append(text)
            if recentStdout.count > recentLogLimit {
                recentStdout = String(recentStdout.suffix(recentLogLimit))
            }
        } else {
            recentStderr.append(text)
            if recentStderr.count > recentLogLimit {
                recentStderr = String(recentStderr.suffix(recentLogLimit))
            }
        }
    }

    private func handleProcessTermination(_ process: Process) {
        // A termination callback can arrive after stop() has already started
        // a replacement process. Never let the old process tear down the new
        // process's pipes or request bookkeeping.
        guard serverProcess === process else {
            Log.debug("Ignoring termination callback for stale server process", category: .lddc)
            return
        }

        Log.warning(
            "Server terminated reason=\(process.terminationReason) code=\(process.terminationStatus)",
            category: .lddc
        )
        teardownLogPipes()
        inFlightRequestCount = 0
        lastRequestTime = Date()
        if serverProcess === process {
            serverProcess = nil
            isRunning = false
        }
    }

    private func teardownLogPipes() {
        if let stdoutPipe {
            let handle = stdoutPipe.fileHandleForReading
            handle.readabilityHandler = nil
            try? handle.close()
        }
        if let stderrPipe {
            let handle = stderrPipe.fileHandleForReading
            handle.readabilityHandler = nil
            try? handle.close()
        }
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func findAvailablePort() async throws -> Int {
        // Try preferred port first
        if isPortAvailable(preferredPort) {
            Log.debug("Port \(preferredPort) is available", category: .lddc)
            return preferredPort
        }
        Log.debug(
            "Preferred port \(preferredPort) not available; scanning range",
            category: .lddc)

        // Scan port range
        for port in portRange {
            if isPortAvailable(port) {
                Log.debug("Found available port: \(port)", category: .lddc)
                return port
            }
        }

        Log.error("No available port found in range \(portRange)", category: .lddc)
        throw LDDCError.portUnavailable
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        // Create socket
        let sockFd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sockFd >= 0 else {
            Log.debug("Failed to create socket for port check: \(getPortErrorString())", category: .lddc)
            return false
        }
        defer { Darwin.close(sockFd) }

        // Allow port reuse
        var reuse: Int32 = 1
        setsockopt(sockFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sockFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            // Uncomment for verbose debugging if needed, but reducing noise for standard failures
            return false
        }

        return true
    }

    private func getPortErrorString() -> String {
        return String(cString: strerror(errno))
    }

    private func waitForHealthy() async throws {
        let deadline = Date().addingTimeInterval(healthCheckTimeout)
        didLogHealthCheckFailure = false

        while Date() < deadline {
            if let process = serverProcess, !process.isRunning {
                Log.error("Health check failed because server process exited", category: .lddc)
                dumpRecentLogs()
                stop()
                throw LDDCError.healthCheckFailed
            }
            if await checkHealth() {
                Log.info("health check ok port=\(currentPort)", category: .lddc)
                didLogHealthCheckFailure = false
                return
            }
            try await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
        }

        // Cleanup on failure
        Log.error("Health check failed due to timeout", category: .lddc)
        dumpRecentLogs()
        stop()
        throw LDDCError.healthCheckFailed
    }

    private func dumpRecentLogs() {
        if !recentStderr.isEmpty {
            Log.debug("Recent stderr (tail):", category: .lddc)
            Log.debug(recentStderr, category: .lddc)
        }
        if !recentStdout.isEmpty {
            Log.debug("Recent stdout (tail):", category: .lddc)
            Log.debug(recentStdout, category: .lddc)
        }
    }

    private func checkHealth() async -> Bool {
        // Avoid noisy URLSession "Task finished with error -1004" logs during cold start
        // by doing a tiny raw-socket HTTP check instead.
        let port = currentPort
        return await Task.detached(priority: .utility) {
            Self.checkHealthRaw(port: port)
        }.value
    }

    nonisolated private static func checkHealthRaw(port: Int) -> Bool {
        let sockFd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sockFd >= 0 else {
            return false
        }
        defer { Darwin.close(sockFd) }

        // Short read/write timeouts so we never block the UI thread for long.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        withUnsafePointer(to: &tv) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rebound in
                _ = setsockopt(
                    sockFd, SOL_SOCKET, SO_RCVTIMEO, rebound,
                    socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(
                    sockFd, SOL_SOCKET, SO_SNDTIMEO, rebound,
                    socklen_t(MemoryLayout<timeval>.size))
            }
        }

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sockFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return false
        }

        let req = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        let reqBytes = Array(req.utf8)
        let sent = reqBytes.withUnsafeBytes { ptr -> Int in
            Darwin.send(sockFd, ptr.baseAddress, ptr.count, 0)
        }
        guard sent > 0 else {
            return false
        }

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            Darwin.recv(sockFd, ptr.baseAddress, ptr.count, 0)
        }
        guard n > 0 else {
            return false
        }

        let s = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        guard s.hasPrefix("HTTP/1.1 200") || s.hasPrefix("HTTP/1.0 200") else {
            return false
        }
        // Status 200 on /health is sufficient.
        return true
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            timeInterval: idleTimeout,
            target: self,
            selector: #selector(handleIdleTimer),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func handleIdleTimer() {
        handleIdleTimeout()
    }

    private func handleIdleTimeout() {
        guard inFlightRequestCount == 0 else {
            resetIdleTimer()
            return
        }

        let idleTime = Date().timeIntervalSince(lastRequestTime)
        if idleTime >= idleTimeout {
            Log.info("Idle timeout reached; stopping server", category: .lddc)
            stop()
        }
    }
}
