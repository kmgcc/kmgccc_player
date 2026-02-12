//
//  LDDCServerManager.swift
//  myPlayer2
//
//  TrueMusic - LDDC Server Process Manager
//  Manages the lifecycle of the local LDDC HTTP server.
//

import Combine
import Foundation

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
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

    // MARK: - Private State

    private var serverProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var idleTimer: Timer?
    private var lastRequestTime = Date()
    private var recentStdout: String = ""
    private var recentStderr: String = ""
    private let recentLogLimit = 8_000
    private var didLogHealthCheckFailure = false

    private init() {}

    // MARK: - Public API

    /// Ensure server is running, starting it if necessary.
    func ensureRunning() async throws {
        if isRunning {
            resetIdleTimer()
            return
        }

        try await startServer()
    }

    /// Stop the server process.
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil

        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("[LDDCServerManager] Server terminated")
        }

        serverProcess = nil
        isRunning = false
    }

    /// Get the base URL for API requests.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(currentPort)")!
    }

    /// Record a request (resets idle timer).
    func recordRequest() {
        lastRequestTime = Date()
        resetIdleTimer()
    }

    // MARK: - Private Methods

    private func startServer() async throws {
        // Find available port
        let port = try await findAvailablePort()
        currentPort = port

        let candidates = buildLaunchCandidates(port: port)
        guard !candidates.isEmpty else {
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
                print("[LDDCServerManager] Launch failed for \(candidate.name): \(error)")
                stop()
            }
        }

        let error =
            (lastLaunchError as? LDDCError)
            ?? LDDCError.startupFailed(
                NSLocalizedString("error.lddc.all_candidates_failed", comment: ""))
        lastError = error
        throw error
    }

    private func buildLaunchCandidates(port: Int) -> [LaunchCandidate] {
        var candidates: [LaunchCandidate] = []

        candidates.append(contentsOf: findBundledBinaryCandidates(port: port))

        if let pythonCandidate = findPythonCandidate(port: port) {
            candidates.append(pythonCandidate)
        }

        return candidates
    }

    private func findBundledBinaryCandidates(port: Int) -> [LaunchCandidate] {
        print("[LDDCServerManager] Searching for lddc-server binary...")
        print("[LDDCServerManager] Bundle path: \(Bundle.main.bundlePath)")
        print("[LDDCServerManager] Resource path: \(Bundle.main.resourcePath ?? "nil")")

        var urls: [URL] = []

        // Path 0: Resources root (folder reference named "lddc-server")
        if let url = Bundle.main.url(forResource: "lddc-server", withExtension: nil) {
            urls.append(url)
        }

        // Path 1: Tools subdirectory
        if let url = Bundle.main.url(
            forResource: "lddc-server", withExtension: nil, subdirectory: "Tools")
        {
            urls.append(url)
        }

        // Path 2: myPlayer2/Resources/Tools (Xcode might preserve structure)
        if let url = Bundle.main.url(
            forResource: "lddc-server", withExtension: nil,
            subdirectory: "myPlayer2/Resources/Tools")
        {
            urls.append(url)
        }

        // Path 3: Resources/Tools
        if let url = Bundle.main.url(
            forResource: "lddc-server", withExtension: nil, subdirectory: "Resources/Tools")
        {
            urls.append(url)
        }

        // Path 4: resourcePath direct
        if let resourcePath = Bundle.main.resourcePath {
            let candidates = [
                "\(resourcePath)/Tools/lddc-server",
                "\(resourcePath)/lddc-server",
                "\(resourcePath)/myPlayer2/Resources/Tools/lddc-server",
            ]
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate) {
                    urls.append(URL(fileURLWithPath: candidate))
                }
            }
        }

        // Path 5: Development paths
        let devRoot =
            Bundle.main.bundlePath
            .replacingOccurrences(of: "/Build/Products/Debug/myPlayer2.app", with: "")
            .replacingOccurrences(of: "/myPlayer2.app", with: "")

        let devCandidates = [
            "\(devRoot)/myPlayer2/Resources/Tools/lddc-server",
            "\(devRoot)/LDDC_Fetch_Core/dist/lddc-server",
        ]
        for candidate in devCandidates {
            if FileManager.default.fileExists(atPath: candidate) {
                urls.append(URL(fileURLWithPath: candidate))
            }
        }

        var launchCandidates: [LaunchCandidate] = []

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }

            if isDir.boolValue {
                let execURL = url.appendingPathComponent("lddc-server")
                if FileManager.default.fileExists(atPath: execURL.path) {
                    ensureExecutable(execURL)
                    var environment = ProcessInfo.processInfo.environment
                    environment["PYTHONUNBUFFERED"] = "1"
                    launchCandidates.append(
                        LaunchCandidate(
                            name: "lddc-server (onedir) \(execURL.path)",
                            executableURL: execURL,
                            arguments: ["--host", "127.0.0.1", "--port", String(port)],
                            environment: environment,
                            currentDirectoryURL: FileManager.default.temporaryDirectory
                        )
                    )
                }
                continue
            }

            ensureExecutable(url)
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            launchCandidates.append(
                LaunchCandidate(
                    name: "lddc-server \(url.path)",
                    executableURL: url,
                    arguments: ["--host", "127.0.0.1", "--port", String(port)],
                    environment: environment,
                    currentDirectoryURL: FileManager.default.temporaryDirectory
                )
            )
        }

        if launchCandidates.isEmpty, let resourcePath = Bundle.main.resourcePath {
            print("[LDDCServerManager] ✗ Binary not found. Listing Resources directory:")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
                for item in contents.prefix(20) {
                    print("[LDDCServerManager]   - \(item)")
                }
            }
        }

        return launchCandidates
    }

    private func findPythonCandidate(port: Int) -> LaunchCandidate? {
        guard let coreRoot = locateLDDCCoreRoot() else {
            print("[LDDCServerManager] Python fallback: could not locate LDDC_Fetch_Core on disk")
            return nil
        }

        guard let pythonURL = findPythonExecutable(coreRoot: coreRoot) else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        let pythonPathRoot = coreRoot.appendingPathComponent("src", isDirectory: true)
        let existing = environment["PYTHONPATH"] ?? ""
        environment["PYTHONPATH"] =
            existing.isEmpty ? pythonPathRoot.path : "\(pythonPathRoot.path):\(existing)"
        environment["PYTHONUNBUFFERED"] = "1"
        let pythonPathValue = environment["PYTHONPATH"] ?? ""
        print("[LDDCServerManager] Python fallback: coreRoot=\(coreRoot.path)")
        print("[LDDCServerManager] Python fallback: python=\(pythonURL.path)")
        print("[LDDCServerManager] Python fallback: PYTHONPATH=\(pythonPathValue)")

        return LaunchCandidate(
            name: "python -m lddc_fetch_core.server",
            executableURL: pythonURL,
            arguments: [
                "-m", "lddc_fetch_core.server", "--host", "127.0.0.1", "--port", String(port),
            ],
            environment: environment,
            currentDirectoryURL: coreRoot
        )
    }

    private func findPythonExecutable(coreRoot: URL) -> URL? {
        let venvPaths = [
            coreRoot.appendingPathComponent(".venv/bin/python").path,
            coreRoot.appendingPathComponent(".venv/bin/python3").path,
        ]
        let pythonPaths = [
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]

        for path in (venvPaths + pythonPaths)
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func locateLDDCCoreRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            home.appendingPathComponent("Documents/vscode/player/myPlayer2", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home,
        ]

        let relativeCandidates = [
            "LDDC_Fetch_Core",
            "LDDC-main/LDDC_Fetch_Core",
        ]

        for base in candidates {
            for rel in relativeCandidates {
                let root = base.appendingPathComponent(rel, isDirectory: true)
                let marker =
                    root
                    .appendingPathComponent("src", isDirectory: true)
                    .appendingPathComponent("lddc_fetch_core", isDirectory: true)
                if FileManager.default.fileExists(atPath: marker.path) {
                    return root
                }
            }
        }

        // Walk up a few levels from current directory (common when running from a subfolder).
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            for rel in relativeCandidates {
                let root = cur.appendingPathComponent(rel, isDirectory: true)
                let marker =
                    root
                    .appendingPathComponent("src", isDirectory: true)
                    .appendingPathComponent("lddc_fetch_core", isDirectory: true)
                if FileManager.default.fileExists(atPath: marker.path) {
                    return root
                }
            }
            cur.deleteLastPathComponent()
        }

        return nil
    }

    private func ensureExecutable(_ url: URL) {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else {
            return
        }
        print("[LDDCServerManager] ⚠️ File exists but not executable, trying chmod: \(url.path)")
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
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    weakSelf.value?.appendRecentLog(str, isStdout: true)
                }
                print("[LDDC stdout] \(str)", terminator: "")
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    weakSelf.value?.appendRecentLog(str, isStdout: false)
                }
                print("[LDDC stderr] \(str)", terminator: "")
            }
        }

        process.terminationHandler = { proc in
            Task { @MainActor in
                print(
                    "[LDDCServerManager] Server exited reason=\(proc.terminationReason) code=\(proc.terminationStatus)"
                )
                if weakSelf.value?.serverProcess === proc {
                    weakSelf.value?.serverProcess = nil
                    weakSelf.value?.isRunning = false
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
            print("[LDDCServerManager] Started server (\(candidate.name)) on port \(currentPort)")
        } catch {
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

    private func findAvailablePort() async throws -> Int {
        // Try preferred port first
        if isPortAvailable(preferredPort) {
            print("[LDDCServerManager] Port \(preferredPort) is available")
            return preferredPort
        }
        print(
            "[LDDCServerManager] Preferred port \(preferredPort) not available, scanning range...")

        // Scan port range
        for port in portRange {
            if isPortAvailable(port) {
                print("[LDDCServerManager] Found available port: \(port)")
                return port
            }
        }

        print("[LDDCServerManager] No available port found in range \(portRange)")
        throw LDDCError.portUnavailable
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        // Create socket
        let sockFd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sockFd >= 0 else {
            print("[LDDCServerManager] Failed to create socket for check: \(getPortErrorString())")
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
            // print("[LDDCServerManager] Port \(port) unavailable: \(getPortErrorString())")
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
                dumpRecentLogs()
                stop()
                throw LDDCError.healthCheckFailed
            }
            if await checkHealth() {
                didLogHealthCheckFailure = false
                return
            }
            try await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
        }

        // Cleanup on failure
        dumpRecentLogs()
        stop()
        throw LDDCError.healthCheckFailed
    }

    private func dumpRecentLogs() {
        if !recentStderr.isEmpty {
            print("[LDDCServerManager] Recent stderr (tail):")
            print(recentStderr)
        }
        if !recentStdout.isEmpty {
            print("[LDDCServerManager] Recent stdout (tail):")
            print(recentStdout)
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
        let idleTime = Date().timeIntervalSince(lastRequestTime)
        if idleTime >= idleTimeout {
            print("[LDDCServerManager] Idle timeout reached, stopping server")
            stop()
        }
    }
}
