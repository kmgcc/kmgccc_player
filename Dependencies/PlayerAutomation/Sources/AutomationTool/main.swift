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
    var timeout: TimeInterval = AutomationToolDefaults.defaultConnectionTimeout
    var timeoutWasSet = false
    var libraryID: UUID?
    var query: String?
    var entityType: String?
    var playlistID: String?
    var trackTargetID: String?
    var artistID: String?
    var albumKey: String?
    var targetPlaylistID: String?
    var sourceID: String?
    var sourceMode: String?
    var relativePathPrefix: String?
    var ids: [String] = []
    var filterJSON: AutomationJSONValue?
    var sortJSON: AutomationJSONValue?
    var paramsJSON: AutomationJSONValue?
    var limit: Int?
    var offset: Int?
    var from: String?
    var to: String?
    var dimension: String?
    var expectedRevision: String?
    var idempotencyKey: String?
    /// Normal playlist/source mutations are direct. Callers can opt into an
    /// explicit preview with --dry-run; high-risk operations still require the
    /// App policy and a separate confirmation path.
    var dryRun = false
    var confirm = false
    var force = false
}

enum AutomationToolDefaults {
    static let defaultConnectionTimeout: TimeInterval = 10
    static let maximumTimeout: TimeInterval = 120

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

    static func requestTimeout(
        for request: AutomationRequest,
        configuredTimeout: TimeInterval,
        timeoutWasSet: Bool
    ) -> TimeInterval {
        let slowMethods: Set<String> = [
            AutomationMethod.libraryCreate,
            AutomationMethod.libraryOpen,
            AutomationMethod.librarySwitch,
            "lyrics.search",
            "lyrics.candidates",
            "artwork.search",
            "metadata.search",
            "storage.validate",
            "diagnostics.health"
        ]
        let waitsForInteraction = AutomationToolCatalog.descriptor(for: request.method)?.requiresConfirmation == true
            || request.method == AutomationMethod.sourceCreate
            || request.method == AutomationMethod.operationsBatch
        var budget = !timeoutWasSet && (slowMethods.contains(request.method) || waitsForInteraction)
            ? maximumTimeout
            : configuredTimeout

        if ["jobs.wait", AutomationMethod.dspWait].contains(request.method), !timeoutWasSet {
            let waitSeconds: TimeInterval
            if case .object(let parameters) = request.params,
               case .number(let timeoutMs) = parameters["timeoutMs"],
               timeoutMs.isFinite,
               timeoutMs > 0 {
                waitSeconds = timeoutMs / 1_000
            } else {
                waitSeconds = 20
            }
            budget = max(budget, waitSeconds + 5)
        }

        return min(max(budget, 0.000_001), maximumTimeout)
    }

    static func requestDeadline(
        for request: AutomationRequest,
        configuredTimeout: TimeInterval,
        timeoutWasSet: Bool,
        now: Date = Date()
    ) -> Date {
        let transportDeadline = now.addingTimeInterval(
            requestTimeout(
                for: request,
                configuredTimeout: configuredTimeout,
                timeoutWasSet: timeoutWasSet
            )
        )
        return min(transportDeadline, request.context.deadline ?? transportDeadline)
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
            if args.first == "--help" || args.first == "-h" {
                printUsage(to: FileHandle.standardOutput)
                return .success
            }
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
            guard args.isEmpty else {
                writeDiagnostic("usage error: mcp-stdio does not accept positional arguments")
                return .usage
            }
            let mcpExitCode = AutomationMCPStdioServer(
                options: AutomationMCPStdioOptions(
                    socketPath: options.socketPath,
                    noLaunch: options.noLaunch,
                    timeout: options.timeout,
                    timeoutWasSet: options.timeoutWasSet
                )
            ).run()
            return AutomationCLIExitCode(rawValue: mcpExitCode) ?? .internalError
        }

