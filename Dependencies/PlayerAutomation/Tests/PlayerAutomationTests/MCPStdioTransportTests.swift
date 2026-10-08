import Darwin
import Foundation
import Testing
@testable import PlayerAutomationIPC
import PlayerAutomationProtocol
@testable import AutomationTool

private struct RequestFingerprint: Equatable {
    let method: String
    let params: AutomationJSONValue?
    let libraryID: UUID?
    let caller: String?

    init(_ request: AutomationRequest) {
        method = request.method
        params = request.params
        libraryID = request.context.libraryID
        caller = request.context.caller
    }
}

private final class FakeAutomationService: @unchecked Sendable {
    private struct CachedResult {
        let fingerprint: RequestFingerprint
        let response: AutomationResponse
    }

    private let lock = NSLock()
    private var receivedRequests: [AutomationRequest] = []
    private var executedMutationCount = 0
    private var idempotencyCache: [String: CachedResult] = [:]

    func handle(_ request: AutomationRequest) -> AutomationResponse {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests.append(request)

        guard let key = request.context.idempotencyKey else {
            executedMutationCount += request.method == "metadata.patch" ? 1 : 0
            return AutomationResponse.success(
                for: request,
                result: .object(["accepted": .boolean(true)])
            )
        }

        let cacheKey = "\(request.method):\(key)"
        let fingerprint = RequestFingerprint(request)
        if let cached = idempotencyCache[cacheKey] {
            guard cached.fingerprint == fingerprint else {
                return AutomationResponse.failure(
                    for: request,
                    error: AutomationError(
                        code: .conflict,
                        message: "The idempotency key was already used with different parameters."
                    )
                )
            }
            return AutomationResponse(
                requestID: request.requestID,
                result: cached.response.result,
                error: cached.response.error,
                serverTime: cached.response.serverTime,
                protocolVersion: cached.response.protocolVersion
            )
        }

        executedMutationCount += request.method == "metadata.patch" ? 1 : 0
        let response = AutomationResponse.success(
            for: request,
            result: .object(["accepted": .boolean(true)])
        )
        idempotencyCache[cacheKey] = CachedResult(
            fingerprint: fingerprint,
            response: response
        )
        return response
    }

    var metadataPatchRequests: [AutomationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.filter { $0.method == "metadata.patch" }
    }

    var receivedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.count
    }

    func requests(method: String) -> [AutomationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.filter { $0.method == method }
    }

    var executedMetadataPatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return executedMutationCount
    }
}

private final class MCPRequestCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: Bool?

    func record(wasCancelled: Bool) {
        lock.lock()
        cancellation = wasCancelled
        lock.unlock()
    }

    var wasCancelled: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return cancellation
    }
}

private final class MCPProcessOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [Data] = []
    private var reachedEOF = false

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            self?.append(data)
        }
    }

    var hasReachedEOF: Bool {
        condition.lock()
        defer { condition.unlock() }
        return reachedEOF
    }

    func nextLine(timeout: TimeInterval) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while lines.isEmpty && !reachedEOF {
            guard condition.wait(until: deadline) else { return nil }
        }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func stop(handle: FileHandle) {
        handle.readabilityHandler = nil
    }

    private func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            reachedEOF = true
            condition.broadcast()
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        condition.broadcast()
    }
}

