import Darwin
import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

private enum AutomationCLIExitCode: Int32 {
    case success = 0
    case usage = 2
    case unavailable = 3
    case internalError = 4
    case authorization = 5
    case conflict = 6
    case interactionRequired = 7
}

private struct CLIOptions {
    var json = false
    var noLaunch = false
    var socketPath = AutomationToolDefaults.socketPath
    var timeout: TimeInterval = 10
}

private enum AutomationToolDefaults {
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["KMGCCC_AUTOMATION_SOCKET"],
           !override.isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("automation.sock", isDirectory: false)
            .path
    }
}

private struct AutomationCLI {
    func run(arguments: ArraySlice<String>) -> AutomationCLIExitCode {
        var args = Array(arguments)
        guard !args.isEmpty else {
            printUsage(to: FileHandle.standardError)
            return .usage
        }

        if args.first == "--help" || args.first == "-h" {
            printUsage(to: FileHandle.standardOutput)
            return .success
        }

        if args.first == "cli" {
            args.removeFirst()
        }
        guard let command = args.first else {
            printUsage(to: FileHandle.standardError)
            return .usage
        }
        args.removeFirst()

        var options = CLIOptions()
        do {
            try parseOptions(&args, into: &options)
        } catch {
            writeDiagnostic("usage error: \(error.localizedDescription)")
            return .usage
        }

        if command == "mcp-stdio" {
            writeDiagnostic("mcp-stdio is reserved for the Phase 6 MCP adapter; use CLI commands in Phase 1")
            if options.json {
                let response = AutomationResponse(
                    requestID: UUID(),
                    error: AutomationError(
                        code: .methodNotFound,
                        message: "MCP stdio is not implemented in this protocol spike."
                    )
                )
                writeJSON(response)
            }
            return .usage
        }

        let method: String
        switch command {
        case "system":
            guard let action = args.first else {
                writeDiagnostic("usage error: system requires ping or info")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "ping": method = AutomationMethod.systemPing
            case "info": method = AutomationMethod.systemInfo
            default:
                writeDiagnostic("usage error: unknown system action \(action)")
                return .usage
            }
        case "library":
            guard let action = args.first, action == "list" else {
                writeDiagnostic("usage error: library requires list")
                return .usage
            }
            args.removeFirst()
            method = AutomationMethod.libraryList
        default:
            writeDiagnostic("usage error: unknown command \(command)")
            return .usage
        }

        guard args.isEmpty else {
            writeDiagnostic("usage error: unexpected arguments: \(args.joined(separator: " "))")
            return .usage
        }

        let request = AutomationRequest(method: method)
        do {
            if !options.noLaunch {
                launchAppIfNeeded()
            }
            let sharedSecret = try loadSharedSecret(
                forSocketPath: options.socketPath,
                waitForCreation: !options.noLaunch,
                timeout: options.timeout
            )
            let configuration = try AutomationIPCConfiguration(
                ioTimeout: options.timeout,
                sharedSecret: sharedSecret
            )
            let client = try AutomationIPCClient(
                socketPath: options.socketPath,
                configuration: configuration
            )
            let response = try send(
                request,
                client: client,
                noLaunch: true,
                timeout: options.timeout
            )
            if options.json {
                writeJSON(response)
            } else {
                renderHuman(response, method: method)
            }
            return exitCode(for: response)
        } catch let error as AutomationIPCError {
            if options.json {
                let response = AutomationResponse(
                    requestID: request.requestID,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: error.localizedDescription,
                        retryable: true
                    )
                )
                writeJSON(response)
            }
            writeDiagnostic(error.localizedDescription)
            return .unavailable
        } catch {
            if options.json {
                let response = AutomationResponse(
                    requestID: request.requestID,
                    error: AutomationError(
                        code: .internalError,
                        message: error.localizedDescription
                    )
                )
                writeJSON(response)
            }
            writeDiagnostic(error.localizedDescription)
            return .internalError
        }
    }

    private func loadSharedSecret(
        forSocketPath socketPath: String,
        waitForCreation: Bool,
        timeout: TimeInterval
    ) throws -> Data {
        let secretURL = try AutomationIPCSecretStore.url(forSocketPath: socketPath)
        guard waitForCreation else {
            return try AutomationIPCSecretStore.load(forSocketPath: socketPath)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: secretURL.path) {
                return try AutomationIPCSecretStore.load(forSocketPath: socketPath)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AutomationIPCError.sharedSecretUnavailable
    }

    private func exitCode(for response: AutomationResponse) -> AutomationCLIExitCode {
        guard let error = response.error else { return .success }
        switch error.code {
        case .unsupportedVersion, .invalidRequest, .methodNotFound:
            return .usage
        case .serverUnavailable, .libraryNotActive:
            return .unavailable
        case .authorizationRequired:
            return .authorization
        case .conflict:
            return .conflict
        case .interactionRequired:
            return .interactionRequired
        case .internalError:
            return .internalError
        }
    }

    private func send(
        _ request: AutomationRequest,
        client: AutomationIPCClient,
        noLaunch: Bool,
        timeout: TimeInterval
    ) throws -> AutomationResponse {
        if !noLaunch {
            launchAppIfNeeded()
        }
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

    private func launchAppIfNeeded() {
        let appName = ProcessInfo.processInfo.environment["KMGCCC_PLAYER_APP"] ?? "kmgccc_player"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do {
            try process.run()
        } catch {
            writeDiagnostic("could not launch \(appName): \(error.localizedDescription)")
        }
    }

    private func parseOptions(_ args: inout [String], into options: inout CLIOptions) throws {
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                options.json = true
                args.remove(at: index)
            case "--no-launch":
                options.noLaunch = true
                args.remove(at: index)
            case "--socket":
                guard index + 1 < args.count else { throw CLIError.missingValue("--socket") }
                options.socketPath = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--timeout":
                guard index + 1 < args.count,
                      let timeout = TimeInterval(args[index + 1]),
                      timeout.isFinite,
                      timeout > 0,
                      timeout <= 120 else {
                    throw CLIError.invalidValue("--timeout")
                }
                options.timeout = timeout
                args.removeSubrange(index...(index + 1))
            case "--help", "-h":
                printUsage(to: FileHandle.standardOutput)
                exit(AutomationCLIExitCode.success.rawValue)
            default:
                index += 1
            }
        }
    }

    private func renderHuman(_ response: AutomationResponse, method: String) {
        if let error = response.error {
            writeDiagnostic("\(error.code.rawValue): \(error.message)")
            return
        }
        guard let result = response.result else {
            print("\(method): ok")
            return
        }
        switch result {
        case .object(let values):
            for key in values.keys.sorted() {
                print("\(key): \(render(value: values[key]!))")
            }
        default:
            print(render(value: result))
        }
    }

    private func render(value: AutomationJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .boolean(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .string(let value): return value
        case .array(let values): return "[\(values.map(render(value:)).joined(separator: ", "))]"
        case .object(let values):
            return "{\(values.keys.sorted().map { "\($0): \(render(value: values[$0]!))" }.joined(separator: ", "))}"
        }
    }

    private func printUsage(to handle: FileHandle) {
        let usage = """
        player-automation [cli] <command> [options]

        Commands:
          system ping             Check the App automation socket
          system info             Read protocol and capability information
          library list            List registered libraries and active ID

        Options:
          --json                  Emit one versioned JSON response on stdout
          --no-launch             Do not ask LaunchServices to start the App
          --socket <path>         Override the per-user AF_UNIX socket path
          --timeout <seconds>     Bound connection and launch wait (default 10)
          --help                  Show this help

        mcp-stdio is reserved for the later MCP compatibility adapter.
        """
        if let data = usage.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T) {
        do {
            let data = try AutomationWireCoding.encoder().encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            writeDiagnostic("failed to encode JSON: \(error.localizedDescription)")
        }
    }

    private func writeDiagnostic(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private enum CLIError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option): return "missing value for \(option)"
        case .invalidValue(let option): return "invalid value for \(option)"
        }
    }
}

exit(AutomationCLI().run(arguments: CommandLine.arguments.dropFirst()).rawValue)