        let method: String
        var params: AutomationJSONValue?
        switch command {
        case "automation":
            guard let action = args.first else {
                writeDiagnostic("usage error: automation requires capabilities, scopes or call")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "capabilities":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: automation capabilities does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.automationCapabilities
                params = nil
            case "scopes":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: automation scopes does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.automationScopes
                params = nil
            case "call":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: automation call requires exactly one method name")
                    return .usage
                }
                method = args.removeFirst()
                params = options.paramsJSON
            default:
                writeDiagnostic("usage error: unknown automation action \(action)")
                return .usage
            }
        case "system":
            guard let action = args.first else {
                writeDiagnostic("usage error: system requires ping or info")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "ping":
                method = AutomationMethod.systemPing
            case "info":
                method = AutomationMethod.systemInfo
            default:
                writeDiagnostic("usage error: unknown system action \(action)")
                return .usage
            }
            guard args.isEmpty else {
                writeDiagnostic("usage error: system action does not accept positional arguments")
                return .usage
            }
            params = nil
        case "library":
            guard let action = args.first else {
                writeDiagnostic("usage error: library requires list, get, tracks, stats, report, bundle-export, selection-list, selection-create, selection-get, selection-delete, import, create, open, switch, rename, relocate or remove")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "list":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: library list does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.libraryList
                params = nil
            case "get":
                guard args.count == 1 else { writeDiagnostic("usage error: library get requires one library ID"); return .usage }
                method = AutomationMethod.libraryGet
                params = .object(["libraryID": .string(args[0])])
            case "tracks":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: library tracks uses named options only")
                    return .usage
                }
                if let paramsJSON = options.paramsJSON {
                    guard case .object = paramsJSON else {
                        writeDiagnostic("usage error: library tracks --params-json must be an object")
                        return .usage
                    }
                }
                method = AutomationMethod.libraryTracks
                params = libraryTracksParameters(from: options)
            case "stats":
                guard args.isEmpty else { writeDiagnostic("usage error: library stats does not accept positional arguments"); return .usage }
                method = AutomationMethod.libraryStats
                params = nil
            case "report":
                guard args.isEmpty else { writeDiagnostic("usage error: library report uses named options only"); return .usage }
                var values: [String: AutomationJSONValue] = [
                    "limit": .number(Double(options.limit ?? 100)),
                    "offset": .number(Double(options.offset ?? 0))
                ]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: library report --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.libraryReport
                params = .object(values)
            case "bundle-export":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: library bundle-export does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.libraryBundleExport
                params = .object([
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            case "selection-list":
                guard args.isEmpty else { writeDiagnostic("usage error: library selection-list does not accept positional arguments"); return .usage }
                method = AutomationMethod.librarySelectionList
                params = nil
            case "selection-create":
                guard args.count <= 10_000 else {
                    writeDiagnostic("usage error: library selection-create accepts at most 10000 Track IDs")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: library selection-create --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                if args.isEmpty {
                    guard values["filter"] != nil, values["trackIDs"] == nil else {
                        writeDiagnostic("usage error: library selection-create requires Track IDs or --params-json with a filter")
                        return .usage
                    }
                } else {
                    guard values["filter"] == nil, values["trackIDs"] == nil else {
                        writeDiagnostic("usage error: pass Track IDs or a filter, not both")
                        return .usage
                    }
                    values["trackIDs"] = .array(args.map { .string($0) })
                }
                values["dryRun"] = .boolean(options.dryRun)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.librarySelectionCreate
                params = .object(values)
            case "selection-get":
                guard args.count == 1 else { writeDiagnostic("usage error: library selection-get requires one selection ID"); return .usage }
                method = AutomationMethod.librarySelectionGet
                params = .object(["selectionID": .string(args[0])])
            case "selection-delete":
                guard args.count == 1 else { writeDiagnostic("usage error: library selection-delete requires one selection ID"); return .usage }
                method = AutomationMethod.librarySelectionDelete
                params = .object([
                    "selectionID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "import":
                guard !args.isEmpty else {
                    writeDiagnostic("usage error: library import requires file or folder paths")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "filePaths": .array(args.map { .string($0) }),
                    "dryRun": .boolean(options.dryRun)
                ]
                if let playlistID = options.targetPlaylistID ?? options.playlistID {
                    values["targetPlaylistID"] = .string(playlistID)
                }
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: library import --params-json requires an object")
                        return .usage
                    }
                    values.merge(extra) { existing, _ in existing }
                }
                method = AutomationMethod.libraryImport
                params = .object(values)
            case "create":
                guard args.count == 2 || args.count == 3 else {
                    writeDiagnostic("usage error: library create requires mode, display name and optional parent path")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "mode": .string(args[0]),
                    "displayName": .string(args[1]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if args.count == 3 {
                    values["parentPath"] = .string(args[2])
                }
                method = AutomationMethod.libraryCreate
                params = .object(values)
            case "open":
                guard args.count <= 1 else {
                    writeDiagnostic("usage error: library open accepts an optional path hint")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if let path = args.first {
                    values["path"] = .string(path)
                }
                method = AutomationMethod.libraryOpen
                params = .object(values)
            case "switch":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: library switch requires exactly one library ID")
                    return .usage
                }
                method = AutomationMethod.librarySwitch
                params = .object([
                    "libraryID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            case "rename":
                guard args.count == 2 else {
                    writeDiagnostic("usage error: library rename requires a library ID and display name")
                    return .usage
                }
                method = AutomationMethod.libraryRename
                params = .object([
                    "libraryID": .string(args[0]),
                    "displayName": .string(args[1]),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "relocate":
                guard args.count == 1 || args.count == 2 else {
                    writeDiagnostic("usage error: library relocate requires a library ID and optional parent path")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "libraryID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if args.count == 2 {
                    values["parentPath"] = .string(args[1])
                }
                method = AutomationMethod.libraryRelocate
                params = .object(values)
            case "remove":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: library remove requires exactly one library ID")
                    return .usage
                }
                method = AutomationMethod.libraryRemove
                params = .object([
                    "libraryID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            default:
                writeDiagnostic("usage error: unknown library action \(action)")
                return .usage
            }
        case "playlist":
            guard let action = args.first else {
                writeDiagnostic("usage error: playlist requires list, get, create, rename, delete, add, add-selection, remove, replace, reorder or diff")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "list":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: playlist list does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.playlistList
                params = nil
            case "create":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: playlist create requires exactly one name")
                    return .usage
                }
                method = AutomationMethod.playlistCreate
                params = .object([
                    "name": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            case "get":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: playlist get requires exactly one playlist ID")
                    return .usage
                }
                method = AutomationMethod.playlistGet
                params = .object(["playlistID": .string(args[0])])
            case "diff":
                guard args.count >= 3 else { writeDiagnostic("usage error: playlist diff requires an operation and at least two playlist IDs"); return .usage }
                let operation = args.removeFirst()
                method = AutomationMethod.playlistDiff
                params = .object([
                    "operation": .string(operation),
                    "playlistIDs": .array(args.map { .string($0) }),
                    "limit": .number(Double(options.limit ?? 100)),
                    "offset": .number(Double(options.offset ?? 0))
                ])
            case "export":
                guard args.count == 1 else { writeDiagnostic("usage error: playlist export requires one playlist ID"); return .usage }
                method = AutomationMethod.playlistExport
                params = .object(["playlistID": .string(args[0])])
            case "import":
                guard args.count == 1, case .object(var values)? = options.paramsJSON else {
                    writeDiagnostic("usage error: playlist import requires a playlist ID and --params-json containing m3uText")
                    return .usage
                }
                values["playlistID"] = .string(args[0])
                values["dryRun"] = .boolean(options.dryRun)
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                method = AutomationMethod.playlistImport
                params = .object(values)
            case "rename":
                guard args.count >= 2 else {
                    writeDiagnostic("usage error: playlist rename requires an ID and a name")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "playlistID": .string(args[0]),
                    "name": .string(args[1]),
                    "dryRun": .boolean(options.dryRun)
                ]
                if args.count > 2 { values["description"] = .string(args.dropFirst(2).joined(separator: " ")) }
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                method = AutomationMethod.playlistRename
                params = .object(values)
            case "delete":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: playlist delete requires exactly one playlist ID")
                    return .usage
                }
                method = AutomationMethod.playlistDelete
                params = .object([
                    "id": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            case "replace", "reorder":
                guard args.count >= 1 else {
                    writeDiagnostic("usage error: playlist \(action) requires a playlist ID")
                    return .usage
                }
                let playlistID = args[0]
                let trackIDs = Array(args.dropFirst())
                var values: [String: AutomationJSONValue] = [
                    "playlistID": .string(playlistID),
                    "trackIDs": .array(trackIDs.map { .string($0) }),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                method = action == "replace" ? AutomationMethod.playlistReplaceTracks : AutomationMethod.playlistReorder
                params = .object(values)
            case "add", "remove":
                guard (options.playlistID != nil && !args.isEmpty) || args.count >= 2 else {
                    writeDiagnostic(
                        "usage error: playlist \(action) requires a playlist ID and at least one track ID"
                    )
                    return .usage
                }
                guard let playlistID = options.playlistID ?? args.first else {
                    writeDiagnostic("usage error: playlist ID is required")
                    return .usage
                }
                let trackIDs = options.playlistID == nil
                    ? Array(args.dropFirst())
                    : args
                guard !trackIDs.isEmpty else {
                    writeDiagnostic("usage error: at least one track ID is required")
                    return .usage
                }
                method = action == "add"
                    ? AutomationMethod.playlistAddTracks
                    : AutomationMethod.playlistRemoveTracks
                var values: [String: AutomationJSONValue] = [
                    "playlistID": .string(playlistID),
                    "trackIDs": .array(trackIDs.map { .string($0) }),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                params = .object(values)
            case "add-selection":
                guard args.count == 2 else {
                    writeDiagnostic("usage error: playlist add-selection requires a playlist ID and selection ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: playlist add-selection --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                values["playlistID"] = .string(args[0])
                values["selectionID"] = .string(args[1])
                values["dryRun"] = .boolean(options.dryRun)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.playlistAddSelection
                params = .object(values)
            default:
                writeDiagnostic("usage error: unknown playlist action \(action)")
                return .usage
            }
        case "source":
            guard let action = args.first else {
                writeDiagnostic("usage error: source requires list, get, config-export, config-import, rename, refresh, create, bind, exclude, include, watch, unwatch or remove")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "list":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: source list does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.sourceList
                params = nil
            case "get":
                guard args.count == 1 else { writeDiagnostic("usage error: source get requires one source ID"); return .usage }
                method = AutomationMethod.sourceGet
                params = .object(["sourceID": .string(args[0])])
            case "config-export":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: source config-export does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.sourceConfigExport
                params = nil
            case "config-import":
                guard args.isEmpty,
                      let paramsJSON = options.paramsJSON,
                      case .object(let suppliedValues) = paramsJSON,
                      suppliedValues["document"] != nil else {
                    writeDiagnostic("usage error: source config-import requires --params-json with a document object")
                    return .usage
                }
                var values = suppliedValues
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.sourceConfigImport
                params = .object(values)
            case "rename":
                guard args.count == 2 else { writeDiagnostic("usage error: source rename requires a source ID and display name"); return .usage }
                method = AutomationMethod.sourceRename
                params = .object([
                    "sourceID": .string(args[0]),
                    "displayName": .string(args[1]),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "refresh":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: source refresh requires exactly one source ID")
                    return .usage
                }
                method = AutomationMethod.sourceRefresh
                params = .object([
                    "sourceID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "create":
                guard args.isEmpty || args.count == 1 else {
                    writeDiagnostic("usage error: source create accepts an optional path")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "dryRun": .boolean(options.dryRun),
                    "mode": .string(options.sourceMode ?? "directory")
                ]
                if let path = args.first { values["path"] = .string(path) }
                if let playlistID = options.playlistID { values["playlistID"] = .string(playlistID) }
                method = AutomationMethod.sourceCreate
                params = .object(values)
            case "bind":
                guard args.count >= 2, args.count <= 3 else {
                    writeDiagnostic("usage error: source bind requires source ID, playlist ID and optional relative path")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "sourceID": .string(args[0]),
                    "playlistID": .string(args[1]),
                    "dryRun": .boolean(options.dryRun)
                ]
                if args.count == 3 { values["relativePath"] = .string(args[2]) }
                method = AutomationMethod.sourceBindPlaylist
                params = .object(values)
            case "exclude", "include":
                guard args.count == 2 else {
                    writeDiagnostic("usage error: source \(action) requires a source ID and relative path")
                    return .usage
                }
                method = AutomationMethod.sourceSetExcludedPath
                params = .object([
                    "sourceID": .string(args[0]),
                    "relativePath": .string(args[1]),
                    "excluded": .boolean(action == "exclude"),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "watch", "unwatch":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: source \(action) requires a source ID")
                    return .usage
                }
                method = AutomationMethod.sourceSetMonitorPolicy
                params = .object([
                    "sourceID": .string(args[0]),
                    "policy": .string(action == "watch" ? "on" : "off"),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "remove":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: source remove requires exactly one source ID")
                    return .usage
                }
                method = AutomationMethod.sourceRemove
                params = .object([
                    "id": .string(args[0]),
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ])
            default:
                writeDiagnostic("usage error: unknown source action \(action)")
                return .usage
            }
        case "files":
            guard let action = args.first, action == "reveal" || action == "export" else {
                writeDiagnostic("usage error: files supports reveal or export")
                return .usage
            }
            args.removeFirst()
            let maximum = action == "reveal" ? 50 : 500
            guard (1...maximum).contains(args.count) else {
                writeDiagnostic("usage error: files \(action) requires 1 to \(maximum) Track IDs")
                return .usage
            }
            if action == "export" && options.dryRun {
                writeDiagnostic("usage error: files export does not support --dry-run; it requires choosing an output folder")
                return .usage
            }
            method = action == "reveal" ? AutomationMethod.filesReveal : AutomationMethod.filesExport
            var values: [String: AutomationJSONValue] = [
                "trackIDs": .array(args.map(AutomationJSONValue.string))
            ]
            if action == "reveal" { values["dryRun"] = .boolean(options.dryRun) }
            params = .object(values)
        case "playback":
            guard let action = args.first else {
                writeDiagnostic("usage error: playback requires state, play, play-playlist, toggle, pause, next, previous, seek, volume or mode")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "state": method = AutomationMethod.playbackState; params = nil
            case "play":
                if args.isEmpty {
                    params = nil
                } else {
                    let trackIDs = args
                    args.removeAll()
                    params = .object(["trackIDs": .array(trackIDs.map { .string($0) })])
                }
                method = AutomationMethod.playbackPlay
            case "play-playlist":
                guard args.count == 1 || args.count == 2 else { writeDiagnostic("usage error: playback play-playlist requires a playlist ID and optional start index"); return .usage }
                let playlistID = args[0]
                let startIndex = args.count == 2 ? Int(args[1]) : (options.offset ?? 0)
                guard let startIndex, startIndex >= 0 else { writeDiagnostic("usage error: start index must be non-negative"); return .usage }
                method = AutomationMethod.playbackPlayPlaylist
                params = .object(["playlistID": .string(playlistID), "startIndex": .number(Double(startIndex))])
                args.removeAll()
            case "toggle": method = AutomationMethod.playbackToggle; params = nil
            case "pause": method = AutomationMethod.playbackPause; params = nil
            case "next": method = AutomationMethod.playbackNext; params = nil
            case "previous": method = AutomationMethod.playbackPrevious; params = nil
            case "seek":
                guard args.count == 1, let value = Double(args.removeFirst()) else { writeDiagnostic("usage error: playback seek requires seconds"); return .usage }
                method = AutomationMethod.playbackSeek; params = .object(["seconds": .number(value)])
            case "volume":
                guard args.count == 1, let value = Double(args.removeFirst()) else { writeDiagnostic("usage error: playback volume requires 0...1"); return .usage }
                method = AutomationMethod.playbackSetVolume; params = .object(["volume": .number(value)])
            case "mode":
                guard args.count == 1 else { writeDiagnostic("usage error: playback mode requires a mode"); return .usage }
                let rawMode = args.removeFirst()
                method = AutomationMethod.playbackSetMode; params = .object(["mode": .string(rawMode)])
            default: writeDiagnostic("usage error: unknown playback action \(action)"); return .usage
            }
            guard args.isEmpty else { writeDiagnostic("usage error: unexpected playback arguments"); return .usage }
        case "queue":
            guard let action = args.first else { writeDiagnostic("usage error: queue requires get, upcoming, replace, enqueue, enqueue-next, remove, reorder or clear"); return .usage }
            args.removeFirst()
            switch action {
            case "get": method = AutomationMethod.queueGet; params = nil
            case "upcoming":
                guard args.isEmpty else { writeDiagnostic("usage error: queue upcoming does not accept positional arguments"); return .usage }
                var values: [String: AutomationJSONValue] = [
                    "limit": .number(Double(options.limit ?? 100)),
                    "offset": .number(Double(options.offset ?? 0))
                ]
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                method = AutomationMethod.queueUpcoming
                params = .object(values)
            case "clear": method = AutomationMethod.queueClear; params = .object(["dryRun": .boolean(options.dryRun)])
            case "replace", "enqueue", "enqueue-next", "remove", "reorder":
                guard !args.isEmpty else {
                    writeDiagnostic("usage error: queue \(action) requires at least one track ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "trackIDs": .array(args.map { .string($0) }),
                    "dryRun": .boolean(options.dryRun)
                ]
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                switch action {
                case "replace": method = AutomationMethod.queueReplace
                case "enqueue": method = AutomationMethod.queueEnqueue
                case "enqueue-next": method = AutomationMethod.queueEnqueueNext
                case "remove": method = AutomationMethod.queueRemove
                default: method = AutomationMethod.queueReorder
                }
                params = .object(values)
            default: writeDiagnostic("usage error: unknown queue action \(action)"); return .usage
            }
        case "history":
            guard let action = args.first else { writeDiagnostic("usage error: history requires list, stats or clear"); return .usage }
            args.removeFirst()
            guard args.isEmpty else {
                writeDiagnostic("usage error: history action does not accept positional arguments")
                return .usage
            }
            switch action {
            case "list":
                if let paramsJSON = options.paramsJSON {
                    guard case .object = paramsJSON else {
                        writeDiagnostic("usage error: history list --params-json must be an object")
                        return .usage
                    }
                }
                method = AutomationMethod.historyList
                params = historyParameters(from: options)
            case "stats":
                var values: [String: AutomationJSONValue] = ["limit": .number(Double(options.limit ?? 20))]
                if let from = options.from { values["from"] = .string(from) }
                if let to = options.to { values["to"] = .string(to) }
                if let dimension = options.dimension { values["dimension"] = .string(dimension) }
                method = AutomationMethod.historyStats
                params = .object(values)
            case "clear":
                guard options.from == nil, options.to == nil else {
                    writeDiagnostic("usage error: history clear does not support --from or --to")
                    return .usage
                }
                method = AutomationMethod.historyClear
                params = .object(["dryRun": .boolean(options.dryRun), "confirm": .boolean(options.confirm)])
            default: writeDiagnostic("usage error: unknown history action \(action)"); return .usage
            }
        case "metadata":
            guard let action = args.first else { writeDiagnostic("usage error: metadata requires get, embedded-get, embedded-patch, export, import, search, apply-candidate or patch"); return .usage }
            args.removeFirst()
            switch action {
            case "get":
                let targets = entityTargetValues(from: options)
                guard options.entityType == nil
                    ? ((args.isEmpty && !targets.isEmpty) || (!args.isEmpty && targets.isEmpty))
                    : (args.isEmpty && targets.isEmpty) else {
                    writeDiagnostic("usage error: metadata get requires Track IDs, one entity target, or --entity-type")
                    return .usage
                }
                method = AutomationMethod.metadataGet
                if let entityType = options.entityType {
                    var values: [String: AutomationJSONValue] = ["entityType": .string(entityType)]
                    if let query = options.query { values["query"] = .string(query) }
                    if let limit = options.limit { values["limit"] = .number(Double(limit)) }
                    if let offset = options.offset { values["offset"] = .number(Double(offset)) }
                    params = .object(values)
                } else {
                    params = args.isEmpty
                        ? .object(targets)
                        : .object(["trackIDs": .array(args.map { .string($0) })])
                }
            case "embedded-get":
                guard !args.isEmpty, args.count <= 100,
                      entityTargetValues(from: options).isEmpty,
                      options.entityType == nil else {
                    writeDiagnostic("usage error: metadata embedded-get requires 1...100 Track IDs")
                    return .usage
                }
                method = AutomationMethod.metadataEmbeddedGet
                params = .object(["trackIDs": .array(args.map { .string($0) })])
            case "embedded-patch":
                guard !args.isEmpty, args.count <= 100,
                      entityTargetValues(from: options).isEmpty,
                      options.entityType == nil,
                      case .object(let supplied)? = options.paramsJSON,
                      case .object = supplied["fields"],
                      case .object = supplied["expectedRevisions"] else {
                    writeDiagnostic("usage error: metadata embedded-patch requires Track IDs and --params-file/--params-json with fields and expectedRevisions")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = supplied
                values["trackIDs"] = .array(args.map { .string($0) })
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                method = AutomationMethod.metadataEmbeddedPatch
                params = .object(values)
            case "export":
                guard options.entityType == nil,
                      options.trackTargetID == nil,
                      options.artistID == nil,
                      options.albumKey == nil,
                      options.playlistID == nil,
                      args.count <= 100,
                      options.limit.map({ (1...100).contains($0) }) ?? true,
                      args.isEmpty || (options.limit == nil && options.offset == nil) else {
                    writeDiagnostic("usage error: metadata export accepts up to 100 Track IDs or --limit/--offset")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if !args.isEmpty {
                    values["trackIDs"] = .array(args.map { .string($0) })
                }
                if let limit = options.limit { values["limit"] = .number(Double(limit)) }
                if let offset = options.offset { values["offset"] = .number(Double(offset)) }
                method = AutomationMethod.metadataExport
                params = .object(values)
            case "import":
                guard args.isEmpty,
                      options.entityType == nil,
                      entityTargetValues(from: options).isEmpty,
                      case .object(var values)? = options.paramsJSON,
                      values["document"] != nil else {
                    writeDiagnostic("usage error: metadata import requires --params-json/--params-file with a document object")
                    return .usage
                }
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.metadataImport
                params = .object(values)
            case "search":
                guard args.count == 1, entityTargetValues(from: options).isEmpty else {
                    writeDiagnostic("usage error: metadata search requires one Track ID")
                    return .usage
                }
                method = AutomationMethod.metadataSearch
                params = .object(["trackID": .string(args[0])])
            case "apply-candidate":
                guard args.count == 2, entityTargetValues(from: options).isEmpty else {
                    writeDiagnostic("usage error: metadata apply-candidate requires a Track ID and candidate ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "trackID": .string(args[0]),
                    "candidateID": .string(args[1]),
                    "dryRun": .boolean(options.dryRun)
                ]
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON,
                          Set(extra.keys).isSubset(of: ["overwriteExistingFields"]) else {
                        writeDiagnostic("usage error: metadata apply-candidate --params-json only accepts overwriteExistingFields")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                method = AutomationMethod.metadataApplyCandidate
                params = .object(values)
            case "patch":
                guard options.entityType == nil else {
                    writeDiagnostic("usage error: metadata patch does not accept --entity-type")
                    return .usage
                }
                guard let patchJSON = options.paramsJSON,
                      case .object = patchJSON else {
                    writeDiagnostic("usage error: metadata patch requires --params-json patch object")
                    return .usage
                }
                let targets = entityTargetValues(from: options)
                guard (args.isEmpty && !targets.isEmpty) || (!args.isEmpty && targets.isEmpty) else {
                    writeDiagnostic("usage error: metadata patch requires Track IDs or one entity target")
                    return .usage
                }
                var values = targets
                if !args.isEmpty { values["trackIDs"] = .array(args.map { .string($0) }) }
                values["patch"] = patchJSON
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.metadataPatch
                params = .object(values)
            default: writeDiagnostic("usage error: unknown metadata action \(action)"); return .usage
            }
        case "artwork":
            guard let action = args.first else {
                writeDiagnostic("usage error: artwork requires search, get, apply or apply-candidate")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "search":
                let targets = entityTargetValues(from: options)
                guard (args.count == 1 && targets.isEmpty) || (args.isEmpty && !targets.isEmpty) else {
                    writeDiagnostic("usage error: artwork search requires one Track ID or one entity target")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: artwork search --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                if let trackID = args.first {
                    values["trackID"] = .string(trackID)
                } else {
                    values.merge(targets) { _, incoming in incoming }
                }
                method = AutomationMethod.artworkSearch
                params = .object(values)
            case "get":
                let targets = entityTargetValues(from: options)
                guard (args.isEmpty && !targets.isEmpty) || (!args.isEmpty && targets.isEmpty) else {
                    writeDiagnostic("usage error: artwork get requires Track IDs or one entity target")
                    return .usage
                }
                method = AutomationMethod.artworkGet
                params = args.isEmpty
                    ? .object(targets)
                    : .object(["trackIDs": .array(args.map { .string($0) })])
            case "apply":
                let targets = entityTargetValues(from: options)
                guard (args.isEmpty && !targets.isEmpty) || (!args.isEmpty && targets.isEmpty) else {
                    writeDiagnostic("usage error: artwork apply requires Track IDs or one entity target")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: artwork apply --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                if !args.isEmpty {
                    values["trackIDs"] = .array(args.map { .string($0) })
                } else {
                    values.merge(targets) { _, incoming in incoming }
                }
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.artworkApply
                params = .object(values)
            case "apply-candidate":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: artwork apply-candidate requires one candidate ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: artwork apply-candidate --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                values["candidateID"] = .string(args[0])
                values["dryRun"] = .boolean(options.dryRun)
                values["confirm"] = .boolean(options.confirm)
                if let expectedRevision = options.expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                method = AutomationMethod.artworkApplyCandidate
                params = .object(values)
            default:
                writeDiagnostic("usage error: unknown artwork action \(action)")
                return .usage
            }
        case "lyrics":
            guard let action = args.first else { writeDiagnostic("usage error: lyrics requires get, search, candidates, compare, apply, clean or refresh"); return .usage }
            args.removeFirst()
            switch action {
            case "get":
                guard args.count == 1 else { writeDiagnostic("usage error: lyrics get requires one Track ID"); return .usage }
                method = AutomationMethod.lyricsGet
                params = .object(["trackID": .string(args[0])])
            case "clean":
                guard args.count == 1 else { writeDiagnostic("usage error: lyrics clean requires one Track ID"); return .usage }
                method = AutomationMethod.lyricsClean
                params = .object([
                    "trackID": .string(args[0]),
                    "dryRun": .boolean(options.dryRun)
                ])
            case "search", "candidates":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: lyrics \(action) requires one Track ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [:]
                if let paramsJSON = options.paramsJSON {
                    guard case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: lyrics \(action) --params-json must be an object")
                        return .usage
                    }
                    values.merge(extra) { _, incoming in incoming }
                }
                values["trackID"] = .string(args[0])
                if action == "candidates", options.force {
                    values["refresh"] = .boolean(true)
                }
                method = action == "search"
                    ? AutomationMethod.lyricsSearch
                    : AutomationMethod.lyricsCandidates
                params = .object(values)
            case "compare", "apply":
                guard args.count == 1,
                      let paramsJSON = options.paramsJSON,
                      case .object(let values) = paramsJSON else {
                    writeDiagnostic("usage error: lyrics \(action) requires one Track ID and --params-json object")
                    return .usage
                }
                var merged = values
                merged["trackID"] = .string(args[0])
                if action == "apply" {
                    merged["dryRun"] = .boolean(options.dryRun)
                    if options.force { merged["force"] = .boolean(true) }
                }
                method = action == "compare"
                    ? AutomationMethod.lyricsCompare
                    : AutomationMethod.lyricsApply
                params = .object(merged)
            case "refresh":
                guard !args.isEmpty else { writeDiagnostic("usage error: lyrics refresh requires Track IDs"); return .usage }
                method = AutomationMethod.lyricsRefresh
                params = .object([
                    "trackIDs": .array(args.map { .string($0) }),
                    "force": .boolean(options.force),
                    "dryRun": .boolean(options.dryRun)
                ])
            default: writeDiagnostic("usage error: unknown lyrics action \(action)"); return .usage
            }
        case "jobs":
            guard let action = args.first else { writeDiagnostic("usage error: jobs requires list, get, wait, cancel or retry"); return .usage }
            args.removeFirst()
            switch action {
            case "list": method = AutomationMethod.jobsList; params = nil
            case "get", "wait", "cancel", "retry":
                guard args.count == 1 else { writeDiagnostic("usage error: jobs \(action) requires a job ID"); return .usage }
                method = action == "get"
                    ? AutomationMethod.jobsGet
                    : (action == "wait"
                        ? AutomationMethod.jobsWait
                        : (action == "cancel" ? AutomationMethod.jobsCancel : AutomationMethod.jobsRetry))
                var values: [String: AutomationJSONValue] = ["jobID": .string(args[0])]
                if let paramsJSON = options.paramsJSON {
                    guard action == "retry" || action == "wait",
                          case .object(let extra) = paramsJSON else {
                        writeDiagnostic("usage error: --params-json is supported for jobs wait or retry and must be an object")
                        return .usage
                    }
                    values.merge(extra) { existing, _ in existing }
                }
                params = .object(values)
            default: writeDiagnostic("usage error: unknown jobs action \(action)"); return .usage
            }
        case "diagnostics":
            guard args.count == 1, args[0] == "health" else { writeDiagnostic("usage error: diagnostics health [--params-json <object>]"); return .usage }
            method = AutomationMethod.diagnosticsHealth
            if let paramsJSON = options.paramsJSON {
                guard case .object = paramsJSON else {
                    writeDiagnostic("usage error: diagnostics health --params-json requires an object")
                    return .usage
                }
                params = paramsJSON
            } else {
                params = nil
            }
        case "settings":
            guard let action = args.first else {
                writeDiagnostic("usage error: settings requires schema, get, patch, validate or reset")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "schema":
                guard args.isEmpty else { writeDiagnostic("usage error: settings schema takes no arguments"); return .usage }
                method = AutomationMethod.settingsSchema
                params = nil
            case "get":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: settings get does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.settingsGet
                params = nil
            case "patch":
                guard args.isEmpty, let values = options.paramsJSON else {
                    writeDiagnostic("usage error: settings patch requires --params-json values object")
                    return .usage
                }
                method = AutomationMethod.settingsPatch
                var parameters: [String: AutomationJSONValue] = [
                    "values": values,
                    "dryRun": .boolean(options.dryRun),
                    "confirm": .boolean(options.confirm)
                ]
                if let expectedRevision = options.expectedRevision {
                    parameters["expectedRevision"] = .string(expectedRevision)
                }
                params = .object(parameters)
            case "validate":
                guard args.isEmpty, let values = options.paramsJSON else {
                    writeDiagnostic("usage error: settings validate requires --params-json values object")
                    return .usage
                }
                method = AutomationMethod.settingsValidate
                params = .object(["values": values])
            case "reset":
                guard args.isEmpty else { writeDiagnostic("usage error: settings reset takes no positional arguments"); return .usage }
                method = AutomationMethod.settingsReset
                var values: [String: AutomationJSONValue] = ["dryRun": .boolean(options.dryRun)]
                if let revision = options.expectedRevision { values["expectedRevision"] = .string(revision) }
                params = .object(values)
            default:
                writeDiagnostic("usage error: unknown settings action \(action)")
                return .usage
            }
        case "dsp":
            guard let action = args.first else {
                writeDiagnostic("usage error: dsp requires schema, state, validate, patch, wait, presets, scripts, nodes or errors")
                return .usage
            }
            args.removeFirst()
            if ["presets", "errors", "scripts", "nodes"].contains(action) {
                guard let operation = args.first else {
                    writeDiagnostic("usage error: dsp \(action) requires an operation")
                    return .usage
                }
                args.removeFirst()
                method = "dsp.\(action).\(operation)"
            } else {
                method = "dsp.\(action)"
            }
            guard args.isEmpty, let descriptor = AutomationToolCatalog.descriptor(for: method) else {
                writeDiagnostic("usage error: unknown DSP operation or unexpected positional arguments")
                return .usage
            }
            var values: [String: AutomationJSONValue] = [:]
            if let supplied = options.paramsJSON {
                guard case .object(let object) = supplied else {
                    writeDiagnostic("usage error: --params-json must contain a complete object")
                    return .usage
                }
                values = object
            }
            if options.dryRun {
                guard descriptor.supportsDryRun else {
                    writeDiagnostic("usage error: this DSP operation does not support --dry-run")
                    return .usage
                }
                values["dryRun"] = .boolean(true)
            }
            if let revision = options.expectedRevision { values["expectedRevision"] = .string(revision) }
            params = values.isEmpty ? nil : .object(values)
        case "audio":
            guard let action = args.first else { writeDiagnostic("usage error: audio requires get or patch"); return .usage }
            args.removeFirst()
            switch action {
            case "get":
                guard args.isEmpty else { writeDiagnostic("usage error: audio get takes no arguments"); return .usage }
                method = AutomationMethod.audioGet
                params = nil
            case "loudness":
                guard let operation = args.first, args.count == 1, ["get", "analyze"].contains(operation) else {
                    writeDiagnostic("usage error: audio loudness requires get or analyze"); return .usage
                }
                method = operation == "get" ? AutomationMethod.audioLoudnessGet : AutomationMethod.audioLoudnessAnalyze
                var parameters: [String: AutomationJSONValue] = [:]
                if let raw = options.paramsJSON {
                    guard case .object(let values) = raw else { writeDiagnostic("usage error: --params-json requires an object"); return .usage }
                    parameters = values
                }
                if options.dryRun { parameters["dryRun"] = .boolean(true) }
                params = parameters.isEmpty ? nil : .object(parameters)
            case "patch":
                guard args.isEmpty, let values = options.paramsJSON else { writeDiagnostic("usage error: audio patch requires --params-json values object"); return .usage }
                method = AutomationMethod.audioPatch
                var parameters: [String: AutomationJSONValue] = ["values": values, "dryRun": .boolean(options.dryRun)]
                if let revision = options.expectedRevision { parameters["expectedRevision"] = .string(revision) }
                params = .object(parameters)
            default:
                writeDiagnostic("usage error: unknown audio action \(action)")
                return .usage
            }
        case "storage":
            guard let action = args.first else {
                writeDiagnostic("usage error: storage requires inspect, validate, orphans, backup, diff, reload or repair")
                return .usage
            }
            args.removeFirst()
            switch action {
            case "inspect":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage inspect does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageInspect
                params = nil
            case "validate":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage validate does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageValidate
                if let paramsJSON = options.paramsJSON {
                    guard case .object = paramsJSON else {
                        writeDiagnostic("usage error: storage validate --params-json requires an object")
                        return .usage
                    }
                    params = paramsJSON
                } else {
                    params = nil
                }
            case "orphans":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage orphans does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageOrphans
                params = nil
            case "backup":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage backup does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageBackup
                params = nil
            case "diff":
                guard args.count == 1 else {
                    writeDiagnostic("usage error: storage diff requires exactly one backup path")
                    return .usage
                }
                method = AutomationMethod.storageDiff
                params = .object(["backupPath": .string(args[0])])
            case "reload":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage reload does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageReload
                params = nil
            case "repair":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: storage repair does not accept positional arguments")
                    return .usage
                }
                method = AutomationMethod.storageRepair
                params = .object(["dryRun": .boolean(options.dryRun)])
            default:
                writeDiagnostic("usage error: unknown storage action \(action)")
                return .usage
            }
        default:
            writeDiagnostic("usage error: unknown command \(command)")
            return .usage
        }

        let requestID = UUID()
        let automaticIdempotencyKey: String?
        if let idempotencyKey = options.idempotencyKey {
            automaticIdempotencyKey = idempotencyKey
        } else if AutomationToolCatalog.descriptor(for: method)?.readOnly == false {
            // Safe reconnect attempts can happen before request delivery.
            // Scope this key to one invocation so separate CLI calls do not
            // accidentally share a mutation result.
            automaticIdempotencyKey = "cli:\(requestID.uuidString)"
        } else {
            automaticIdempotencyKey = nil
        }
        let request = AutomationRequest(
            method: method,
            params: params,
            context: AutomationRequestContext(
                libraryID: options.libraryID,
                idempotencyKey: automaticIdempotencyKey,
                caller: "cli"
            ),
            requestID: requestID
        )
        do {
            let connectionDeadline = Date().addingTimeInterval(options.timeout)
            let socketExists = FileManager.default.fileExists(atPath: options.socketPath)
            let isCustomSocket = options.socketPath != AutomationToolDefaults.socketPath
            let secretURL = try AutomationIPCSecretStore.url(forSocketPath: options.socketPath)
            let secretExists = FileManager.default.fileExists(atPath: secretURL.path)
            if !options.noLaunch && (!socketExists || !secretExists) && !isCustomSocket {
                launchAppIfNeeded()
            }
            let sharedSecret = try loadSharedSecret(
                forSocketPath: options.socketPath,
                waitForCreation: !options.noLaunch,
                timeout: max(0.000_001, connectionDeadline.timeIntervalSinceNow)
            )
            let configuration = try AutomationIPCConfiguration(
                ioTimeout: options.timeout,
                sharedSecret: sharedSecret
            )
            let client = try AutomationIPCClient(
                socketPath: options.socketPath,
                configuration: configuration
            )
            let requestDeadline = AutomationToolDefaults.requestDeadline(
                for: request,
                configuredTimeout: options.timeout,
                timeoutWasSet: options.timeoutWasSet
            )
            let response = try send(
                request,
                client: client,
                noLaunch: options.noLaunch,
                deadline: requestDeadline,
                connectionDeadline: min(connectionDeadline, requestDeadline),
                canLaunch: !isCustomSocket
            )
            if options.json {
                writeJSON(response)
            } else {
                renderHuman(response, method: method)
            }
            return exitCode(for: response)
        } catch let error as AutomationIPCRequestError {
            let retryable = error.isDefinitelyNotSent
            let response = AutomationResponse(
                requestID: request.requestID,
                error: AutomationError(
                    code: .serverUnavailable,
                    message: error.localizedDescription,
                    retryable: retryable,
                    details: .object([
                        "delivery": .string(retryable ? "notSent" : "unknown"),
                        "retryable": .boolean(retryable)
                    ])
                )
            )
            if options.json { writeJSON(response) }
            writeDiagnostic(error.localizedDescription)
            return .unavailable
        } catch let error as AutomationIPCError {
            if options.json {
                let response = AutomationResponse(
                    requestID: request.requestID,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: error.localizedDescription,
                        retryable: true,
                        details: .object(["delivery": .string("notSent")])
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
        case .authorizationRequired, .permissionDenied:
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
        deadline: Date,
        connectionDeadline: Date,
        canLaunch: Bool
    ) throws -> AutomationResponse {
        let connectionDeadline = min(connectionDeadline, deadline)
        var lastError: Error?
        var didLaunchApp = false
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            let remainingConnection = connectionDeadline.timeIntervalSinceNow
            guard remaining > 0, remainingConnection > 0 else {
                throw lastError ?? AutomationIPCError.timeout
            }
            do {
                return try client.sendClassified(
                    request,
                    timeout: remaining,
                    connectionTimeout: remainingConnection
                )
            } catch let error as AutomationIPCRequestError {
                guard error.isDefinitelyNotSent else { throw error }
                lastError = error
                if canLaunch && !noLaunch && !didLaunchApp {
                    launchAppIfNeeded()
                    didLaunchApp = true
                }
                guard Date() < connectionDeadline else { throw error }
                Thread.sleep(forTimeInterval: min(0.1, max(0, connectionDeadline.timeIntervalSinceNow)))
            }
        }
        throw lastError ?? AutomationIPCError.timeout
    }

    private func libraryTracksParameters(from options: CLIOptions) -> AutomationJSONValue? {
        var values: [String: AutomationJSONValue] = [:]
        if let query = options.query {
            values["query"] = .string(query)
        }
        if let playlistID = options.playlistID {
            values["playlistID"] = .string(playlistID)
        }
        if let sourceID = options.sourceID {
            values["sourceID"] = .string(sourceID)
        }
        if let relativePathPrefix = options.relativePathPrefix {
            values["relativePathPrefix"] = .string(relativePathPrefix)
        }
        if !options.ids.isEmpty {
            values["ids"] = .array(options.ids.map { .string($0) })
        }
        if let filterJSON = options.filterJSON {
            values["filter"] = filterJSON
        }
        if let sortJSON = options.sortJSON {
            values["sort"] = sortJSON
        }
        if let limit = options.limit {
            values["limit"] = .number(Double(limit))
        }
        if let offset = options.offset {
            values["offset"] = .number(Double(offset))
        }
        if let expectedRevision = options.expectedRevision {
            values["expectedRevision"] = .string(expectedRevision)
        }
        if let paramsJSON = options.paramsJSON {
            if case .object(let extra) = paramsJSON {
                values.merge(extra) { _, incoming in incoming }
            }
        }
        return values.isEmpty ? nil : .object(values)
    }

    private func historyParameters(from options: CLIOptions) -> AutomationJSONValue? {
        var values: [String: AutomationJSONValue] = [:]
        if let query = options.query { values["query"] = .string(query) }
        if let trackID = options.trackTargetID { values["trackID"] = .string(trackID) }
        if let limit = options.limit { values["limit"] = .number(Double(limit)) }
        if let offset = options.offset { values["offset"] = .number(Double(offset)) }
        if let from = options.from { values["from"] = .string(from) }
        if let to = options.to { values["to"] = .string(to) }
        if let paramsJSON = options.paramsJSON, case .object(let extra) = paramsJSON {
            values.merge(extra) { _, incoming in incoming }
        }
        if let expectedRevision = options.expectedRevision {
            values["expectedRevision"] = .string(expectedRevision)
        }
        return values.isEmpty ? nil : .object(values)
    }

    private func entityTargetValues(from options: CLIOptions) -> [String: AutomationJSONValue] {
        var values: [String: AutomationJSONValue] = [:]
        if let trackID = options.trackTargetID { values["trackID"] = .string(trackID) }
        if let artistID = options.artistID { values["artistID"] = .string(artistID) }
        if let albumKey = options.albumKey { values["albumKey"] = .string(albumKey) }
        if let playlistID = options.targetPlaylistID { values["playlistID"] = .string(playlistID) }
        return values
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
                      timeout <= AutomationToolDefaults.maximumTimeout else {
                    throw CLIError.invalidValue("--timeout")
                }
                options.timeout = timeout
                options.timeoutWasSet = true
                args.removeSubrange(index...(index + 1))
            case "--library":
                guard index + 1 < args.count,
                      let libraryID = UUID(uuidString: args[index + 1]) else {
                    throw CLIError.invalidValue("--library")
                }
                options.libraryID = libraryID
                args.removeSubrange(index...(index + 1))
            case "--query":
                guard index + 1 < args.count else {
                    throw CLIError.missingValue("--query")
                }
                options.query = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--entity-type":
                guard index + 1 < args.count,
                      ["artist", "album", "playlist"].contains(args[index + 1].lowercased()) else {
                    throw CLIError.invalidValue("--entity-type")
                }
                options.entityType = args[index + 1].lowercased()
                args.removeSubrange(index...(index + 1))
            case "--playlist":
                guard index + 1 < args.count else {
                    throw CLIError.missingValue("--playlist")
                }
                options.playlistID = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--track-id":
                guard index + 1 < args.count,
                      UUID(uuidString: args[index + 1]) != nil else {
                    throw CLIError.invalidValue("--track-id")
                }
                options.trackTargetID = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--artist-id":
                guard index + 1 < args.count,
                      UUID(uuidString: args[index + 1]) != nil else {
                    throw CLIError.invalidValue("--artist-id")
                }
                options.artistID = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--album-key":
                guard index + 1 < args.count, !args[index + 1].isEmpty else {
                    throw CLIError.invalidValue("--album-key")
                }
                options.albumKey = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--playlist-id":
                guard index + 1 < args.count,
                      UUID(uuidString: args[index + 1]) != nil else {
                    throw CLIError.invalidValue("--playlist-id")
                }
                options.targetPlaylistID = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--source":
                guard index + 1 < args.count else {
                    throw CLIError.missingValue("--source")
                }
                options.sourceID = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--source-mode":
                guard index + 1 < args.count,
                      ["directory", "file"].contains(args[index + 1]) else {
                    throw CLIError.invalidValue("--source-mode")
                }
                options.sourceMode = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--relative-path-prefix":
                guard index + 1 < args.count else {
                    throw CLIError.missingValue("--relative-path-prefix")
                }
                options.relativePathPrefix = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--ids":
                guard index + 1 < args.count else { throw CLIError.missingValue("--ids") }
                options.ids = args[index + 1]
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map(String.init)
                args.removeSubrange(index...(index + 1))
            case "--filter-json":
                guard index + 1 < args.count else { throw CLIError.missingValue("--filter-json") }
                options.filterJSON = try decodeJSON(args[index + 1], option: "--filter-json")
                args.removeSubrange(index...(index + 1))
            case "--sort-json":
                guard index + 1 < args.count else { throw CLIError.missingValue("--sort-json") }
                options.sortJSON = try decodeJSON(args[index + 1], option: "--sort-json")
                args.removeSubrange(index...(index + 1))
            case "--params-json":
                guard index + 1 < args.count else { throw CLIError.missingValue("--params-json") }
                options.paramsJSON = try decodeJSON(args[index + 1], option: "--params-json")
                args.removeSubrange(index...(index + 1))
            case "--params-file":
                guard index + 1 < args.count else { throw CLIError.missingValue("--params-file") }
                let fileURL = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let fileSize = attributes[.size] as? NSNumber,
                      fileSize.intValue <= 750_000 else {
                    throw CLIError.invalidValue("--params-file (maximum size 750000 bytes)")
                }
                guard let data = try? Data(contentsOf: fileURL),
                      let raw = String(data: data, encoding: .utf8) else {
                    throw CLIError.invalidValue("--params-file")
                }
                options.paramsJSON = try decodeJSON(raw, option: "--params-file")
                args.removeSubrange(index...(index + 1))
            case "--limit":
                guard index + 1 < args.count,
                      let limit = Int(args[index + 1]),
                      (1...500).contains(limit) else {
                    throw CLIError.invalidValue("--limit")
                }
                options.limit = limit
                args.removeSubrange(index...(index + 1))
            case "--offset":
                guard index + 1 < args.count,
                      let offset = Int(args[index + 1]),
                      offset >= 0 else {
                    throw CLIError.invalidValue("--offset")
                }
                options.offset = offset
                args.removeSubrange(index...(index + 1))
            case "--from", "--to":
                guard index + 1 < args.count,
                      ISO8601DateFormatter().date(from: args[index + 1]) != nil else {
                    throw CLIError.invalidValue(args[index])
                }
                if args[index] == "--from" {
                    options.from = args[index + 1]
                } else {
                    options.to = args[index + 1]
                }
                args.removeSubrange(index...(index + 1))
            case "--dimension":
                guard index + 1 < args.count,
                      ["all", "track", "artist", "album"].contains(args[index + 1]) else {
                    throw CLIError.invalidValue("--dimension")
                }
                options.dimension = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--expected-revision":
                guard index + 1 < args.count else {
                    throw CLIError.missingValue("--expected-revision")
                }
                options.expectedRevision = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--idempotency-key":
                guard index + 1 < args.count else { throw CLIError.missingValue("--idempotency-key") }
                options.idempotencyKey = args[index + 1]
                args.removeSubrange(index...(index + 1))
            case "--dry-run":
                options.dryRun = true
                args.remove(at: index)
            case "--yes", "--confirm", "--apply":
                options.confirm = true
                options.dryRun = false
                args.remove(at: index)
            case "--force":
                options.force = true
                args.remove(at: index)
            case "--help", "-h":
                printUsage(to: FileHandle.standardOutput)
                exit(AutomationCLIExitCode.success.rawValue)
            default:
                index += 1
            }
        }
    }

    private func decodeJSON(_ raw: String, option: String) throws -> AutomationJSONValue {
        guard let data = raw.data(using: .utf8) else {
            throw CLIError.invalidValue(option)
        }
        do {
            return try AutomationWireCoding.decoder().decode(AutomationJSONValue.self, from: data)
        } catch {
            throw CLIError.invalidValue(option)
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
          automation capabilities  List the shared capability catalog
          automation scopes        Show granted and denied scopes
          automation call <method> Call any catalog method with --params-json
          system ping             Check the App automation socket
          system info             Read protocol and capability information
          library list            List registered libraries and active ID
          library get <id>        Read registered library name, mode and active status
          library tracks          Query tracks with filters, sorting and pagination
          library stats           Summarize library contents and media coverage
          library report          Export a paginated machine-readable Library report
          library bundle-export   Export metadata, playlists and media; returns a Job
          library selection-list|selection-get|selection-create|selection-delete
                                  Save and reuse Track ID or filter selections
          library import <path>... [--playlist-id <id>] [--params-json '{"enrichmentPolicy":"migration"}']
                                   Import audio/folders (including NCM); returns a Job
          library create <mode> <name> [parent]
                                   Create and activate a library
          library open [path]     Open and activate an existing library
          library switch <id>     Switch to a registered library
          library rename <id> <name>
                                   Rename a registered library
          library relocate <id> [parent]
                                   Move a library to a new parent folder
          library remove <id>     Move a library to macOS Trash
          playlist list            List playlists and revisions
          playlist get <id>        Read ordered playlist membership
          playlist export <id>     Export M3U8 text with stable Track IDs
          playlist import <id> --params-json '{"m3uText":"..."}'
                                   Preview or import an M3U8 payload
          playlist diff <union|intersection|difference> <id> <id>...
          playlist create <name>   Create a playlist (use --dry-run to preview)
          playlist rename <id> <name> [description]
          playlist delete <id>     Delete a playlist (App confirmation required)
          playlist replace <id> <track-id>...
          playlist reorder <id> <track-id>...
          playlist add <playlist-id> <track-id>...
                           Add existing library tracks (use --dry-run to preview)
          playlist add-selection <playlist-id> <selection-id>
                           Add a saved selection to a playlist
          playlist remove <playlist-id> <track-id>...
                                   Remove playlist membership (use --dry-run to preview)
          source list              List referenced-library sources
          source get <id>          Read one source policy and status
          source config-export     Export portable Source policies as JSON
          source config-import --params-json '{"document":{...}}'
                                   Preview/apply policies to existing Sources
          source rename <id> <name>
                                   Rename a source without changing its authority
          source refresh <id>      Refresh one authorized source (use --dry-run to preview)
          source create [path]     Request a folder/file Source through the App picker
          source bind <source-id> <playlist-id> [relative-path]
          source exclude|include <source-id> <relative-path>
          source watch|unwatch <source-id>
          source remove <id>       Remove a Source (App confirmation required)
          files reveal <track-id>... Reveal authorized files in Finder
          files export <track-id>... Copy audio through an App folder picker
          playback state|play|play-playlist|toggle|pause|next|previous|seek|volume|mode
          queue get|upcoming|replace|enqueue|enqueue-next|remove|reorder|clear
          history list|stats|clear Read, aggregate or clear listening history
                                   list accepts date/query/Track filters and pagination
          metadata get <track-id>... | --track-id/--artist-id/--album-key/--playlist-id
                                  or --entity-type artist|album|playlist [--query]
          metadata embedded-get <track-id>...  Read tags from audio files
          metadata embedded-patch <track-id>... --params-file <json-file>
                                  Preview or write MP3 ID3 tags; App confirmation required
          metadata export [<track-id>...] [--limit <count> --offset <count>] (max 100 per page)
          metadata import --params-file <json-file> [--dry-run] [--confirm]
          metadata search <track-id>
          metadata apply-candidate <track-id> <candidate-id> [--dry-run]
          metadata patch <track-id>... --params-json '{"title":"..."}'
                                  or an entity target flag
          artwork search <track-id> | --track-id/--artist-id/--album-key
          artwork get <track-id>... | an entity target flag
          artwork apply <track-id>... | an entity target flag
                                  --params-json '{"imagePath":"/path/cover.jpg"}'
          artwork apply-candidate <candidate-id> [--dry-run]
          lyrics get <track-id>
          lyrics clean <track-id> [--dry-run]
          lyrics search|candidates <track-id> [--params-json '{...}']
          lyrics compare|apply <track-id> --params-json '{...}'
          lyrics refresh <track-id>... [--force] (returns a Job)
          jobs list               Inspect recent library jobs
          jobs get|wait|cancel|retry <job-id>
                                   Inspect, wait for, cancel or retry a library job
          jobs wait <job-id> [--params-json '{"timeoutMs":20000}']
                                   Wait up to 20 seconds by default; use jobs get for a snapshot
          jobs retry <job-id> --params-json '{"filePaths":[...]}'
                                   Retry an import with newly authorized input files
          diagnostics health [--params-json <object>]
                                   Collect paginated health evidence or start a background Job
          settings schema|get|patch|validate|reset
                                   Inspect, validate, update or reset persistent settings
          dsp schema|state|validate|patch|wait|presets|errors  Control DSP and complete presets.
          audio get|patch          Read audio state or update scheduling and App output routing
          storage inspect         Inspect Library storage layout and schema
          storage validate [--params-json <object>]
                                   Validate storage invariants or start a background Job
          storage orphans         Report Playlist references to missing Tracks
          storage backup          Back up JSON/sidecar metadata without audio
          storage diff <path>     Compare current metadata with a backup
          storage reload          Reload the active Library from its storage
          storage repair          Repair missing App-owned scaffolding

        Options:
          --json                  Emit one versioned JSON response on stdout
          --no-launch             Do not ask LaunchServices to start the App
          --socket <path>         Override the per-user AF_UNIX socket path
          --timeout <seconds>     IPC timeout override (0 < seconds <= 120; default 10)
          --library <id>          Require a specific active library UUID
          --query <text>          Filter tracks or metadata entities by text
          --entity-type <type>    List metadata entities: artist, album or playlist
          --playlist <id>         Limit library tracks to a playlist
          --track-id <id>         Target one Track for metadata/artwork
          --artist-id <id>        Target one Artist for metadata/artwork
          --album-key <key>       Target one Album for metadata/artwork
          --playlist-id <id>      Target one Playlist for metadata/artwork
          --source <id>           Limit library tracks to a referenced source
          --source-mode <mode>    Source creation mode: directory or file
          --relative-path-prefix <path>
                                  Limit tracks to a Source-relative path prefix
          --ids <id,id,...>       Limit tracks to a set of Track IDs
          --filter-json <json>    Composable all/any/not Track predicate
          --sort-json <json>      Ordered sort descriptor array
          --limit <count>         Page size from 1 to 500
          --offset <count>        Page offset, starting at 0
          --from <iso8601>        History lower bound (inclusive)
          --to <iso8601>          History upper bound (exclusive)
          --expected-revision <id>
                                  Require a matching library/playlist revision
          --idempotency-key <id>  Safely retry the same mutation
          --params-json <json>    Parameters for automation call
          --params-file <path>    Read a JSON parameter object from a file
          --dry-run               Preview a mutation without applying it
          --force                 Allow a lyrics refresh/apply policy to replace lower-quality lyrics
          --yes                   Acknowledge a high-risk request; App policy still confirms
          --help                  Show this help

        mcp-stdio                 Serve the same tools over MCP stdio
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