private final class MCPStdioSubprocess: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errors: Pipe
    private let outputReader: MCPProcessOutput

    init(socketPath: String, timeout: TimeInterval = 2, disconnectOutput: Bool = false) throws {
        let executable = try Self.executableURL()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = [
            "mcp-stdio",
            "--socket", socketPath,
            "--no-launch",
            "--timeout", String(timeout)
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let outputReader = MCPProcessOutput(handle: output.fileHandleForReading)
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        self.outputReader = outputReader
        try process.run()
        if disconnectOutput {
            outputReader.stop(handle: output.fileHandleForReading)
            try output.fileHandleForReading.close()
        }
    }

    func call(
        id: String,
        title: String,
        idempotencyKey: String? = nil
    ) async throws -> [String: Any] {
        var params: [String: Any] = [
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
            "name": "metadata.patch",
            "arguments": ["title": title]
        ]
        if let idempotencyKey {
            params["context"] = ["idempotencyKey": idempotencyKey]
        }
        return try await call(id: id, params: params)
    }

    func callBackgroundSearch(id: String, trackID: UUID) async throws -> [String: Any] {
        let params: [String: Any] = [
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
            "name": "metadata.search",
            "arguments": ["trackID": trackID.uuidString, "background": true]
        ]
        return try await call(id: id, params: params)
    }

    private func call(id: String, params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": params
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let data = payload + Data([0x0A])
        let line = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async { [self] in
                do {
                    try input.fileHandleForWriting.write(contentsOf: data)
                    guard let line = outputReader.nextLine(timeout: 8) else {
                        throw MCPSubprocessError.responseTimedOut
                    }
                    continuation.resume(returning: line)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw MCPSubprocessError.invalidResponse
        }
        return response
    }

    func sendOneShot(_ requests: [[String: Any]], timeout: TimeInterval = 8) async throws -> (status: Int32, responses: [[String: Any]]) {
        var inputData = Data()
        for request in requests {
            inputData.append(try JSONSerialization.data(withJSONObject: request))
            inputData.append(0x0A)
        }
        let inputPayload = inputData

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, [Data]), Error>) in
            DispatchQueue.global().async { [self] in
                do {
                    try input.fileHandleForWriting.write(contentsOf: inputPayload)
                    try input.fileHandleForWriting.close()
                    let deadline = Date().addingTimeInterval(timeout)
                    var responseLines: [Data] = []
                    while !outputReader.hasReachedEOF {
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else { throw MCPSubprocessError.responseTimedOut }
                        if let line = outputReader.nextLine(timeout: min(remaining, 0.1)) {
                            responseLines.append(line)
                        }
                    }
                    while let line = outputReader.nextLine(timeout: 0.01) {
                        responseLines.append(line)
                    }
                    process.waitUntilExit()
                    outputReader.stop(handle: output.fileHandleForReading)
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: (process.terminationStatus, responseLines))
                } catch {
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    outputReader.stop(handle: output.fileHandleForReading)
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }

        let responses = try result.1.map { line -> [String: Any] in
            guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw MCPSubprocessError.invalidResponse
            }
            return response
        }
        return (result.0, responses)
    }

    func sendWithDisconnectedOutput(_ requests: [[String: Any]], timeout: TimeInterval = 3) async throws -> Int32 {
        var inputData = Data()
        for request in requests {
            inputData.append(try JSONSerialization.data(withJSONObject: request))
            inputData.append(0x0A)
        }
        let inputPayload = inputData

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global().async { [self] in
                do {
                    try input.fileHandleForWriting.write(contentsOf: inputPayload)
                    try input.fileHandleForWriting.close()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    guard !process.isRunning else {
                        process.terminate()
                        process.waitUntilExit()
                        throw MCPSubprocessError.responseTimedOut
                    }
                    process.waitUntilExit()
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func finish() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: finishBlocking())
            }
        }
    }

    private func finishBlocking() -> Int32 {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        outputReader.stop(handle: output.fileHandleForReading)
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }

    var processIsRunning: Bool { process.isRunning }

    fileprivate static func executableURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["PLAYER_AUTOMATION_TEST_BIN"] {
            let explicit = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.isExecutableFile(atPath: explicit.path) else {
                throw MCPSubprocessError.executableNotFound
            }
            return explicit
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let products = packageRoot
            .appendingPathComponent(".build/out/Products/Debug/player-automation")
        guard FileManager.default.isExecutableFile(atPath: products.path),
              Self.productWasBuiltFromCurrentSources(products, packageRoot: packageRoot) else {
            throw MCPSubprocessError.executableNotFound
        }
        return products
    }

    private static func productWasBuiltFromCurrentSources(
        _ executable: URL,
        packageRoot: URL
    ) -> Bool {
        let sourcePaths = [
            "Sources/AutomationTool/main.swift",
            "Sources/AutomationTool/MCPStdioServer.swift",
            "Sources/PlayerAutomationIPC/AutomationIPCClient.swift",
            "Sources/PlayerAutomationIPC/AutomationIPCTransport.swift"
        ]
        let dates = sourcePaths.compactMap { relativePath -> Date? in
            let source = packageRoot.appendingPathComponent(relativePath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            return attributes?[.modificationDate] as? Date
        }
        guard let newestSource = dates.max(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let executableDate = attributes[.modificationDate] as? Date else {
            return false
        }
        return executableDate >= newestSource
    }
}

private enum MCPSubprocessError: Error {
    case executableNotFound
    case responseTimedOut
    case invalidResponse
}

private struct AutomationCLIRun: Sendable {
    let status: Int32
    let output: Data
}

private func runAutomationCLI(arguments: [String]) async throws -> AutomationCLIRun {
    let executable = try MCPStdioSubprocess.executableURL()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AutomationCLIRun, Error>) in
        DispatchQueue.global().async {
            do {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: AutomationCLIRun(status: process.terminationStatus, output: data)
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func makeSocketDirectory() throws -> (directory: URL, socket: URL, secret: Data) {
    // AF_UNIX paths have a small platform-specific limit. Keep the test socket
    // directly under /tmp so the host's longer temporary directory does not
    // turn a transport test into a path-length failure.
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let socket = directory.appendingPathComponent("automation.sock", isDirectory: false)
    let secret = try AutomationIPCSecretStore.loadOrCreate(forSocketPath: socket.path)
    return (directory, socket, secret)
}

private func verifyMCPStdioOneShotPipesDrainDiscoveryAndLegacyLifecycle() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let modernDiscovery = try await MCPStdioSubprocess(socketPath: paths.socket.path).sendOneShot([
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "server/discover",
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
        ]
    ])
    #expect(modernDiscovery.status == 0)
    #expect(modernDiscovery.responses.count == 1)
    #expect(modernDiscovery.responses.first?["id"] as? Int == 1)
    #expect(modernDiscovery.responses.first?["error"] == nil)
    #expect(modernDiscovery.responses.first?["result"] != nil)

    let legacyLifecycle = try await MCPStdioSubprocess(socketPath: paths.socket.path).sendOneShot([
        [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "one-shot-test", "version": "1"]
            ]
        ],
        ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]],
        ["jsonrpc": "2.0", "id": 11, "method": "ping", "params": [:]]
    ])
    #expect(legacyLifecycle.status == 0)
    #expect(legacyLifecycle.responses.count == 2)
    #expect(legacyLifecycle.responses.first(where: { $0["id"] as? Int == 10 })?["error"] == nil)
    #expect(legacyLifecycle.responses.first(where: { $0["id"] as? Int == 11 })?["error"] == nil)
}

