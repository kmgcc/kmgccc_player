import Foundation
import Dispatch
import Darwin
import PlayerAutomationIPC
import PlayerAutomationProtocol

private enum MCPProtocolVersion {
    static let current = "2026-07-28"
    static let legacy = "2025-11-25"
    static let supported = [current, legacy]
    static let handshakeSupported = [legacy]
}

private enum MCPJSONRPCID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else {
            throw MCPProtocolError.invalidRequest
        }
    }

    init?(value: AutomationJSONValue) {
        switch value {
        case .string(let value): self = .string(value)
        case .number(let value): self = .number(value)
        case .null, .boolean, .array, .object: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    /// MCP retries repeat the JSON-RPC id. Keep the App-side idempotency key
    /// stable across those retries while distinguishing strings, numbers and
    /// null IDs that happen to have similar textual descriptions.
    var idempotencyComponent: String {
        switch self {
        case .string(let value): return "string:" + value
        case .number(let value): return "number:" + String(value)
        case .null: return "null"
        }
    }

    var subscriptionMetaValue: AutomationJSONValue? {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .null: return nil
        }
    }
}

private struct MCPRequest: Decodable, Sendable {
    let jsonrpc: String?
    let id: MCPJSONRPCID?
    let method: String?
    let params: AutomationJSONValue?
}

private struct MCPError: Encodable {
    let code: Int
    let message: String
    let data: AutomationJSONValue?
}

private struct MCPResponse: Encodable {
    let jsonrpc = "2.0"
    let id: MCPJSONRPCID?
    let result: AutomationJSONValue?
    let error: MCPError?
    let meta: AutomationJSONValue?

    init(
        id: MCPJSONRPCID?,
        result: AutomationJSONValue?,
        error: MCPError?,
        meta: AutomationJSONValue? = nil
    ) {
        self.id = id
        self.result = result
        self.error = error
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
        case meta = "_meta"
    }
}

private struct MCPServerNotification: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: AutomationJSONValue
}

private final class MCPStdioOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let onWriteFailure: @Sendable () -> Void
    private var writable = true

    init(onWriteFailure: @escaping @Sendable () -> Void) {
        self.onWriteFailure = onWriteFailure
    }

    var isWritable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writable
    }

    func write<Value: Encodable>(_ value: Value) {
        let data: Data
        do {
            data = try AutomationWireCoding.encoder().encode(value) + Data([0x0A])
        } catch {
            let diagnostic = "MCP response encoding failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            return
        }

        lock.lock()
        guard writable else {
            lock.unlock()
            return
        }
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
            lock.unlock()
        } catch {
            writable = false
            lock.unlock()
            let diagnostic = "MCP stdout closed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            onWriteFailure()
        }
    }
}

private final class MCPInFlightRequests: @unchecked Sendable {
    private struct Entry {
        let requestID: MCPJSONRPCID
        let token: AutomationIPCCancellationToken
        let deadline: Date
    }

    private let condition = NSCondition()
    private var requests: [ObjectIdentifier: Entry] = [:]
    private var requestTokens: [MCPJSONRPCID: Set<ObjectIdentifier>] = [:]

    func insert(
        _ token: AutomationIPCCancellationToken,
        for requestID: MCPJSONRPCID,
        deadline: Date
    ) {
        let tokenID = ObjectIdentifier(token)
        condition.lock()
        requests[tokenID] = Entry(requestID: requestID, token: token, deadline: deadline)
        requestTokens[requestID, default: []].insert(tokenID)
        condition.unlock()
    }

    func cancel(_ requestID: MCPJSONRPCID) {
        condition.lock()
        let tokens = requestTokens[requestID, default: []].compactMap { requests[$0]?.token }
        condition.unlock()
        tokens.forEach { $0.cancel() }
    }

    func remove(_ requestID: MCPJSONRPCID, token: AutomationIPCCancellationToken) {
        let tokenID = ObjectIdentifier(token)
        condition.lock()
        defer { condition.unlock() }
        guard let entry = requests[tokenID], entry.requestID == requestID else { return }
        requests.removeValue(forKey: tokenID)
        requestTokens[requestID]?.remove(tokenID)
        if requestTokens[requestID]?.isEmpty == true {
            requestTokens.removeValue(forKey: requestID)
        }
        if requests.isEmpty {
            condition.broadcast()
        }
    }

    func cancelAll() {
        condition.lock()
        let active = requests.values.map(\.token)
        condition.unlock()
        active.forEach { $0.cancel() }
    }

    func drainDeadline(grace: TimeInterval, maximumWait: TimeInterval) -> Date {
        condition.lock()
        let latestRequestDeadline = requests.values.map(\.deadline).max()
        condition.unlock()

        let now = Date()
        let requestDeadline = latestRequestDeadline ?? now
        return min(
            max(now, requestDeadline).addingTimeInterval(max(0, grace)),
            now.addingTimeInterval(max(0, maximumWait))
        )
    }

    @discardableResult
    func waitUntilDrained(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !requests.isEmpty {
            guard deadline.timeIntervalSinceNow > 0 else { return false }
            guard condition.wait(until: deadline) else { return requests.isEmpty }
        }
        return true
    }
}

private final class MCPJobResourceSubscriptions: @unchecked Sendable {
    private struct Subscription {
        let subscriptionID: MCPJSONRPCID
        let resourceURIs: Set<String>
        let taskIDs: Set<String>
        var lastJobs: AutomationJSONValue?
        var hasSnapshot: Bool
        var lastTaskSnapshots: [String: AutomationJSONValue]
        var lastResourceSnapshots: [String: AutomationJSONValue]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kmgccc.player.mcp-job-subscriptions", qos: .utility)
    private let output: MCPStdioOutput
    private let readResource: @Sendable (String) -> AutomationJSONValue?
    private let readJobs: @Sendable () -> AutomationJSONValue?
    private let taskNotificationValue: @Sendable (AutomationJobSummary) -> AutomationJSONValue?
    private var subscriptions: [String: Subscription] = [:]
    private var isPolling = false
    private var isStopped = false

    init(
        output: MCPStdioOutput,
        readJobs: @escaping @Sendable () -> AutomationJSONValue?,
        taskNotificationValue: @escaping @Sendable (AutomationJobSummary) -> AutomationJSONValue?,
        readResource: @escaping @Sendable (String) -> AutomationJSONValue? = { _ in nil }
    ) {
        self.output = output
        self.readResource = readResource
        self.readJobs = readJobs
        self.taskNotificationValue = taskNotificationValue
    }

    func register(
        requestID: MCPJSONRPCID,
        subscriptionID: MCPJSONRPCID,
        resourceURIs: [String],
        taskIDs: [String],
        initialJobs: AutomationJSONValue?,
        initialTaskSnapshots: [String: AutomationJSONValue],
        initialResourceSnapshots: [String: AutomationJSONValue] = [:]
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        let key = requestID.idempotencyComponent
        guard subscriptions[key] == nil else { return false }
        subscriptions[key] = Subscription(
            subscriptionID: subscriptionID,
            resourceURIs: Set(resourceURIs),
            taskIDs: Set(taskIDs),
            lastJobs: initialJobs,
            hasSnapshot: initialJobs != nil,
            lastTaskSnapshots: initialTaskSnapshots,
            lastResourceSnapshots: initialResourceSnapshots
        )
        return true
    }

    func activate() {
        lock.lock()
        let shouldStart = !isStopped
            && !isPolling
            && subscriptions.values.contains {
                !$0.resourceURIs.isDisjoint(with: Self.supportedResourceURIs) || !$0.taskIDs.isEmpty
            }
        if shouldStart { isPolling = true }
        lock.unlock()
        if shouldStart {
            queue.async { [weak self] in self?.pollLoop() }
        }
    }

    func cancel(requestID: MCPJSONRPCID) {
        lock.lock()
        defer { lock.unlock() }
        _ = subscriptions.removeValue(forKey: requestID.idempotencyComponent)
    }

    func stop() {
        lock.lock()
        isStopped = true
        subscriptions.removeAll()
        lock.unlock()
    }

    static let jobsURI = "kmgccc://jobs"
    static let audioStateURI = "kmgccc://audio/state"
    static let dspStateURI = "kmgccc://audio/dsp/state"
    static let dspPresetsURI = "kmgccc://audio/dsp/presets"
    static let supportedResourceURIs: Set<String> = [jobsURI, audioStateURI, dspStateURI, dspPresetsURI]
    static let subscriptionIDMetaKey = "io.modelcontextprotocol/subscriptionId"

