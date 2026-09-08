import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

private enum MCPProtocolVersion {
    static let current = "2026-07-28"
    static let legacy = "2025-11-25"
    static let supported = [current, legacy]
    static let handshakeSupported = [legacy]
}

private enum MCPJSONRPCID: Codable, Equatable {
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
}

private struct MCPRequest: Decodable {
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

private struct MCPConnectionState {
    enum Phase: Equatable {
        case undecided
        case legacyAwaitingInitialize
        case legacyAwaitingInitializedNotification
        case legacyReady
        case modernStateless
    }

    var phase: Phase = .undecided
    var protocolVersion: String?
}

private enum MCPProtocolError: Error, LocalizedError {
    case invalidRequest
    case invalidParams(String)
    case methodNotFound(String)
    case notInitialized
    case alreadyInitialized

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
        }
    }
}

struct AutomationMCPStdioOptions {
    let socketPath: String
    let noLaunch: Bool
    let timeout: TimeInterval
}

struct AutomationMCPStdioServer {
    let options: AutomationMCPStdioOptions

    func run() -> Int32 {
        var client: AutomationIPCClient?
        var state = MCPConnectionState()
        while let line = readLine(strippingNewline: true) {
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
                if let response = try handle(request, client: &client, state: &state) {
                    write(response)
                }
            } catch let error as MCPProtocolError {
                if isNotification { continue }
                write(
                    MCPResponse(
                        id: requestID,
                        result: nil,
                        error: MCPError(
                            code: error.code,
                            message: error.localizedDescription,
                            data: nil
                        )
                    )
                )
            } catch {
                if isNotification { continue }
                write(
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
        return 0
    }

    private func handle(
        _ request: MCPRequest,
        client: inout AutomationIPCClient?,
        state: inout MCPConnectionState
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
                result: toolsListResult(),
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
            let idempotencyKey = suppliedContext.idempotencyKey
                ?? (AutomationToolCatalog.descriptor(for: toolName)?.readOnly == false
                    ? "mcp:\(requestID.uuidString)"
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
                if client == nil {
                    client = try makeClient()
                }
                let response = try send(
                    automationRequest,
                    client: client!,
                    timeout: options.timeout
                )
                toolResult = makeToolResult(response)
            } catch {
                toolResult = makeToolExecutionError(
                    code: "serverUnavailable",
                    message: error.localizedDescription
                )
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
                result: try resourceReadResult(uri: uri),
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
            "capabilities": capabilitiesValue,
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
            "capabilities": capabilitiesValue,
            "serverInfo": serverInfoValue,
            "instructions": .string(
                AutomationDocumentation.agentBehaviorGuide
            )
        ])
    }

    private func toolsListResult() -> AutomationJSONValue {
        .object([
            "tools": .array(AutomationToolCatalog.all.map(toolValue))
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
                ])
            ])
        ])
    }

    private func resourceReadResult(uri: String) throws -> AutomationJSONValue {
        let text: String
        switch uri {
        case "kmgccc://capabilities":
            text = AutomationDocumentation.capabilityOverview
        case "kmgccc://agent-guide":
            text = AutomationDocumentation.agentBehaviorGuide
        default:
            throw MCPProtocolError.invalidParams("Unknown resource URI: \(uri)")
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("text/plain"),
                    "text": .string(text)
                ])
            ])
        ])
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

    private func toolValue(_ descriptor: AutomationToolDescriptor) -> AutomationJSONValue {
        .object([
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
            "execution": .object([
                "taskSupport": .string("forbidden")
            ])
        ])
    }

    private var capabilitiesValue: AutomationJSONValue {
        .object([
            "tools": .object(["listChanged": .boolean(false)]),
            "resources": .object([
                "subscribe": .boolean(false),
                "listChanged": .boolean(false)
            ])
        ])
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

    private func makeClient() throws -> AutomationIPCClient {
        if !options.noLaunch {
            launchAppIfNeeded()
        }
        let secretURL = try AutomationIPCSecretStore.url(forSocketPath: options.socketPath)
        let deadline = Date().addingTimeInterval(options.timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: secretURL.path) {
                let secret = try AutomationIPCSecretStore.load(
                    forSocketPath: options.socketPath
                )
                let configuration = try AutomationIPCConfiguration(
                    ioTimeout: options.timeout,
                    sharedSecret: secret
                )
                return try AutomationIPCClient(
                    socketPath: options.socketPath,
                    configuration: configuration,
                    clientIDHint: "player-automation-mcp-stdio",
                    displayName: "kmgccc_player MCP stdio"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AutomationIPCError.sharedSecretUnavailable
    }

    private func send(
        _ request: AutomationRequest,
        client: AutomationIPCClient,
        timeout: TimeInterval
    ) throws -> AutomationResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try client.send(request)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? AutomationIPCError.timeout
    }

    private func makeToolResult(_ response: AutomationResponse) -> AutomationJSONValue {
        guard let error = response.error else {
            let result = response.result ?? .null
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(jsonText(result))
                    ])
                ]),
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

    private func write(_ response: MCPResponse) {
        do {
            let data = try AutomationWireCoding.encoder().encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            let diagnostic = "MCP response encoding failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
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