private func verifyMCPStdioOneShotEOFDoesNotCancelBackgroundJobRequest() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let cancellationProbe = MCPRequestCancellationProbe()
    let configuration = try AutomationIPCConfiguration(
        maximumConcurrentConnections: 8,
        ioTimeout: 120,
        sharedSecret: paths.secret
    )
    let listener = try AutomationIPCListener(
        socketPath: paths.socket.path,
        configuration: configuration
    )
    try await listener.start(cancellableHandler: { request, cancellation in
        try? await Task.sleep(for: .milliseconds(250))
        cancellationProbe.record(wasCancelled: cancellation.isCancelled)
        return service.handle(request)
    })

    let response = try await MCPStdioSubprocess(socketPath: paths.socket.path).sendOneShot([
        [
            "jsonrpc": "2.0",
            "id": "background-job",
            "method": "tools/call",
            "params": [
                "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
                "name": "metadata.search",
                "arguments": ["trackID": UUID().uuidString, "background": true]
            ]
        ]
    ])
    await listener.stop()

    #expect(response.status == 0)
    #expect(response.responses.count == 1)
    #expect(response.responses.first?["id"] as? String == "background-job")
    #expect(!isToolError(response.responses[0], code: "serverUnavailable"))
    #expect(service.requests(method: AutomationMethod.metadataSearch).count == 1)
    #expect(service.requests(method: AutomationMethod.jobsCancel).isEmpty)
    #expect(cancellationProbe.wasCancelled == false)
}

private func verifyMCPStdioHandlesDisconnectedOutput() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }

    let status = try await MCPStdioSubprocess(
        socketPath: paths.socket.path,
        disconnectOutput: true
    ).sendWithDisconnectedOutput([
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "server/discover",
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
        ]
    ])
    #expect(status == 0)
}