    private func pollLoop() {
        while true {
            lock.lock()
            let shouldContinue = !isStopped
                && subscriptions.values.contains {
                    !$0.resourceURIs.isDisjoint(with: Self.supportedResourceURIs) || !$0.taskIDs.isEmpty
                }
            if !shouldContinue {
                isPolling = false
                lock.unlock()
                return
            }
            let requestedURIs = Set(subscriptions.values.flatMap { $0.resourceURIs })
            let needsJobs = requestedURIs.contains(Self.jobsURI)
                || subscriptions.values.contains { !$0.taskIDs.isEmpty }
            lock.unlock()

            var resourceSnapshots: [String: AutomationJSONValue] = [:]
            for uri in requestedURIs.subtracting([Self.jobsURI]) {
                if let snapshot = readResource(uri) { resourceSnapshots[uri] = snapshot }
            }
            lock.lock()
            for key in Array(subscriptions.keys) {
                guard var subscription = subscriptions[key] else { continue }
                for (uri, snapshot) in resourceSnapshots where subscription.resourceURIs.contains(uri) {
                    if subscription.lastResourceSnapshots[uri] != snapshot {
                        subscription.lastResourceSnapshots[uri] = snapshot
                        output.write(MCPServerNotification(
                            method: "notifications/resources/updated",
                            params: .object([
                                "uri": .string(uri),
                                "_meta": .object([
                                    Self.subscriptionIDMetaKey: subscription.subscriptionID.subscriptionMetaValue ?? .null
                                ])
                            ])
                        ))
                    }
                }
                subscriptions[key] = subscription
            }
            lock.unlock()

            if needsJobs, let currentJobs = readJobs() {
                let summaries = Self.jobSummaries(in: currentJobs)
                lock.lock()
                for key in Array(subscriptions.keys) {
                    guard var subscription = subscriptions[key] else { continue }
                    if subscription.resourceURIs.contains(Self.jobsURI) {
                        let changed = !subscription.hasSnapshot || subscription.lastJobs != currentJobs
                        subscription.lastJobs = currentJobs
                        subscription.hasSnapshot = true
                        if changed {
                            output.write(MCPServerNotification(
                                method: "notifications/resources/updated",
                                params: .object([
                                    "uri": .string(Self.jobsURI),
                                    "_meta": .object([
                                        Self.subscriptionIDMetaKey: subscription.subscriptionID.subscriptionMetaValue ?? .null
                                    ])
                                ])
                            ))
                        }
                    }
                    for taskID in subscription.taskIDs {
                        guard let job = summaries.first(where: {
                            MCPTaskIdentity(job: $0)?.rawValue == taskID
                        }),
                        let taskValue = taskNotificationValue(job) else { continue }
                        let changed = subscription.lastTaskSnapshots[taskID] != taskValue
                        subscription.lastTaskSnapshots[taskID] = taskValue
                        if changed {
                            var params: [String: AutomationJSONValue]
                            if case .object(let fields) = taskValue {
                                params = fields
                            } else {
                                params = [:]
                            }
                            params["_meta"] = .object([
                                Self.subscriptionIDMetaKey: subscription.subscriptionID.subscriptionMetaValue ?? .null
                            ])
                            output.write(MCPServerNotification(
                                method: "notifications/tasks",
                                params: .object(params)
                            ))
                        }
                    }
                    subscriptions[key] = subscription
                }
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private static func jobSummaries(in value: AutomationJSONValue) -> [AutomationJobSummary] {
        guard case .object(let fields) = value,
              case .array(let jobs) = fields["jobs"] else { return [] }
        return jobs.compactMap { rawJob in
            guard let data = try? AutomationWireCoding.encoder().encode(rawJob) else { return nil }
            return try? AutomationWireCoding.decoder().decode(AutomationJobSummary.self, from: data)
        }
    }
}

private struct MCPConnectionState: Sendable {
    enum Phase: Equatable, Sendable {
        case undecided
        case legacyAwaitingInitialize
        case legacyAwaitingInitializedNotification
        case legacyReady
        case modernStateless
    }

    var phase: Phase = .undecided
    var protocolVersion: String?
}

/// App Jobs are library-scoped. Encoding both IDs keeps an MCP task handle
/// bound to the library that created it, including across library switches.
private struct MCPTaskIdentity {
    let libraryID: UUID
    let jobID: UUID

    var rawValue: String {
        "\(libraryID.uuidString):\(jobID.uuidString)"
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let libraryID = UUID(uuidString: String(parts[0])),
              let jobID = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        self.libraryID = libraryID
        self.jobID = jobID
    }

    init?(job: AutomationJobSummary) {
        guard let libraryID = job.libraryID else { return nil }
        self.libraryID = libraryID
        self.jobID = job.id
    }
}

private enum MCPProtocolError: Error, LocalizedError {
    case invalidRequest
    case invalidParams(String)
    case methodNotFound(String)
    case notInitialized
    case alreadyInitialized
    case missingTasksCapability
    case taskUnavailable(String)

    var code: Int {
        switch self {
        case .invalidRequest:
            return -32_600
        case .invalidParams:
            return -32_602
        case .methodNotFound:
            return -32_601
        case .notInitialized, .alreadyInitialized:
            return -32_600
        case .missingTasksCapability:
            return -32_021
        case .taskUnavailable:
            return -32_001
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid JSON-RPC request."
        case .invalidParams(let message):
            return message
        case .methodNotFound(let method):
            return "Method not found: \(method)"
        case .notInitialized:
            return "The MCP session must be initialized before this operation."
        case .alreadyInitialized:
            return "The MCP session has already been initialized."
        case .missingTasksCapability:
            return "The client must declare the io.modelcontextprotocol/tasks extension for this request."
        case .taskUnavailable(let message):
            return message
        }
    }

    var data: AutomationJSONValue? {
        guard case .missingTasksCapability = self else { return nil }
        return .object([
            "requiredCapabilities": .object([
                "extensions": .object([
                    "io.modelcontextprotocol/tasks": .object([:])
                ])
            ])
        ])
    }
}

struct AutomationMCPStdioOptions: Sendable {
    let socketPath: String
    let noLaunch: Bool
    let timeout: TimeInterval
    let timeoutWasSet: Bool
}

struct AutomationMCPStdioServer: Sendable {
    let options: AutomationMCPStdioOptions
    private let idempotencySessionID = UUID()

    func run() -> Int32 {
        // A disconnected MCP client must be reported as a write failure so
        // pending IPC work can be cancelled instead of terminating by SIGPIPE.
        _ = signal(SIGPIPE, SIG_IGN)
        var client: AutomationIPCClient?
        var state = MCPConnectionState()
        let inFlight = MCPInFlightRequests()
        let output = MCPStdioOutput { inFlight.cancelAll() }
        let subscriptions = MCPJobResourceSubscriptions(
            output: output,
            readJobs: { [self] in readJobsForSubscription() },
            taskNotificationValue: { [self] job in taskNotificationValue(for: job) },
            readResource: { [self] uri in readDSPResourceForSubscription(uri: uri) }
        )
        while output.isWritable, let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            var isNotification = false
            var requestID: MCPJSONRPCID?
            do {
                let request = try AutomationWireCoding.decoder().decode(
                    MCPRequest.self,
                    from: Data(line.utf8)
                )
                guard request.jsonrpc == "2.0",
                      let method = request.method,
                      !method.isEmpty else {
                    throw MCPProtocolError.invalidRequest
                }
                isNotification = request.id == nil
                requestID = request.id
                if request.method == "subscriptions/listen" {
                    try openSubscription(request, state: &state, subscriptions: subscriptions, output: output)
                } else if request.method == "notifications/cancelled", request.id == nil {
                    cancelSubscription(request, subscriptions: subscriptions)
                    if let cancelledID = cancelledRequestID(request) {
                        inFlight.cancel(cancelledID)
                    }
                } else if request.method == "initialize"
                    || request.method == "notifications/initialized"
                    || request.id == nil {
                    if let response = try handle(
                        request,
                        client: &client,
                        state: &state
                    ) {
                        output.write(response)
                    }
                } else if let requestID = request.id {
                    if requestProtocolVersion(request) != nil {
                        try negotiateRequest(request, state: &state)
                    }
                    let cancellation = AutomationIPCCancellationToken()
                    inFlight.insert(
                        cancellation,
                        for: requestID,
                        deadline: inFlightDeadline(for: request)
                    )
                    let stateSnapshot = state
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        defer { inFlight.remove(requestID, token: cancellation) }
                        var requestClient: AutomationIPCClient?
                        var requestState = stateSnapshot
                        do {
                            if let response = try handle(
                                request,
                                client: &requestClient,
                                state: &requestState,
                                cancellation: cancellation
                            ), !cancellation.isCancelled {
                                output.write(response)
                            }
                        } catch let error as MCPProtocolError {
                            guard !cancellation.isCancelled else { return }
                            output.write(
                                MCPResponse(
                                    id: requestID,
                                    result: nil,
                                    error: MCPError(
                                        code: error.code,
                                        message: error.localizedDescription,
                                        data: error.data
                                    )
                                )
                            )
                        } catch {
                            guard !cancellation.isCancelled else { return }
                            output.write(
                                MCPResponse(
                                    id: requestID,
                                    result: nil,
                                    error: MCPError(
                                        code: -32_000,
                                        message: error.localizedDescription,
                                        data: nil
                                    )
                                )
                            )
                        }
                    }
                } else if let response = try handle(request, client: &client, state: &state) {
                    output.write(response)
                }
            } catch let error as MCPProtocolError {
                if isNotification { continue }
                output.write(
                    MCPResponse(
                        id: requestID,
                        result: nil,
                        error: MCPError(
                            code: error.code,
                            message: error.localizedDescription,
                            data: error.data
                        )
                    )
                )
            } catch {
                if isNotification { continue }
                output.write(
                    MCPResponse(
                        id: nil,
                        result: nil,
                        error: MCPError(
                            code: -32_700,
                            message: "Parse error: \(error.localizedDescription)",
                            data: nil
                        )
                    )
                )
            }
        }
        subscriptions.stop()

        if output.isWritable {
            let drainDeadline = inFlight.drainDeadline(
                grace: 0.5,
                maximumWait: AutomationToolDefaults.maximumTimeout + 0.5
            )
            if !inFlight.waitUntilDrained(until: drainDeadline) {
                inFlight.cancelAll()
                _ = inFlight.waitUntilDrained(until: Date().addingTimeInterval(1))
            }
        } else {
            inFlight.cancelAll()
            _ = inFlight.waitUntilDrained(until: Date().addingTimeInterval(1))
        }
        return 0
    }

    private func inFlightDeadline(for request: MCPRequest) -> Date {
        let now = Date()
        guard request.method == "tools/call",
              case .object(let values) = request.params,
              case .string(let toolName) = values["name"] else {
            return now.addingTimeInterval(
                min(max(options.timeout, 0.000_001), AutomationToolDefaults.maximumTimeout)
            )
        }

        let context = (try? automationContext(from: values["context"]))
            ?? AutomationRequestContext(caller: "mcp")
        let automationRequest = AutomationRequest(
            method: toolName,
            params: values["arguments"],
            context: context
        )
        return AutomationToolDefaults.requestDeadline(
            for: automationRequest,
            configuredTimeout: options.timeout,
            timeoutWasSet: options.timeoutWasSet,
            now: now
        )
    }

    private func openSubscription(
        _ request: MCPRequest,
        state: inout MCPConnectionState,
        subscriptions: MCPJobResourceSubscriptions,
        output: MCPStdioOutput
    ) throws {
        try negotiateRequest(request, state: &state)
        try requireReady(state)
        guard isModernRequest(request) else {
            throw MCPProtocolError.methodNotFound("subscriptions/listen")
        }
        guard let requestID = request.id,
              let subscriptionID = requestID.subscriptionMetaValue else {
            throw MCPProtocolError.invalidRequest
        }
        guard case .object(let values) = request.params,
              case .object(let notifications)? = values["notifications"] else {
            throw MCPProtocolError.invalidParams("subscriptions/listen requires a notifications filter object.")
        }
        let requestedURIs: [String]
        if let rawURIs = notifications["resourceSubscriptions"] {
            guard case .array(let values) = rawURIs,
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw MCPProtocolError.invalidParams("notifications.resourceSubscriptions must be an array of resource URI strings.")
            }
            requestedURIs = values.compactMap { if case .string(let uri) = $0 { return uri }; return nil }
        } else {
            requestedURIs = []
        }
        let requestedTaskIDs: [String]
        if let rawTaskIDs = notifications["taskIds"] {
            guard case .array(let values) = rawTaskIDs,
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                throw MCPProtocolError.invalidParams("notifications.taskIds must be an array of task ID strings.")
            }
            requestedTaskIDs = values.compactMap { if case .string(let taskID) = $0 { return taskID }; return nil }
            if !requestedTaskIDs.isEmpty { try requireTasksCapability(request) }
        } else {
            requestedTaskIDs = []
        }
        let acceptedURIs = Array(Set(requestedURIs.filter { MCPJobResourceSubscriptions.supportedResourceURIs.contains($0) })).sorted()
        let initialJobs = acceptedURIs.contains(MCPJobResourceSubscriptions.jobsURI)
            || !requestedTaskIDs.isEmpty
            ? readJobsForSubscription()
            : nil
        let visibleJobs = jobSummaries(from: initialJobs)
        let visibleTaskIDs = Set(visibleJobs.compactMap { MCPTaskIdentity(job: $0)?.rawValue })
        let acceptedTaskIDs = Array(Set(requestedTaskIDs.filter { visibleTaskIDs.contains($0) })).sorted()
        var initialTaskSnapshots: [String: AutomationJSONValue] = [:]
        for taskID in acceptedTaskIDs {
            guard let job = visibleJobs.first(where: { MCPTaskIdentity(job: $0)?.rawValue == taskID }),
                  let value = taskNotificationValue(for: job) else { continue }
            initialTaskSnapshots[taskID] = value
        }
        var initialResourceSnapshots: [String: AutomationJSONValue] = [:]
        for uri in acceptedURIs where uri != MCPJobResourceSubscriptions.jobsURI {
            if let snapshot = readDSPResourceForSubscription(uri: uri) { initialResourceSnapshots[uri] = snapshot }
        }
        guard subscriptions.register(
            requestID: requestID,
            subscriptionID: requestID,
            resourceURIs: acceptedURIs,
            taskIDs: acceptedTaskIDs,
            initialJobs: initialJobs,
            initialTaskSnapshots: initialTaskSnapshots,
            initialResourceSnapshots: initialResourceSnapshots
        ) else {
            throw MCPProtocolError.invalidRequest
        }

