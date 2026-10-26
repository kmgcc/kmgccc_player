import Foundation

nonisolated enum MusicEnrichmentHelperError: Error {
    case unavailable, failed(String), invalidResponse
    /// Network trouble a later attempt may get past.
    case network(String)

    /// Whether the background pass should try again later rather than give up.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case MusicEnrichmentHelperError.network, MusicEnrichmentHelperError.unavailable: true
        case is URLError: true
        default: false
        }
    }
}

/// Each independent source gets a short-lived invocation of the existing
/// bundled runtime. A cache lookup never queues behind a network request.
nonisolated struct MusicEnrichmentHelperClient: Sendable {
    struct MaterializedMotion: Decodable, Sendable {
        var path: String
        var startTime: Double
        var duration: Double
    }

    private struct Request: Encodable {
        var provider: String
        var query: MusicEnrichmentQuery?
        var url: String?
        var destination: String?
        /// Lets each short-lived invocation reuse the public catalog token.
        var cacheDirectory: String? = Self.cacheDirectory

        nonisolated static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "kmgccc_player", isDirectory: true)
            .appendingPathComponent("MusicEnrichment", isDirectory: true).path
    }

    private struct Response: Decodable {
        var ok: Bool
        var result: MusicEnrichmentResult?
        var asset: MaterializedMotion?
        var candidates: [MusicEnrichmentResult]?
        var error: String?
        var retryable: Bool?
    }

    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult? {
        let response = try await run(Request(provider: provider, query: query))
        return response.result
    }

    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MaterializedMotion {
        let response = try await run(Request(provider: "motion", url: descriptor.url, destination: destination.path))
        guard let asset = response.asset else { throw MusicEnrichmentHelperError.invalidResponse }
        return asset
    }

    func searchMotion(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult] {
        try await run(Request(provider: "motionSearch", query: query)).candidates ?? []
    }

    private func run(_ request: Request) async throws -> Response {
        guard let resources = Bundle.main.resourceURL else { throw MusicEnrichmentHelperError.unavailable }
        let executable = resources.appendingPathComponent("Tools/qqmusic-helper/qqmusic-helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MusicEnrichmentHelperError.unavailable
        }
        let data = try JSONEncoder().encode(request)
        let invocation = MusicEnrichmentInvocation(executable: executable, input: data)
        let output = try await withTaskCancellationHandler {
            try await invocation.execute()
        } onCancel: {
            invocation.cancel()
        }
        let response = try JSONDecoder().decode(Response.self, from: output)
        guard response.ok else {
            let name = response.error ?? "provider failed"
            throw response.retryable == true ? MusicEnrichmentHelperError.network(name) : MusicEnrichmentHelperError.failed(name)
        }
        return response
    }
}

/// Process owns no App state; the lock covers cancellation racing with launch.
private nonisolated final class MusicEnrichmentInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let input: Data
    private var process: Process?
    private var cancelled = false

    init(executable: URL, input: Data) {
        self.executable = executable
        self.input = input
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }

    func execute() async throws -> Data {
        try await Task.detached(priority: .utility) { [self] in
            try executeBlocking()
        }.value
    }

    private func executeBlocking() throws -> Data {
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            process.executableURL = executable
            process.arguments = ["--music-enrichment"]
            process.standardInput = stdin
            process.standardOutput = stdout
            // Provider errors are returned as sanitized protocol data. Never
            // forward a Python traceback containing a credential-bearing URL.
            process.standardError = FileHandle.nullDevice
            lock.lock()
            guard !cancelled else { lock.unlock(); throw CancellationError() }
            self.process = process
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            lock.lock()
            let wasCancelled = cancelled
            self.process = nil
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw MusicEnrichmentHelperError.invalidResponse }
            return output
    }
}