private func startFakeApp(
    socket: URL,
    secret: Data,
    service: FakeAutomationService,
    delay: Duration = .zero
) async throws -> AutomationIPCListener {
    let configuration = try AutomationIPCConfiguration(
        maximumConcurrentConnections: 8,
        ioTimeout: 120,
        sharedSecret: secret
    )
    let listener = try AutomationIPCListener(
        socketPath: socket.path,
        configuration: configuration
    )
    try await listener.start { request in
        if delay > .zero { try? await Task.sleep(for: delay) }
        return service.handle(request)
    }
    return listener
}

private func sendIPCOnWorker(
    _ client: AutomationIPCClient,
    _ request: AutomationRequest,
    timeout: TimeInterval,
    connectionTimeout: TimeInterval
) async throws -> AutomationResponse {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AutomationResponse, Error>) in
        DispatchQueue.global().async {
            do {
                continuation.resume(
                    returning: try client.sendClassified(
                        request,
                        timeout: timeout,
                        connectionTimeout: connectionTimeout
                    )
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func isToolError(_ response: [String: Any], code: String) -> Bool {
    guard let result = response["result"] as? [String: Any],
          let structured = result["structuredContent"] as? [String: Any],
          let error = structured["error"] as? [String: Any] else {
        return false
    }
    return error["code"] as? String == code
}

private func verifyMCPAdapterScopesDefaultIdempotencyKeysToItsStdioSession() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )

    let firstSession = try MCPStdioSubprocess(socketPath: paths.socket.path)
    _ = try await firstSession.call(id: "same-id", title: "First")
    _ = try await firstSession.call(id: "same-id", title: "First")
    _ = try await firstSession.call(id: "explicit-id", title: "Explicit", idempotencyKey: "caller-key")
    #expect(await firstSession.finish() == 0)

    let secondSession = try MCPStdioSubprocess(socketPath: paths.socket.path)
    _ = try await secondSession.call(id: "same-id", title: "Second")
    _ = try await secondSession.call(id: "other-id", title: "Explicit", idempotencyKey: "caller-key")
    #expect(await secondSession.finish() == 0)
    await listener.stop()

    let calls = service.metadataPatchRequests
    #expect(calls.count == 5)
    #expect(calls[0].context.idempotencyKey == calls[1].context.idempotencyKey)
    #expect(calls[0].context.idempotencyKey != calls[3].context.idempotencyKey)
    #expect(calls[2].context.idempotencyKey == "caller-key")
    #expect(calls[4].context.idempotencyKey == "caller-key")
    #expect(service.executedMetadataPatchCount == 3)
}

private func verifyMCPAdapterReturnsRecoverableAppUnavailableAndKeepsRunningForRestart() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )
    let adapter = try MCPStdioSubprocess(socketPath: paths.socket.path, timeout: 1)

    let first = try await adapter.call(id: "before", title: "Before stop")
    #expect(!isToolError(first, code: "serverUnavailable"))

    await listener.stop()
    let unavailable = try await adapter.call(id: "during", title: "While stopped")
    #expect(isToolError(unavailable, code: "serverUnavailable"))
    #expect(adapter.processIsRunning)

    let restarted = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )
    let recovered = try await adapter.call(id: "after", title: "After restart")
    #expect(!isToolError(recovered, code: "serverUnavailable"))

    #expect(await adapter.finish() == 0)
    await restarted.stop()
}

private func verifyMCPAdapterDoesNotRetryAnAmbiguousMutation() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service,
        delay: .milliseconds(300)
    )
    let adapter = try MCPStdioSubprocess(socketPath: paths.socket.path, timeout: 0.1)
    let result = try await adapter.call(id: "ambiguous", title: "Apply once")
    #expect(isToolError(result, code: "requestOutcomeUnknown"))
    #expect(adapter.processIsRunning)

    let handlerDeadline = Date().addingTimeInterval(2)
    while service.metadataPatchRequests.isEmpty && Date() < handlerDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(service.metadataPatchRequests.count == 1)
    #expect(await adapter.finish() == 0)
    await listener.stop()
}