        var acknowledgedFilter: [String: AutomationJSONValue] = [:]
        if notifications["resourceSubscriptions"] != nil {
            acknowledgedFilter["resourceSubscriptions"] = .array(
                acceptedURIs.map(AutomationJSONValue.string)
            )
        }
        if notifications["taskIds"] != nil {
            acknowledgedFilter["taskIds"] = .array(acceptedTaskIDs.map(AutomationJSONValue.string))
        }

        output.write(MCPServerNotification(
            method: "notifications/subscriptions/acknowledged",
            params: .object([
                "notifications": .object(acknowledgedFilter),
                "_meta": .object([
                    MCPJobResourceSubscriptions.subscriptionIDMetaKey: subscriptionID
                ])
            ])
        ))
        subscriptions.activate()
    }

    private func cancelSubscription(
        _ request: MCPRequest,
        subscriptions: MCPJobResourceSubscriptions
    ) {
        guard case .object(let params) = request.params,
              let rawRequestID = params["requestId"],
              let requestID = MCPJSONRPCID(value: rawRequestID) else {
            return
        }
        subscriptions.cancel(requestID: requestID)
    }

    private func cancelledRequestID(_ request: MCPRequest) -> MCPJSONRPCID? {
        guard case .object(let params) = request.params,
              let rawRequestID = params["requestId"] else {
            return nil
        }
        return MCPJSONRPCID(value: rawRequestID)
    }

