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
            guard args.isEmpty else {
                writeDiagnostic("usage error: mcp-stdio does not accept positional arguments")
                return .usage
            }
            let mcpExitCode = AutomationMCPStdioServer(
                options: AutomationMCPStdioOptions(
                    socketPath: options.socketPath,
                    noLaunch: options.noLaunch,
                    timeout: options.timeout
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
                writeDiagnostic("usage error: library requires list, tracks, create, open, switch, rename, relocate or remove")
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
            case "tracks":
                guard args.isEmpty else {
                    writeDiagnostic("usage error: library tracks uses named options only")
                    return .usage
                }
                method = AutomationMethod.libraryTracks
                params = libraryTracksParameters(from: options)
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
                writeDiagnostic("usage error: playlist requires list, get, create, rename, delete, add, remove, replace or reorder")
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
            default:
                writeDiagnostic("usage error: unknown playlist action \(action)")
                return .usage
            }
        case "source":
            guard let action = args.first else {
                writeDiagnostic("usage error: source requires list, refresh, create, bind, exclude, include, watch, unwatch or remove")
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
        case "playback":
            guard let action = args.first else {
                writeDiagnostic("usage error: playback requires state, play, pause, next, previous, seek, volume or mode")
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
            guard let action = args.first else { writeDiagnostic("usage error: queue requires get, replace, enqueue, enqueue-next or clear"); return .usage }
            args.removeFirst()
            switch action {
            case "get": method = AutomationMethod.queueGet; params = nil
            case "clear": method = AutomationMethod.queueClear; params = .object(["dryRun": .boolean(options.dryRun)])
            case "replace", "enqueue", "enqueue-next":
                guard !args.isEmpty else {
                    writeDiagnostic("usage error: queue \(action) requires at least one track ID")
                    return .usage
                }
                var values: [String: AutomationJSONValue] = [
                    "trackIDs": .array(args.map { .string($0) }),
                    "dryRun": .boolean(options.dryRun)
                ]
                if let expectedRevision = options.expectedRevision { values["expectedRevision"] = .string(expectedRevision) }
                method = action == "replace" ? AutomationMethod.queueReplace : (action == "enqueue" ? AutomationMethod.queueEnqueue : AutomationMethod.queueEnqueueNext)
                params = .object(values)
            default: writeDiagnostic("usage error: unknown queue action \(action)"); return .usage
            }
        case "history":
            guard let action = args.first else { writeDiagnostic("usage error: history requires list or clear"); return .usage }
            args.removeFirst()
            guard args.isEmpty else {
                writeDiagnostic("usage error: history action does not accept positional arguments")
                return .usage
            }
            switch action {
            case "list":
                guard options.offset == nil else {
                    writeDiagnostic("usage error: history list does not support --offset")
                    return .usage
                }
                method = AutomationMethod.historyList
                params = historyParameters(from: options)
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
            guard let action = args.first else { writeDiagnostic("usage error: metadata requires get or patch"); return .usage }
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
                writeDiagnostic("usage error: artwork requires search, get or apply")
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
            guard let action = args.first else { writeDiagnostic("usage error: jobs requires list, get, cancel or retry"); return .usage }
            args.removeFirst()
            switch action {
            case "list": method = AutomationMethod.jobsList; params = nil
            case "get", "cancel", "retry":
                guard args.count == 1 else { writeDiagnostic("usage error: jobs \(action) requires a job ID"); return .usage }
                method = action == "get"
                    ? AutomationMethod.jobsGet
                    : (action == "cancel" ? AutomationMethod.jobsCancel : AutomationMethod.jobsRetry)
                params = .object(["jobID": .string(args[0])])
            default: writeDiagnostic("usage error: unknown jobs action \(action)"); return .usage
            }
        case "diagnostics":
            guard args.count == 1, args[0] == "health" else { writeDiagnostic("usage error: diagnostics health"); return .usage }
            method = AutomationMethod.diagnosticsHealth
            params = nil
        case "settings":
            guard let action = args.first else {
                writeDiagnostic("usage error: settings requires get or patch")
                return .usage
            }
            args.removeFirst()
            switch action {
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
            default:
                writeDiagnostic("usage error: unknown settings action \(action)")
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
                params = nil
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
            // A single CLI invocation may retry after a lost transport
            // response. Give those retries one stable key without making two
            // separate invocations accidentally share a mutation.
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
            let socketExists = FileManager.default.fileExists(atPath: options.socketPath)
            let isCustomSocket = options.socketPath != AutomationToolDefaults.socketPath
            if !options.noLaunch && !socketExists && !isCustomSocket {
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
        return values.isEmpty ? nil : .object(values)
    }

    private func historyParameters(from options: CLIOptions) -> AutomationJSONValue? {
        var values: [String: AutomationJSONValue] = [:]
        if let limit = options.limit { values["limit"] = .number(Double(limit)) }
        if let from = options.from { values["from"] = .string(from) }
        if let to = options.to { values["to"] = .string(to) }
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
                      timeout <= 120 else {
                    throw CLIError.invalidValue("--timeout")
                }
                options.timeout = timeout
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
          library tracks          Query tracks with filters, sorting and pagination
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
          playlist create <name>   Create a playlist (use --dry-run to preview)
          playlist rename <id> <name> [description]
          playlist delete <id>     Delete a playlist (App confirmation required)
          playlist replace <id> <track-id>...
          playlist reorder <id> <track-id>...
          playlist add <playlist-id> <track-id>...
                                   Add existing library tracks (use --dry-run to preview)
          playlist remove <playlist-id> <track-id>...
                                   Remove playlist membership (use --dry-run to preview)
          source list              List referenced-library sources
          source refresh <id>      Refresh one authorized source (use --dry-run to preview)
          source create [path]     Request a folder/file Source through the App picker
          source bind <source-id> <playlist-id> [relative-path]
          source exclude|include <source-id> <relative-path>
          source watch|unwatch <source-id>
          source remove <id>       Remove a Source (App confirmation required)
          playback state|play|pause|next|previous|seek|volume|mode
          queue get|replace|enqueue|enqueue-next|clear
          history list|clear       Read or clear listening history
          metadata get <track-id>... | --track-id/--artist-id/--album-key/--playlist-id
                                  or --entity-type artist|album|playlist [--query]
          metadata patch <track-id>... --params-json '{"title":"..."}'
                                  or an entity target flag
          artwork search <track-id> | --track-id/--artist-id/--album-key
          artwork get <track-id>... | an entity target flag
          artwork apply <track-id>... | an entity target flag
                                  --params-json '{"imagePath":"/path/cover.jpg"}'
          lyrics get <track-id>
          lyrics clean <track-id> [--dry-run]
          lyrics search|candidates <track-id> [--params-json '{...}']
          lyrics compare|apply <track-id> --params-json '{...}'
          lyrics refresh <track-id>... [--force] (returns a Job)
          jobs list|get|cancel|retry
                                   Inspect, cancel or retry long-running library jobs
          diagnostics health      Collect actionable Library/Source health evidence
          settings get            Read supported persistent automation settings
          settings patch          Update settings with --params-json
          storage inspect         Inspect Library storage layout and schema
          storage validate        Run App-owned storage integrity validation
          storage orphans         Report Playlist references to missing Tracks
          storage backup          Back up JSON/sidecar metadata without audio
          storage diff <path>     Compare current metadata with a backup
          storage reload          Reload the active Library from its storage
          storage repair          Repair missing App-owned scaffolding

        Options:
          --json                  Emit one versioned JSON response on stdout
          --no-launch             Do not ask LaunchServices to start the App
          --socket <path>         Override the per-user AF_UNIX socket path
          --timeout <seconds>     Bound connection and launch wait (default 10)
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