private func verifyMCPAdapterScopesBackgroundJobIdempotencyKeys() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )
    let trackID = UUID()
    let firstSession = try MCPStdioSubprocess(socketPath: paths.socket.path)
    _ = try await firstSession.callBackgroundSearch(id: "same-job-id", trackID: trackID)
    _ = try await firstSession.callBackgroundSearch(id: "same-job-id", trackID: trackID)
    #expect(await firstSession.finish() == 0)

    let secondSession = try MCPStdioSubprocess(socketPath: paths.socket.path)
    _ = try await secondSession.callBackgroundSearch(id: "same-job-id", trackID: trackID)
    #expect(await secondSession.finish() == 0)
    await listener.stop()

    let requests = service.requests(method: AutomationMethod.metadataSearch)
    #expect(requests.count == 3)
    #expect(requests[0].context.idempotencyKey == requests[1].context.idempotencyKey)
    #expect(requests[0].context.idempotencyKey != requests[2].context.idempotencyKey)
}

private func verifyCLIWaitAliasAndBackgroundParameterInputs() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )
    let common = ["--socket", paths.socket.path, "--no-launch", "--json"]
    let commands: [[String]] = [
        ["jobs", "wait", "job-123", "--params-json", "{\"timeoutMs\":23000}"],
        ["diagnostics", "health", "--params-json", "{\"offset\":5,\"limit\":10}"],
        ["storage", "validate", "--params-json", "{\"background\":true}"],
        ["library", "import", "/tmp/source.mp3", "--params-json", "{\"enrichmentPolicy\":\"migration\"}"],
        ["system", "ping", "--timeout", "0.1"]
    ]
    for command in commands {
        let result = try await runAutomationCLI(arguments: command + common)
        #expect(result.status == 0)
    }
    await listener.stop()

    let requests = service.requests(method: AutomationMethod.jobsWait)
    #expect(requests.count == 1)
    #expect(requests[0].params == .object([
        "jobID": .string("job-123"),
        "timeoutMs": .number(23_000)
    ]))
    #expect(service.requests(method: AutomationMethod.diagnosticsHealth).first?.params == .object([
        "offset": .number(5),
        "limit": .number(10)
    ]))
    #expect(service.requests(method: AutomationMethod.storageValidate).first?.params == .object([
        "background": .boolean(true)
    ]))
    #expect(service.requests(method: AutomationMethod.libraryImport).first?.params == .object([
        "filePaths": .array([.string("/tmp/source.mp3")]),
        "dryRun": .boolean(false),
        "enrichmentPolicy": .string("migration")
    ]))
    #expect(service.requests(method: AutomationMethod.systemPing).count == 1)
}

private func verifyRequestTimeoutBudgetsMatchSlowOperationsAndContextDeadlines() {
    let defaultTimeout: TimeInterval = 10
    let ordinary = AutomationRequest(method: AutomationMethod.systemPing)
    let search = AutomationRequest(method: AutomationMethod.lyricsSearch)
    let libraryInteractions = [
        AutomationMethod.libraryCreate,
        AutomationMethod.libraryOpen,
        AutomationMethod.librarySwitch,
        AutomationMethod.libraryRelocate,
        AutomationMethod.libraryRemove,
        AutomationMethod.metadataImport,
        AutomationMethod.artworkApply,
        AutomationMethod.automationGrantScope,
        AutomationMethod.sourceCreate,
        AutomationMethod.operationsBatch
    ].map { AutomationRequest(method: $0) }
    let waitWithoutOverride = AutomationRequest(method: "jobs.wait")
    let waitWithOverride = AutomationRequest(
        method: "jobs.wait",
        params: .object(["timeoutMs": .number(25_000)])
    )
    let explicitWaitTimeout = AutomationRequest(
        method: "jobs.wait",
        params: .object(["timeoutMs": .number(25_000)])
    )
    let now = Date()
    let shortDeadline = AutomationRequest(
        method: AutomationMethod.lyricsSearch,
        context: AutomationRequestContext(deadline: now.addingTimeInterval(2))
    )

    #expect(AutomationToolDefaults.requestTimeout(
        for: ordinary,
        configuredTimeout: defaultTimeout,
        timeoutWasSet: false
    ) == 10)
    #expect(AutomationToolDefaults.requestTimeout(
        for: search,
        configuredTimeout: defaultTimeout,
        timeoutWasSet: false
    ) == 120)
    for request in libraryInteractions {
        #expect(AutomationToolDefaults.requestTimeout(
            for: request,
            configuredTimeout: defaultTimeout,
            timeoutWasSet: false
        ) == 120)
        #expect(AutomationToolDefaults.requestTimeout(
            for: request,
            configuredTimeout: 5,
            timeoutWasSet: true
        ) == 5)
    }
    #expect(AutomationToolDefaults.requestTimeout(
        for: waitWithoutOverride,
        configuredTimeout: defaultTimeout,
        timeoutWasSet: false
    ) == 25)
    #expect(AutomationToolDefaults.requestTimeout(
        for: waitWithOverride,
        configuredTimeout: defaultTimeout,
        timeoutWasSet: false
    ) == 30)
    #expect(AutomationToolDefaults.requestTimeout(
        for: explicitWaitTimeout,
        configuredTimeout: 5,
        timeoutWasSet: true
    ) == 5)
    #expect(AutomationToolDefaults.requestTimeout(
        for: ordinary,
        configuredTimeout: 0.001,
        timeoutWasSet: true
    ) == 0.001)
    #expect(AutomationToolDefaults.requestDeadline(
        for: shortDeadline,
        configuredTimeout: defaultTimeout,
        timeoutWasSet: false,
        now: now
    ) == shortDeadline.context.deadline)
}