    private func handle(
        _ request: MCPRequest,
        client: inout AutomationIPCClient?,
        state: inout MCPConnectionState,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> MCPResponse? {
        guard let method = request.method else {
            throw MCPProtocolError.invalidRequest
        }
        switch method {
        case "server/discover":
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: discoveryResult(modern: isModernRequest(request)),
                modern: isModernRequest(request)
            )

        case "initialize":
            guard request.id != nil else { throw MCPProtocolError.invalidRequest }
            guard state.phase == .undecided else {
                throw MCPProtocolError.alreadyInitialized
            }
            guard case .object(let values) = request.params,
                  case .string(let requestedVersion) = values["protocolVersion"] else {
                throw MCPProtocolError.invalidParams(
                    "initialize requires an object with a string protocolVersion."
                )
            }
            guard MCPProtocolVersion.handshakeSupported.contains(requestedVersion) else {
                throw MCPProtocolError.invalidParams(
                    "The 2026-07-28 protocol is stateless and does not use initialize; send server/discover or a per-request _meta protocolVersion."
                )
            }
            let selectedVersion = requestedVersion
            state.protocolVersion = selectedVersion
            state.phase = .legacyAwaitingInitializedNotification
            return success(
                id: request.id,
                result: initializeResult(protocolVersion: selectedVersion)
            )

        case "notifications/initialized":
            guard request.id == nil else { throw MCPProtocolError.invalidRequest }
            guard state.phase == .legacyAwaitingInitializedNotification else {
                throw MCPProtocolError.notInitialized
            }
            state.phase = .legacyReady
            return nil

        case "notifications/cancelled":
            guard request.id == nil else { throw MCPProtocolError.invalidRequest }
            return nil

        case "tasks/get":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            try requireTasksCapability(request)
            guard case .object(let values) = request.params,
                  case .string(let rawTaskID) = values["taskId"],
                  let taskIdentity = MCPTaskIdentity(rawValue: rawTaskID) else {
                throw MCPProtocolError.invalidParams("tasks/get requires a taskId returned by this server.")
            }
            guard request.id != nil else { return nil }
            let job = try fetchJob(taskIdentity, client: &client, cancellation: cancellation)
            return success(id: request.id, result: taskValue(job, resultType: "complete", identity: taskIdentity), modern: isModernRequest(request))

        case "tasks/update":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            try requireTasksCapability(request)
            guard case .object(let values) = request.params,
                  case .string(let rawTaskID) = values["taskId"],
                  let taskIdentity = MCPTaskIdentity(rawValue: rawTaskID),
                  case .object? = values["inputResponses"] else {
                throw MCPProtocolError.invalidParams("tasks/update requires a taskId returned by this server and an inputResponses object.")
            }
            guard request.id != nil else { return nil }
            _ = try fetchJob(taskIdentity, client: &client, cancellation: cancellation)
            return success(id: request.id, result: .object(["resultType": .string("complete")]), modern: isModernRequest(request))

        case "tasks/cancel":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            try requireTasksCapability(request)
            guard case .object(let values) = request.params,
                  case .string(let rawTaskID) = values["taskId"],
                  let taskIdentity = MCPTaskIdentity(rawValue: rawTaskID) else {
                throw MCPProtocolError.invalidParams("tasks/cancel requires a taskId returned by this server.")
            }
            guard request.id != nil else { return nil }
            let cancelRequest = AutomationRequest(
                method: AutomationMethod.jobsCancel,
                params: .object(["jobID": .string(taskIdentity.jobID.uuidString)]),
                context: AutomationRequestContext(libraryID: taskIdentity.libraryID, caller: "mcp-tasks")
            )
            let response: AutomationResponse
            do {
                let deadline = Date().addingTimeInterval(options.timeout)
                if client == nil {
                    client = try makeClient(timeout: options.timeout, cancellation: cancellation)
                }
                response = try send(
                    cancelRequest,
                    client: client!,
                    deadline: deadline,
                    connectionDeadline: deadline,
                    cancellation: cancellation
                )
            } catch {
                throw MCPProtocolError.taskUnavailable("Unable to cancel the task: \(error.localizedDescription)")
            }
            guard response.error == nil else {
                throw MCPProtocolError.taskUnavailable(response.error?.message ?? "The task could not be cancelled.")
            }
            return success(id: request.id, result: .object(["resultType": .string("complete")]), modern: isModernRequest(request))

        case "ping":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: .object([:]),
                modern: isModernRequest(request)
            )

        case "tools/list":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard request.params == nil
                || request.params == .null
                || isObject(request.params) else {
                throw MCPProtocolError.invalidParams("tools/list params must be an object.")
            }
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: toolsListResult(modern: isModernRequest(request)),
                modern: isModernRequest(request)
            )

        case "tools/call":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard let id = request.id else {
                return nil
            }
            guard case .object(let values) = request.params else {
                throw MCPProtocolError.invalidParams("tools/call params must be an object.")
            }
            guard case .string(let toolName) = values["name"] else {
                throw MCPProtocolError.invalidParams("tools/call requires a string 'name'.")
            }
            guard AutomationToolCatalog.descriptor(for: toolName) != nil else {
                throw MCPProtocolError.methodNotFound(toolName)
            }

            let arguments: AutomationJSONValue?
            if let rawArguments = values["arguments"] {
                guard case .object = rawArguments else {
                    throw MCPProtocolError.invalidParams("tools/call arguments must be an object.")
                }
                arguments = rawArguments
            } else {
                arguments = nil
            }
            let requestID = UUID()
            let suppliedContext = try automationContext(from: values["context"])
            let descriptor = AutomationToolCatalog.descriptor(for: toolName)
            let requestsBackgroundJob: Bool
            if case .object(let toolArguments)? = arguments,
               case .boolean(true)? = toolArguments["background"] {
                requestsBackgroundJob = true
            } else {
                requestsBackgroundJob = false
            }
            let submitsBackgroundJob = descriptor?.supportsJobs == true && requestsBackgroundJob
            let idempotencyKey = suppliedContext.idempotencyKey
                ?? (descriptor?.readOnly == false || submitsBackgroundJob
                    ? "mcp:\(idempotencySessionID.uuidString):\(id.idempotencyComponent)"
                    : nil)
            let automationRequest = AutomationRequest(
                method: toolName,
                params: arguments,
                context: AutomationRequestContext(
                    principalSessionID: suppliedContext.principalSessionID,
                    libraryID: suppliedContext.libraryID,
                    idempotencyKey: idempotencyKey,
                    deadline: suppliedContext.deadline,
                    caller: suppliedContext.caller
                ),
                requestID: requestID
            )
            let toolResult: AutomationJSONValue
            do {
                let requestDeadline = AutomationToolDefaults.requestDeadline(
                    for: automationRequest,
                    configuredTimeout: options.timeout,
                    timeoutWasSet: options.timeoutWasSet
                )
                let connectionDeadline = min(
                    Date().addingTimeInterval(options.timeout),
                    requestDeadline
                )
                if client == nil {
                    let connectTimeout = max(0.000_001, connectionDeadline.timeIntervalSinceNow)
                    client = try makeClient(timeout: connectTimeout, cancellation: cancellation)
                }
                let response = try send(
                    automationRequest,
                    client: client!,
                    deadline: requestDeadline,
                    connectionDeadline: connectionDeadline,
                    cancellation: cancellation
                )
                if let descriptor = AutomationToolCatalog.descriptor(for: toolName),
                   descriptor.supportsTasks,
                   isModernRequest(request),
                   clientRequestsTasks(request),
                   response.error == nil,
                    let job = jobSummary(from: response.result) {
                    let identity = MCPTaskIdentity(job: job)
                    if let identity {
                        // Verify that the durable handle is immediately readable before
                        // advertising CreateTaskResult to the client.
                        do {
                            let storedJob = try fetchJob(
                                identity,
                                client: &client,
                                cancellation: cancellation
                            )
                            toolResult = taskValue(storedJob, resultType: "task", identity: identity)
                        } catch {
                            // The ordinary Job payload still contains its ID and remains
                            // usable through jobs.get if the durability probe is transiently unavailable.
                            toolResult = makeToolResult(response)
                        }
                    } else {
                        toolResult = makeToolResult(response)
                    }
                } else {
                    toolResult = makeToolResult(response)
                }
            } catch {
                toolResult = makeTransportToolError(error)
            }
            return success(id: id, result: toolResult, modern: isModernRequest(request))