private func verifyClassifiedIPCRequestAllowsLongerPerCallTimeoutAndNeverHidesAmbiguousDelivery() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service,
        delay: .milliseconds(250)
    )
    let configuration = try AutomationIPCConfiguration(
        ioTimeout: 0.05,
        sharedSecret: paths.secret
    )
    let client = try AutomationIPCClient(
        socketPath: paths.socket.path,
        configuration: configuration
    )
    let slowRequest = AutomationRequest(method: AutomationMethod.systemPing)
    let response = try await sendIPCOnWorker(
        client,
        slowRequest,
        timeout: 2,
        connectionTimeout: 2
    )
    #expect(response.error == nil)

    let timedRequest = AutomationRequest(
        method: AutomationMethod.metadataPatch,
        params: .object(["title": .string("Committed before response timeout")]),
        context: AutomationRequestContext(idempotencyKey: "single-attempt")
    )
    do {
        _ = try await sendIPCOnWorker(
            client,
            timedRequest,
            timeout: 0.05,
            connectionTimeout: 1
        )
        Issue.record("Expected an outcome-unknown timeout after the request was sent.")
    } catch let error as AutomationIPCRequestError {
        #expect(error == .outcomeUnknown(.timeout))
    } catch {
        Issue.record("Expected an AutomationIPCRequestError, got \(error).")
    }
    let handlerDeadline = Date().addingTimeInterval(2)
    while service.metadataPatchRequests.isEmpty && Date() < handlerDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(service.metadataPatchRequests.count == 1)
    #expect(AutomationIPCRequestError.notSent(.timeout).isDefinitelyNotSent)
    await listener.stop()
}

private func verifyIPCClientRefreshesAStaleSecretAfterARejectedHandshake() async throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    #expect(try AutomationIPCSecretStore.load(forSocketPath: paths.socket.path) == paths.secret)
    let service = FakeAutomationService()
    let listener = try await startFakeApp(
        socket: paths.socket,
        secret: paths.secret,
        service: service
    )

    let staleConfiguration = try AutomationIPCConfiguration(
        ioTimeout: 2,
        sharedSecret: Data("stale-credential".utf8)
    )
    let client = try AutomationIPCClient(
        socketPath: paths.socket.path,
        configuration: staleConfiguration
    )
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    do {
        _ = try await sendIPCOnWorker(client, request, timeout: 2, connectionTimeout: 2)
        Issue.record("Expected the stale credential handshake to be rejected before request delivery.")
    } catch let error as AutomationIPCRequestError {
        #expect(error == .notSent(.invalidSharedSecret))
    } catch {
        Issue.record("Expected a not-sent handshake error, got \(error).")
    }

    let recovered = try await sendIPCOnWorker(client, request, timeout: 2, connectionTimeout: 2)
    #expect(recovered.error == nil)
    #expect(service.receivedRequestCount == 1)
    await listener.stop()
}

private func verifyIPCClientClassifiesUnavailableEndpointAndPreservesLegacyErrorSurface() throws {
    let paths = try makeSocketDirectory()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let configuration = try AutomationIPCConfiguration(ioTimeout: 0.1)
    let client = try AutomationIPCClient(
        socketPath: paths.socket.path,
        configuration: configuration
    )
    let request = AutomationRequest(method: AutomationMethod.systemPing)

    #expect(throws: AutomationIPCRequestError.notSent(.connectionFailed(ENOENT))) {
        _ = try client.sendClassified(request, timeout: 0.1, connectionTimeout: 0.1)
    }
    #expect(throws: AutomationIPCError.connectionFailed(ENOENT)) {
        _ = try client.send(request, timeout: 0.1, connectionTimeout: 0.1)
    }
}

@Suite(.serialized)
struct MCPStdioTransportTests {
    @Test func fragmentedResponseUsesOneDeadline() throws {
        var sockets: [Int32] = [-1, -1]
        let opened = sockets.withUnsafeMutableBufferPointer {
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!)
        }
        try #require(opened == 0)
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let writer = sockets[1]
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            Thread.sleep(forTimeInterval: 0.3)
            let header: [UInt8] = [0, 0, 0, 1]
            header.withUnsafeBytes { _ = Darwin.send(writer, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            Thread.sleep(forTimeInterval: 0.4)
            let body: [UInt8] = [42]
            body.withUnsafeBytes { _ = Darwin.send(writer, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        }
        let started = Date()
        #expect(throws: AutomationIPCError.timeout) {
            _ = try readFrame(
                from: sockets[0],
                codec: AutomationIPCFrameCodec(),
                deadline: started.addingTimeInterval(0.5)
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.65)
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test func oneShotPipesDrainModernDiscoveryAndLegacyPing() async throws {
        try await verifyMCPStdioOneShotPipesDrainDiscoveryAndLegacyLifecycle()
    }

    @Test func oneShotEOFDoesNotCancelAcceptedBackgroundJob() async throws {
        try await verifyMCPStdioOneShotEOFDoesNotCancelBackgroundJobRequest()
    }

    @Test func disconnectedStdoutCancelsPendingRequestsWithoutSIGPIPE() async throws {
        try await verifyMCPStdioHandlesDisconnectedOutput()
    }

    @Test func mutationKeysAreScopedToAdapterSession() async throws {
        try await verifyMCPAdapterScopesDefaultIdempotencyKeysToItsStdioSession()
    }

    @Test func adapterSurvivesAppRestart() async throws {
        try await verifyMCPAdapterReturnsRecoverableAppUnavailableAndKeepsRunningForRestart()
    }

    @Test func adapterDoesNotReplayUnknownOutcomeMutations() async throws {
        try await verifyMCPAdapterDoesNotRetryAnAmbiguousMutation()
    }

    @Test func backgroundJobsUseAdapterScopedKeys() async throws {
        try await verifyMCPAdapterScopesBackgroundJobIdempotencyKeys()
    }

    @Test func cliExposesWaitAndBackgroundParameters() async throws {
        try await verifyCLIWaitAliasAndBackgroundParameterInputs()
    }

    @Test func requestTimeoutBudgetsRespectMethodAndDeadline() {
        verifyRequestTimeoutBudgetsMatchSlowOperationsAndContextDeadlines()
    }

    @Test func perCallTimeoutAndAmbiguousDeliveryAreClassified() async throws {
        try await verifyClassifiedIPCRequestAllowsLongerPerCallTimeoutAndNeverHidesAmbiguousDelivery()
    }

    @Test func staleSecretCanRecoverAfterHandshakeRejection() async throws {
        try await verifyIPCClientRefreshesAStaleSecretAfterARejectedHandshake()
    }

    @Test func unavailableEndpointErrorsKeepLegacySurface() throws {
        try verifyIPCClientClassifiesUnavailableEndpointAndPreservesLegacyErrorSurface()
    }
}