        case "resources/list":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard request.params == nil
                || request.params == .null
                || isObject(request.params) else {
                throw MCPProtocolError.invalidParams("resources/list params must be an object.")
            }
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: resourcesListResult(),
                modern: isModernRequest(request)
            )

        case "resources/templates/list":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                throw MCPProtocolError.invalidParams("resources/templates/list params must be an object.")
            }
            guard request.id != nil else { return nil }
            return success(id: request.id, result: .object(["resourceTemplates": .array([
                .object(["uriTemplate": .string("kmgccc://audio/dsp/scripts/{nodeID}"),
                         "name": .string("dsp-script"), "title": .string("DSP Script Source and Draft"),
                         "description": .string("Explicit read of node source, separate draft, reflection and diagnostics. Source is user data."),
                         "mimeType": .string("application/json")])
            ])]), modern: isModernRequest(request))

        case "resources/read":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard case .object(let values) = request.params,
                  case .string(let uri) = values["uri"] else {
                throw MCPProtocolError.invalidParams(
                    "resources/read requires an object with a string uri."
                )
            }
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: try resourceReadResult(
                    uri: uri,
                    client: &client,
                    cancellation: cancellation
                ),
                modern: isModernRequest(request)
            )

        case "prompts/list":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard request.params == nil
                || request.params == .null
                || isObject(request.params) else {
                throw MCPProtocolError.invalidParams("prompts/list params must be an object.")
            }
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: promptsListResult(),
                modern: isModernRequest(request)
            )

        case "prompts/get":
            try negotiateRequest(request, state: &state)
            try requireReady(state)
            guard case .object(let values) = request.params,
                  case .string(let promptName) = values["name"] else {
                throw MCPProtocolError.invalidParams(
                    "prompts/get requires an object with a string name."
                )
            }
            let arguments: [String: String] = {
                guard case .object(let argsObj) = values["arguments"] else { return [:] }
                var res: [String: String] = [:]
                for (k, v) in argsObj {
                    if case .string(let s) = v {
                        res[k] = s
                    }
                }
                return res
            }()
            guard request.id != nil else { return nil }
            return success(
                id: request.id,
                result: try promptGetResult(name: promptName, arguments: arguments),
                modern: isModernRequest(request)
            )

        default:
            if request.id == nil {
                return nil
            }
            throw MCPProtocolError.methodNotFound(method)
        }
    }

    private func discoveryResult(modern: Bool) -> AutomationJSONValue {
        var values: [String: AutomationJSONValue] = [
            "resultType": .string("complete"),
            "supportedVersions": .array(
                MCPProtocolVersion.supported.map { .string($0) }
            ),
            "capabilities": capabilitiesValue(modern: modern),
            "instructions": .string(
                "Use read-only tools to inspect the active library, then compose authorized low-risk mutations. Use dryRun for an explicit preview; only high-risk operations require caller acknowledgement plus App foreground confirmation. Removing playlist membership never deletes the library Track or audio file."
            )
        ]
        if !modern {
            values["serverInfo"] = serverInfoValue
        }
        return .object(values)
    }

    private func initializeResult(protocolVersion: String) -> AutomationJSONValue {
        return .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": capabilitiesValue(modern: false),
            "serverInfo": serverInfoValue,
            "instructions": .string(
                AutomationDocumentation.agentBehaviorGuide
            )
        ])
    }

    private func toolsListResult(modern: Bool) -> AutomationJSONValue {
        .object([
            "tools": .array(AutomationToolCatalog.all.map { toolValue($0, modern: modern) })
        ])
    }

    private func resourcesListResult() -> AutomationJSONValue {
        .object([
            "resources": .array([
                .object([
                    "uri": .string("kmgccc://capabilities"),
                    "name": .string("capabilities"),
                    "title": .string("Automation Capability Catalog"),
                    "description": .string("Shared capability, scope and composition guidance."),
                    "mimeType": .string("text/plain")
                ]),
                .object([
                    "uri": .string("kmgccc://agent-guide"),
                    "name": .string("agent-guide"),
                    "title": .string("Agent Behavior Guide"),
                    "description": .string("Stable Track, Playlist, Source, safety and storage semantics."),
                    "mimeType": .string("text/plain")
                ]),
                .object([
                    "uri": .string("kmgccc://dsp-language"), "name": .string("dsp-language"),
                    "title": .string("DSP Language Guide"),
                    "description": .string("Bundled DSP grammar, reflected parameters, budgets and script repair workflow."),
                    "mimeType": .string("text/plain")
                ]),
                .object([
                    "uri": .string(MCPJobResourceSubscriptions.jobsURI),
                    "name": .string("jobs"),
                    "title": .string("Library Jobs"),
                    "description": .string("Current library import, enrichment, conversion, scan, export and write jobs."),
                    "mimeType": .string("application/json")
                ]),
                .object([
                    "uri": .string(MCPJobResourceSubscriptions.audioStateURI),
                    "name": .string("audio-state"), "title": .string("Global Audio State"),
                    "description": .string("Global fade, normalization, device references and actual transport state."),
                    "mimeType": .string("application/json")
                ]),
                .object([
                    "uri": .string(MCPJobResourceSubscriptions.dspStateURI),
                    "name": .string("audio-dsp-state"),
                    "title": .string("Audio DSP State"),
                    "description": .string("Desired, scheduled and audible DSP configuration and diagnostics."),
                    "mimeType": .string("application/json")
                ]),
                .object([
                    "uri": .string(MCPJobResourceSubscriptions.dspPresetsURI),
                    "name": .string("audio-dsp-presets"),
                    "title": .string("Audio DSP Presets"),
                    "description": .string("Saved DSP presets and the selected working draft."),
                    "mimeType": .string("application/json")
                ])
            ])
        ])
    }

    private func resourceReadResult(
        uri: String,
        client: inout AutomationIPCClient?,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationJSONValue {
        let text: String
        let mimeType: String
        switch uri {
        case "kmgccc://capabilities":
            text = AutomationDocumentation.capabilityOverview
            mimeType = "text/plain"
        case "kmgccc://agent-guide":
            text = AutomationDocumentation.agentBehaviorGuide
            mimeType = "text/plain"
        case "kmgccc://dsp-language":
            text = AutomationDSPScriptDocumentation.languageGuide
            mimeType = "text/plain"
        case MCPJobResourceSubscriptions.jobsURI:
            text = jsonText(try currentJobs(client: &client, cancellation: cancellation))
            mimeType = "application/json"
        case MCPJobResourceSubscriptions.audioStateURI, MCPJobResourceSubscriptions.dspStateURI, MCPJobResourceSubscriptions.dspPresetsURI:
            text = jsonText(try currentDSPResource(uri: uri, client: &client, cancellation: cancellation))
            mimeType = "application/json"
        default:
            let prefix = "kmgccc://audio/dsp/scripts/"
            guard uri.hasPrefix(prefix), let nodeID = UUID(uuidString: String(uri.dropFirst(prefix.count))) else {
                throw MCPProtocolError.invalidParams("Unknown resource URI: \(uri)")
            }
            text = jsonText(try currentScriptResource(nodeID: nodeID, client: &client, cancellation: cancellation))
            mimeType = "application/json"
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string(mimeType),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private func promptsListResult() -> AutomationJSONValue {
        .object([
            "prompts": .array([
                .object([
                    "name": .string("audit_and_clean_lyrics"),
                    "description": .string(
                        "SOP for inspecting track lyrics quality, stripping preamble/credit noise with built-in lyrics.clean, and falling back to manual TTML editing."
                    ),
                    "arguments": .array([
                        .object([
                            "name": .string("trackID"),
                            "description": .string("Optional Track UUID to audit or clean."),
                            "required": .boolean(false)
                        ])
                    ])
                ]),
                .object([
                    "name": .string("upgrade_lyrics_workflow"),
                    "description": .string(
                        "SOP for searching, ranking, and applying word-synced (verbatim) lyrics candidates with automatic metadata cleaning."
                    ),
                    "arguments": .array([
                        .object([
                            "name": .string("trackID"),
                            "description": .string("Track UUID to upgrade lyrics for."),
                            "required": .boolean(true)
                        ])
                    ])
                ]),
                .object([
                    "name": .string("import_audio_workflow"),
                    "description": .string(
                        "Import user-selected audio through the same App pipeline as manual import, including NCM conversion, duplicate handling and automatic metadata, artwork and lyrics enrichment."
                    ),
                    "arguments": .array([
                        .object([
                            "name": .string("filePaths"),
                            "description": .string("One absolute file or folder path per line."),
                            "required": .boolean(true)
                        ]),
                        .object([
                            "name": .string("targetPlaylistID"),
                            "description": .string("Optional destination Playlist UUID."),
                            "required": .boolean(false)
                        ])
                    ])
                ])
            ])
        ])
    }

    private func promptGetResult(name: String, arguments: [String: String]) throws -> AutomationJSONValue {
        switch name {
        case "audit_and_clean_lyrics":
            let targetTrack = arguments["trackID"].map { " for track \($0)" } ?? ""
            let text = """
# Lyrics Audit and Cleaning Standard Operating Procedure (SOP)\(targetTrack)

Follow this structured workflow to ensure lyrics quality:

1. **Inspect Current Status**:
   - Call `lyrics.get(trackID: ...)` to inspect `lyricsStatus` (`wordSynced`, `lineSynced`, `plain`, or `none`).
   - Pure instrumental tracks (e.g. tracks marked as pure music or confirmed to have no vocals) must be kept strictly untouched.

2. **Audit Preamble & Credit Noise**:
   - Check if the beginning or ending contains metadata noise (composers, lyricists, arrangers, producers, vocalists, recording/mixing credits, label tags, or solo speaker headers like '马猋：').

3. **Step 1: Use Built-in Cleaner (`lyrics.clean`)**:
   - Run `lyrics.clean(trackID: ...)` (optionally with `dryRun: true` first to preview).
   - The App-level built-in cleaner automatically identifies preamble and trailing credit lines, strips them, renumbers lines (`itunes:key="L1"..."Ln"`), and updates `<div begin="...">` to match the actual vocal onset.

4. **Step 2: Agent Manual TTML Fallback**:
   - If `lyrics.clean` reported `cleaned: false` or if non-standard noise persists:
     a. Fetch the current TTML via `lyrics.get(trackID: ...)`.
     b. Manually remove noise `<p>` tags from the TTML string.
     c. Ensure word timing tags `<span begin="..." end="...">` within sung lines are preserved.
     d. Align `<div begin="...">` to the first sung line's begin time.
     e. Apply the corrected TTML using `lyrics.apply(trackID: ..., ttmlText: sanitizedTTML)`.

5. **Verify**:
   - Run `lyrics.get(trackID: ...)` to verify that `status` remains `wordSynced` and the first line starts directly with the song vocals.
"""
            return .object([
                "description": .string("SOP for inspecting track lyrics quality and cleaning noise."),
                "messages": .array([
                    .object([
                        "role": .string("user"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(text)
                        ])
                    ])
                ])
            ])

        case "upgrade_lyrics_workflow":
            let trackIdStr = arguments["trackID"] ?? "<trackID>"
            let text = """
# Upgrade Lyrics to Word-Synced Workflow for Track \(trackIdStr)

1. **Search Candidates**:
   - Call `lyrics.search(trackID: "\(trackIdStr)")` or `lyrics.candidates(trackID: "\(trackIdStr)")`.
   - The system automatically handles title noise stripping (e.g. OST brackets like '（电影《...》插曲）') and falls back to clean queries if needed.

2. **Rank & Select Best Word-Synced Candidate**:
   - Prioritize candidates with `mode: "verbatim"` (word-synced, quality: 2) and high `normalizedScore` (>= 75.0).
   - Prefer candidates where title, artist, and duration closely match the track.

3. **Apply Candidate with Clean Metadata**:
   - Call `lyrics.apply(trackID: "\(trackIdStr)", candidate: selectedCandidate, cleanMetadata: true)`.
   - The built-in cleaner will automatically sanitize preamble and trailing credits before writing to the library.

4. **Audit and Verify**:
   - Call `lyrics.get(trackID: "\(trackIdStr)")` to verify:
     - `status` is `wordSynced`.
     - The first line is clean singing lyrics, not credit noise.
   - If any minor noise remains, call `lyrics.clean(trackID: "\(trackIdStr)")`.
"""
            return .object([
                "description": .string("Workflow for searching and upgrading to word-synced lyrics."),
                "messages": .array([
                    .object([
                        "role": .string("user"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(text)
                        ])
                    ])
                ])
            ])

        case "import_audio_workflow":
            let paths = arguments["filePaths"] ?? "<one absolute path per line>"
            let playlist = arguments["targetPlaylistID"]
                .map { "\n4. Add `targetPlaylistID: \"\($0)\"` to the import call." } ?? ""
            let text = """
# Import Audio into the Active Library

1. Convert the `filePaths` argument into an array of absolute paths, one entry per line. Include folders when the user selected a folder.
2. Check the active Library and target Playlist with `library.get` and `playlist.get` when those IDs or the destination are ambiguous.
3. Call `library.import(filePaths: \(paths))`. The App owns authorization, managed or referenced placement, NCM conversion, duplicate reuse, Playlist membership and metadata/artwork/lyrics enrichment. Do not write sidecars or decrypt files outside the App.\(playlist)
4. Poll the returned MCP task with `tasks/get` when the request negotiated Tasks; otherwise poll its App Job with `jobs.get`. Report per-file failures separately from enrichment warnings.
5. Confirm persisted Track IDs and Playlist membership after completion. Provider no-match warnings are not import failures and do not guarantee enrichment for every song.
"""
            return .object([
                "description": .string("Safe import workflow for MP3, lossless audio and NCM sources."),
                "messages": .array([
                    .object([
                        "role": .string("user"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(text)
                        ])
                    ])
                ])
            ])

        default:
            throw MCPProtocolError.invalidParams("Unknown prompt: \(name)")
        }
    }

    private func requireReady(_ state: MCPConnectionState) throws {
        guard state.phase == .legacyReady || state.phase == .modernStateless else {
            throw MCPProtocolError.notInitialized
        }
    }

    /// MCP 2026-07-28 is stateless: every request carries its negotiated
    /// protocol version in params._meta and does not use initialize. The
    /// 2025-11-25 path remains available for clients that still speak the
    /// session handshake. Stdio has no HTTP headers, so body metadata is the
    /// authoritative version signal here.
    private func negotiateRequest(
        _ request: MCPRequest,
        state: inout MCPConnectionState
    ) throws {
        guard let version = requestProtocolVersion(request) else {
            guard state.phase == .legacyReady else {
                throw MCPProtocolError.notInitialized
            }
            return
        }
        guard MCPProtocolVersion.supported.contains(version) else {
            throw MCPProtocolError.invalidParams(
                "Unsupported MCP protocol version \(version). Supported versions: \(MCPProtocolVersion.supported.joined(separator: ", "))."
            )
        }
        switch version {
        case MCPProtocolVersion.current:
            guard state.phase == .undecided || state.phase == .modernStateless else {
                throw MCPProtocolError.alreadyInitialized
            }
            state.phase = .modernStateless
            state.protocolVersion = version
        case MCPProtocolVersion.legacy:
            guard state.phase == .legacyReady else {
                throw MCPProtocolError.notInitialized
            }
        default:
            throw MCPProtocolError.invalidParams("Unsupported MCP protocol version.")
        }
    }

    private func requestProtocolVersion(_ request: MCPRequest) -> String? {
        guard case .object(let values) = request.params,
              case .object(let meta) = values["_meta"],
              case .string(let version) = meta["io.modelcontextprotocol/protocolVersion"] else {
            return nil
        }
        return version
    }

    private func isModernRequest(_ request: MCPRequest) -> Bool {
        requestProtocolVersion(request) == MCPProtocolVersion.current
    }

    private func clientRequestsTasks(_ request: MCPRequest) -> Bool {
        guard case .object(let values) = request.params,
              case .object(let meta) = values["_meta"],
              case .object(let clientCapabilities) = meta["io.modelcontextprotocol/clientCapabilities"],
              case .object(let extensions) = clientCapabilities["extensions"],
              case .object? = extensions["io.modelcontextprotocol/tasks"] else {
            return false
        }
        return true
    }

    private func requireTasksCapability(_ request: MCPRequest) throws {
        guard isModernRequest(request), clientRequestsTasks(request) else {
            throw MCPProtocolError.missingTasksCapability
        }
    }

    private func jobSummary(from value: AutomationJSONValue?) -> AutomationJobSummary? {
        guard let value else { return nil }
        if case .object(let fields) = value {
            if let nested = fields["job"], let summary = decodeJobSummary(nested) {
                return summary
            }
            if case .array(let jobs) = fields["jobs"], jobs.count == 1 {
                return decodeJobSummary(jobs[0])
            }
        }
        return decodeJobSummary(value)
    }

    private func decodeJobSummary(_ value: AutomationJSONValue) -> AutomationJobSummary? {
        guard let data = try? AutomationWireCoding.encoder().encode(value) else { return nil }
        return try? AutomationWireCoding.decoder().decode(AutomationJobSummary.self, from: data)
    }

    private func jobSummaries(from value: AutomationJSONValue?) -> [AutomationJobSummary] {
        guard case .object(let fields)? = value,
              case .array(let jobs)? = fields["jobs"] else { return [] }
        return jobs.compactMap(decodeJobSummary)
    }

    private func taskNotificationValue(for job: AutomationJobSummary) -> AutomationJSONValue? {
        guard let identity = MCPTaskIdentity(job: job),
              case .object(var fields) = taskValue(
                job,
                resultType: "complete",
                identity: identity
              ) else { return nil }
        fields.removeValue(forKey: "resultType")
        return .object(fields)
    }

    private func fetchJob(
        _ identity: MCPTaskIdentity,
        client: inout AutomationIPCClient?,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationJobSummary {
        let response: AutomationResponse
        do {
            let deadline = Date().addingTimeInterval(options.timeout)
            if client == nil {
                client = try makeClient(timeout: options.timeout, cancellation: cancellation)
            }
            let request = AutomationRequest(
                method: AutomationMethod.jobsGet,
                params: .object(["jobID": .string(identity.jobID.uuidString)]),
                context: AutomationRequestContext(libraryID: identity.libraryID, caller: "mcp-tasks")
            )
            response = try send(
                request,
                client: client!,
                deadline: deadline,
                connectionDeadline: deadline,
                cancellation: cancellation
            )
        } catch {
            throw MCPProtocolError.taskUnavailable("Unable to read the task: \(error.localizedDescription)")
        }
        guard response.error == nil, let result = response.result,
              let job = decodeJobSummary(result),
              job.id == identity.jobID,
              job.libraryID == identity.libraryID else {
            throw MCPProtocolError.taskUnavailable(
                response.error?.message ?? "The task is not available in its originating library."
            )
        }
        return job
    }

    private func taskValue(
        _ job: AutomationJobSummary,
        resultType: String,
        identity: MCPTaskIdentity
    ) -> AutomationJSONValue {
        let status: String
        switch job.state {
        case .queued, .running, .checkpointed:
            status = "working"
        case .completed, .partialFailure, .failed:
            status = "completed"
        case .cancelled:
            status = "cancelled"
        }

        let createdAt = taskTimestamp(job.createdAt)
        let lastUpdatedAt = taskTimestamp(job.finishedAt ?? job.startedAt ?? job.createdAt)
        var fields: [String: AutomationJSONValue] = [
            "resultType": .string(resultType),
            "taskId": .string(identity.rawValue),
            "status": .string(status),
            "createdAt": .string(createdAt),
            "lastUpdatedAt": .string(lastUpdatedAt),
            "ttlMs": .null,
            "pollIntervalMs": .number(1_500)
        ]

        let statusMessage: String? = {
            if let total = job.totalCount, total > 0 {
                let phase = job.currentPhase ?? job.checkpoint ?? "Working"
                return "\(phase) (\(job.completedCount)/\(total))"
            }
            return job.currentPhase ?? job.checkpoint ?? job.failures.first
        }()
        if let statusMessage {
            fields["statusMessage"] = .string(statusMessage)
        }

        if status == "completed" {
            let summary = encodeJSONValue(job) ?? .object([:])
            let error = job.state == .partialFailure || job.state == .failed
            let message = job.failures.first ?? jsonText(summary)
            fields["result"] = .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(message)])
                ]),
                "isError": .boolean(error),
                "structuredContent": summary
            ])
        }

        return .object(fields)
    }

    private func taskTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func encodeJSONValue<Value: Encodable>(_ value: Value) -> AutomationJSONValue? {
        guard let data = try? AutomationWireCoding.encoder().encode(value) else { return nil }
        return try? AutomationWireCoding.decoder().decode(AutomationJSONValue.self, from: data)
    }

    /// MCP tool arguments remain the domain payload. This small optional
    /// extension carries the shared App request context without smuggling
    /// transport metadata into every tool schema.
    private func automationContext(
        from value: AutomationJSONValue?
    ) throws -> AutomationRequestContext {
        guard let value else { return AutomationRequestContext(caller: "mcp") }
        guard case .object(let values) = value else {
            throw MCPProtocolError.invalidParams("tools/call context must be an object.")
        }

        let libraryID: UUID?
        if let raw = values["libraryID"] {
            guard case .string(let string) = raw,
                  let parsed = UUID(uuidString: string) else {
                throw MCPProtocolError.invalidParams("tools/call context.libraryID must be a UUID string.")
            }
            libraryID = parsed
        } else {
            libraryID = nil
        }

        let idempotencyKey: String?
        if let raw = values["idempotencyKey"] {
            guard case .string(let string) = raw, !string.isEmpty else {
                throw MCPProtocolError.invalidParams("tools/call context.idempotencyKey must be a non-empty string.")
            }
            idempotencyKey = string
        } else {
            idempotencyKey = nil
        }

        let deadline: Date?
        if let raw = values["deadline"] {
            guard case .string(let string) = raw,
                  let parsed = ISO8601DateFormatter().date(from: string) else {
                throw MCPProtocolError.invalidParams("tools/call context.deadline must be an ISO-8601 string.")
            }
            deadline = parsed
        } else {
            deadline = nil
        }
        return AutomationRequestContext(
            libraryID: libraryID,
            idempotencyKey: idempotencyKey,
            deadline: deadline,
            caller: "mcp"
        )
    }

    private func toolValue(_ descriptor: AutomationToolDescriptor, modern: Bool) -> AutomationJSONValue {
        var values: [String: AutomationJSONValue] = [
            "name": .string(descriptor.name),
            "title": .string(descriptor.title),
            "description": .string(descriptor.description),
            "inputSchema": descriptor.inputSchema,
            "annotations": .object([
                "readOnlyHint": .boolean(descriptor.readOnly),
                "destructiveHint": .boolean(descriptor.risk == .high),
                "openWorldHint": .boolean(false),
                "x-kmgccc-requires-confirmation": .boolean(descriptor.requiresConfirmation),
                "x-kmgccc-risk": .string(descriptor.risk.rawValue),
                "x-kmgccc-scopes": .array(descriptor.scopes.map { .string($0.rawValue) }),
                "x-kmgccc-supports-dry-run": .boolean(descriptor.supportsDryRun),
                "x-kmgccc-supports-jobs": .boolean(descriptor.supportsJobs),
                "x-kmgccc-supports-mcp-tasks": .boolean(descriptor.supportsTasks)
            ]),
        ]
        if modern {
            values["execution"] = .object([
                "taskSupport": .string(modern && descriptor.supportsTasks ? "optional" : "forbidden")
            ])
        }
        return .object(values)
    }

    private func capabilitiesValue(modern: Bool) -> AutomationJSONValue {
        var capabilities: [String: AutomationJSONValue] = [
            "tools": .object(["listChanged": .boolean(false)]),
            "resources": .object([
                "subscribe": .boolean(modern),
                "listChanged": .boolean(false)
            ]),
            "prompts": .object(["listChanged": .boolean(false)])
        ]
        if modern {
            capabilities["extensions"] = .object([
                "io.modelcontextprotocol/tasks": .object([:])
            ])
        }
        return .object(capabilities)
    }

    private var serverInfoValue: AutomationJSONValue {
        .object([
            "name": .string("kmgccc_player"),
            "version": .string(
                ProcessInfo.processInfo.environment["KMGCCC_PLAYER_APP_VERSION"]
                    ?? "development"
            )
        ])
    }

    private func makeClient(
        allowLaunch: Bool = true,
        timeout: TimeInterval? = nil,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationIPCClient {
        let clientTimeout = max(0.000_001, timeout ?? options.timeout)
        let socketExists = FileManager.default.fileExists(atPath: options.socketPath)
        let isCustomSocket = options.socketPath != AutomationToolDefaults.socketPath
        let secretURL = try AutomationIPCSecretStore.url(forSocketPath: options.socketPath)
        let secretExists = FileManager.default.fileExists(atPath: secretURL.path)
        if allowLaunch && !options.noLaunch && (!socketExists || !secretExists) && !isCustomSocket {
            launchAppIfNeeded()
        }
        let deadline = Date().addingTimeInterval(clientTimeout)
        while Date() < deadline {
            if cancellation?.isCancelled == true { throw CancellationError() }
            if FileManager.default.fileExists(atPath: secretURL.path) {
                let secret = try AutomationIPCSecretStore.load(
                    forSocketPath: options.socketPath
                )
                let configuration = try AutomationIPCConfiguration(
                    ioTimeout: clientTimeout,
                    sharedSecret: secret
                )
                return try AutomationIPCClient(
                    socketPath: options.socketPath,
                    configuration: configuration,
                    clientIDHint: "player-automation-mcp-stdio",
                    displayName: "kmgccc_player MCP stdio"
                )
            }
            Thread.sleep(forTimeInterval: min(0.1, max(0, deadline.timeIntervalSinceNow)))
        }
        throw AutomationIPCError.sharedSecretUnavailable
    }

    private func currentJobs(
        client: inout AutomationIPCClient?,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationJSONValue {
        let deadline = Date().addingTimeInterval(options.timeout)
        if client == nil {
            client = try makeClient(timeout: options.timeout, cancellation: cancellation)
        }
        let request = AutomationRequest(
            method: AutomationMethod.jobsList,
            params: nil,
            context: AutomationRequestContext(caller: "mcp-resource")
        )
        let response = try send(
            request,
            client: client!,
            deadline: deadline,
            connectionDeadline: deadline,
            cancellation: cancellation
        )
        guard response.error == nil else {
            throw MCPProtocolError.taskUnavailable(
                response.error?.message ?? "Library jobs are unavailable."
            )
        }
        return response.result ?? .object(["jobs": .array([])])
    }

    private func audioResourceMethod(_ uri: String) -> String {
        switch uri {
        case MCPJobResourceSubscriptions.audioStateURI: return AutomationMethod.audioGet
        case MCPJobResourceSubscriptions.dspStateURI: return AutomationMethod.dspState
        default: return AutomationMethod.dspPresetsList
        }
    }

    private func currentScriptResource(nodeID: UUID, client: inout AutomationIPCClient?,
                                       cancellation: AutomationIPCCancellationToken?) throws -> AutomationJSONValue {
        let deadline = Date().addingTimeInterval(options.timeout)
        if client == nil { client = try makeClient(timeout: options.timeout, cancellation: cancellation) }
        let request = AutomationRequest(method: AutomationMethod.dspScriptsGet,
            params: .object(["nodeID": .string(nodeID.uuidString)]),
            context: AutomationRequestContext(caller: "mcp-resource"))
        let response = try send(request, client: client!, deadline: deadline,
                                connectionDeadline: deadline, cancellation: cancellation)
        if let error = response.error { throw MCPProtocolError.invalidParams(error.message) }
        return response.result ?? .null
    }

    private func currentDSPResource(
        uri: String,
        client: inout AutomationIPCClient?,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationJSONValue {
        let deadline = Date().addingTimeInterval(options.timeout)
        if client == nil { client = try makeClient(timeout: options.timeout, cancellation: cancellation) }
        let request = AutomationRequest(
            method: audioResourceMethod(uri),
            params: nil,
            context: AutomationRequestContext(caller: "mcp-resource")
        )
        let response = try send(request, client: client!, deadline: deadline,
                                connectionDeadline: deadline, cancellation: cancellation)
        if let error = response.error { throw MCPProtocolError.invalidParams(error.message) }
        return response.result ?? .null
    }

    private func readDSPResourceForSubscription(uri: String) -> AutomationJSONValue? {
        guard uri == MCPJobResourceSubscriptions.audioStateURI
            || uri == MCPJobResourceSubscriptions.dspStateURI
            || uri == MCPJobResourceSubscriptions.dspPresetsURI else { return nil }
        do {
            let client = try makeClient(allowLaunch: false, timeout: min(max(options.timeout, 0.5), 2))
            let response = try client.send(AutomationRequest(
                method: audioResourceMethod(uri),
                params: nil, context: AutomationRequestContext(caller: "mcp-subscription")
            ))
            guard response.error == nil else { return nil }
            return response.result
        } catch { return nil }
    }

    private func readJobsForSubscription() -> AutomationJSONValue? {
        do {
            let timeout = min(max(options.timeout, 0.5), 2)
            let client = try makeClient(allowLaunch: false, timeout: timeout)
            let request = AutomationRequest(
                method: AutomationMethod.jobsList,
                params: nil,
                context: AutomationRequestContext(caller: "mcp-subscription")
            )
            let response = try client.send(request)
            guard response.error == nil else { return nil }
            return response.result ?? .object(["jobs": .array([])])
        } catch {
            return nil
        }
    }

    private func send(
        _ request: AutomationRequest,
        client: AutomationIPCClient,
        deadline: Date,
        connectionDeadline: Date,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationResponse {
        let connectionDeadline = min(connectionDeadline, deadline)
        var lastError: Error?
        var didAttemptLaunch = false
        while Date() < deadline {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            let remainingConnection = connectionDeadline.timeIntervalSinceNow
            guard remaining > 0, remainingConnection > 0 else {
                throw lastError ?? AutomationIPCRequestError.notSent(.timeout)
            }
            do {
                return try client.sendClassified(
                    request,
                    timeout: remaining,
                    connectionTimeout: remainingConnection,
                    cancellation: cancellation
                )
            } catch let error as AutomationIPCRequestError {
                guard error.isDefinitelyNotSent else { throw error }
                lastError = error
                if !didAttemptLaunch,
                   !options.noLaunch,
                   options.socketPath == AutomationToolDefaults.socketPath {
                    launchAppIfNeeded()
                    didAttemptLaunch = true
                }
                guard Date() < connectionDeadline else { throw error }
                Thread.sleep(forTimeInterval: min(0.1, max(0, connectionDeadline.timeIntervalSinceNow)))
            } catch {
                if cancellation?.isCancelled == true || error is CancellationError {
                    throw CancellationError()
                }
                throw error
            }
        }
        throw lastError ?? AutomationIPCError.timeout
    }

    private func makeToolResult(_ response: AutomationResponse) -> AutomationJSONValue {
        guard let error = response.error else {
            let result = response.result ?? .null
            var content: [AutomationJSONValue] = [
                .object([
                    "type": .string("text"),
                    "text": .string(jsonText(result))
                ])
            ]
            content.append(contentsOf: artworkImageContentBlocks(in: result))
            return .object([
                "content": .array(content),
                "isError": .boolean(false),
                "structuredContent": result.isObject
                    ? result
                    : .object(["value": result])
            ])
        }
        return makeToolExecutionError(
            code: error.code.rawValue,
            message: error.message,
            details: error.details
        )
    }

    /// MCP supports native image content blocks. Keep the JSON result as the
    /// authoritative structured payload (including imageBase64 for a later
    /// artwork.apply), and additionally expose each artwork candidate as an
    /// image block so multimodal Agents can inspect it without decoding JSON
    /// text themselves.
    private func artworkImageContentBlocks(
        in result: AutomationJSONValue
    ) -> [AutomationJSONValue] {
        guard case .object(let values) = result,
              case .array(let rawCandidates) = values["candidates"] else {
            return []
        }

        return rawCandidates.compactMap { rawCandidate in
            guard case .object(let candidate) = rawCandidate,
                  case .string(let imageBase64) = candidate["imageBase64"],
                  !imageBase64.isEmpty
            else {
                return nil
            }
            let mimeType: String
            if case .string(let value) = candidate["imageMIMEType"], !value.isEmpty {
                mimeType = value
            } else {
                mimeType = "image/jpeg"
            }
            let block: [String: AutomationJSONValue] = [
                "type": .string("image"),
                "data": .string(imageBase64),
                "mimeType": .string(mimeType)
            ]
            return .object(block)
        }
    }

    private func makeToolExecutionError(
        code: String,
        message: String,
        details: AutomationJSONValue? = nil
    ) -> AutomationJSONValue {
        var errorValue: [String: AutomationJSONValue] = [
            "code": .string(code),
            "message": .string(message)
        ]
        if let details {
            errorValue["details"] = details
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(message)
                ])
            ]),
            "isError": .boolean(true),
            "structuredContent": .object(["error": .object(errorValue)])
        ])
    }

    private func makeTransportToolError(_ error: Error) -> AutomationJSONValue {
        if let requestError = error as? AutomationIPCRequestError {
            let notSent = requestError.isDefinitelyNotSent
            return makeToolExecutionError(
                code: notSent ? "serverUnavailable" : "requestOutcomeUnknown",
                message: requestError.localizedDescription,
                details: .object([
                    "delivery": .string(notSent ? "notSent" : "unknown"),
                    "retryable": .boolean(notSent),
                    "action": .string(
                        notSent
                            ? "Start or reopen kmgccc_player, then retry."
                            : "Check the relevant job or state before retrying; do not repeat a mutation until its outcome is known."
                    )
                ])
            )
        }

        if let ipcError = error as? AutomationIPCError {
            return makeToolExecutionError(
                code: "serverUnavailable",
                message: ipcError.localizedDescription,
                details: .object([
                    "delivery": .string("notSent"),
                    "retryable": .boolean(true),
                    "action": .string("Start or reopen kmgccc_player, then retry.")
                ])
            )
        }

        return makeToolExecutionError(
            code: "serverUnavailable",
            message: error.localizedDescription
        )
    }

    private func success(
        id: MCPJSONRPCID?,
        result: AutomationJSONValue,
        modern: Bool = false
    ) -> MCPResponse {
        MCPResponse(
            id: id,
            result: result,
            error: nil,
            meta: modern
                ? .object(["io.modelcontextprotocol/serverInfo": serverInfoValue])
                : nil
        )
    }

    private func isObject(_ value: AutomationJSONValue?) -> Bool {
        guard let value else { return false }
        if case .object = value {
            return true
        }
        return false
    }

    private func jsonText(_ value: AutomationJSONValue) -> String {
        guard let data = try? AutomationWireCoding.encoder().encode(value) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func launchAppIfNeeded() {
        let appName = ProcessInfo.processInfo.environment["KMGCCC_PLAYER_APP"]
            ?? "kmgccc_player"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do {
            try process.run()
        } catch {
            let diagnostic = "could not launch \(appName): \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
    }
}

private extension AutomationJSONValue {
    var isObject: Bool {
        if case .object = self {
            return true
        }
        return false
    }
}
