import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

private nonisolated struct AutomationStorageBackupManifest: Codable {
    let schemaVersion: Int
    let libraryID: UUID
    let mode: String
    let createdAt: Date
    let files: [File]

    struct File: Codable {
        let relativePath: String
        let sha256: String
        let byteCount: Int64
    }
}

nonisolated struct AutomationStorageBackupPruneResult: Sendable, Equatable {
    let removedBackupCount: Int
    let failures: [String]
}

/// Keeps storage.backup recoverable without letting repeated automation runs
/// accumulate one full metadata/artwork snapshot per invocation.
nonisolated enum AutomationStorageBackupRetention {
    static let maximumBackupCount = 1

    static func pruneOlderBackups(
        at rootURL: URL,
        keeping retainedBackupURL: URL,
        fileManager: FileManager = .default
    ) -> AutomationStorageBackupPruneResult {
        let root = rootURL.standardizedFileURL
        let retained = retainedBackupURL.standardizedFileURL
        guard retained.path.hasPrefix(root.path + "/") else {
            return AutomationStorageBackupPruneResult(
                removedBackupCount: 0,
                failures: ["Refused to prune a backup outside the backup root."]
            )
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return AutomationStorageBackupPruneResult(
                removedBackupCount: 0,
                failures: ["Failed to enumerate automation backup snapshots."]
            )
        }

        var removedBackupCount = 0
        var failures: [String] = []
        for entry in entries {
            guard entry.standardizedFileURL.path != retained.path else {
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            do {
                try fileManager.removeItem(at: entry)
                removedBackupCount += 1
            } catch {
                if failures.count < 50 {
                    failures.append(
                        "Failed to remove old automation backup \(entry.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        return AutomationStorageBackupPruneResult(
            removedBackupCount: removedBackupCount,
            failures: failures
        )
    }
}

private nonisolated struct AutomationStorageInventoryItem {
    let relativePath: String
    let sourceURL: URL
    let sha256: String
    let byteCount: Int64
}

private nonisolated struct AutomationStorageInventory {
    let items: [AutomationStorageInventoryItem]
    let omittedFileCount: Int
    let failures: [String]
}

@MainActor
struct AutomationStorageHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }
    private let automationBundleIdentifier: String
    private let appSupportDirectoryURL: URL?

    init(appSession: AppSessionHost?, automationBundleIdentifier: String, appSupportDirectoryURL: URL?) {
        self.appSession = appSession
        self.automationBundleIdentifier = automationBundleIdentifier
        self.appSupportDirectoryURL = appSupportDirectoryURL
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.diagnosticsHealth:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 100)
                guard offset >= 0, (1...100).contains(limit) else {
                    throw AutomationParameterError.outOfRange("offset/limit")
                }
                let tracks = session.libraryViewModel.allTracks
                let missing = tracks.filter { $0.availability == .missing }.count
                let unavailable = tracks.filter { $0.availability != .available }.count
                let missingLyrics = tracks.filter { queries.trackLyricsStatus($0) == "none" }.count
                let missingArtwork = tracks.filter { !$0.hasArtwork }.count
                let incompleteMetadata = tracks.filter { track in
                    [track.title, track.artist, track.album].contains {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }.count
                let sources = try await appSession.referencedSources()
                let sourceIssues = sources
                    .filter { $0.status != .available }
                    .map { "\($0.displayName): \($0.status.rawValue) (\($0.lastKnownPath))" }
                let jobs = session.libraryJobDescriptorsSnapshot()
                let runningJobs = jobs.filter {
                    switch $0.state {
                    case .queued, .running, .checkpointed: return true
                    case .completed, .partialFailure, .failed, .cancelled: return false
                    }
                }.count
                let failedJobs = jobs.filter {
                    switch $0.state {
                    case .failed, .partialFailure: return true
                    case .queued, .running, .checkpointed, .completed, .cancelled: return false
                    }
                }
                let failedJobSummaries = failedJobs.flatMap { job in
                    let prefix = job.partialFailureSummaries.prefix(3)
                    if prefix.isEmpty {
                        return ["\(job.id.uuidString): \(job.state.rawValue)"]
                    }
                    return prefix.map { "\(job.id.uuidString): \($0)" }
                }.prefix(50)
                let diskSnapshot = try? await storageDiskSnapshot(for: session)
                let playlistReferenceIssues = diskSnapshot.map {
                    makePlaylistReferenceIssues($0.playlistReferenceIssues)
                } ?? []
                var storageValidation = "notRun"
                var storageValidationMessage: String?
                var storageValidationError: Error?
                do {
                    try await LibraryUpgradeSessionValidator.validate(
                        context: session.context,
                        libraryViewModel: session.libraryViewModel,
                        repository: session.repository,
                        searchIndex: session.searchIndex,
                        playbackHistoryStore: session.playbackHistoryStore
                    )
                    storageValidation = "passed"
                } catch {
                    storageValidation = "failed"
                    storageValidationMessage = String(describing: error)
                    storageValidationError = error
                }
                let issues = diagnosticsIssues(
                    tracks: tracks,
                    sources: sources,
                    jobs: jobs,
                    playlistReferences: playlistReferenceIssues,
                    storageError: storageValidationError,
                    diskSnapshot: diskSnapshot,
                    in: session
                )
                let mediaIssues = mediaPresenceIssues(for: tracks, in: session).map {
                    AutomationDiagnosticIssue(
                        id: $0.id,
                        code: $0.code,
                        trackID: $0.trackID,
                        path: $0.path,
                        reason: $0.reason
                    )
                }.sorted { $0.id < $1.id }
                let checks = [
                    "library": "ok",
                    "sources": sourceIssues.isEmpty ? "ok" : "attention",
                    "missingTracks": missing == 0 ? "ok" : "attention",
                    "unavailableTracks": unavailable == 0 ? "ok" : "attention",
                    "lyricsCoverage": missingLyrics == 0 ? "complete" : "partial",
                    "artworkCoverage": missingArtwork == 0 ? "complete" : "partial",
                    "metadataCoverage": incompleteMetadata == 0 ? "complete" : "partial",
                    "jobs": runningJobs == 0 ? (failedJobs.isEmpty ? "idle" : "attention") : "running",
                    "playlistReferences": playlistReferenceIssues.isEmpty ? "ok" : "attention",
                    "mediaPresence": mediaIssues.isEmpty ? "ok" : "attention",
                    "storage": storageValidation == "passed" ? "ok" : "attention"
                ]
                return AutomationResponseSupport.encodeResult(
                    AutomationDiagnosticsResult(
                        healthy: sourceIssues.isEmpty
                            && unavailable == 0
                            && failedJobs.isEmpty
                            && playlistReferenceIssues.isEmpty
                            && mediaIssues.isEmpty
                            && storageValidation == "passed",
                        libraryID: session.context.id,
                        trackCount: tracks.count,
                        playlistCount: session.libraryViewModel.playlists.count,
                        missingTrackCount: missing,
                        unavailableTrackCount: unavailable,
                        missingLyricsTrackCount: missingLyrics,
                        missingArtworkTrackCount: missingArtwork,
                        incompleteMetadataTrackCount: incompleteMetadata,
                        sourceCount: sources.count,
                        sourceIssues: sourceIssues,
                        runningJobCount: runningJobs,
                        checks: checks,
                        failedJobCount: failedJobs.count,
                        failedJobSummaries: Array(failedJobSummaries),
                        playlistReferenceIssues: Array(playlistReferenceIssues.prefix(100)),
                        storageValidation: storageValidation,
                        storageValidationMessage: storageValidationMessage,
                        issues: Array(issues.dropFirst(offset).prefix(limit)),
                        issueCount: issues.count,
                        offset: offset,
                        limit: limit,
                        hasMore: offset + limit < issues.count,
                        mediaIssues: Array(mediaIssues.dropFirst(offset).prefix(limit)),
                        mediaIssueCount: mediaIssues.count,
                        mediaHasMore: offset + limit < mediaIssues.count
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to collect library diagnostics.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageInspect:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                storageResult(for: session, validation: "notRun"),
                for: request
            )

        case AutomationMethod.storageValidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 100)
                guard offset >= 0, (1...100).contains(limit) else {
                    throw AutomationParameterError.outOfRange("offset/limit")
                }
                let diskSnapshot = try? await storageDiskSnapshot(for: session)
                do {
                    try await LibraryUpgradeSessionValidator.validate(
                        context: session.context,
                        libraryViewModel: session.libraryViewModel,
                        repository: session.repository,
                        searchIndex: session.searchIndex,
                        playbackHistoryStore: session.playbackHistoryStore
                    )
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "passed",
                            validationMessage: "The App-owned storage validator passed.",
                            diskSnapshot: diskSnapshot,
                            includeMediaPresenceIssues: true,
                            offset: offset,
                            limit: limit
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "failed",
                            validationMessage: String(describing: error),
                            message: "Storage validation found an issue; no repair was attempted.",
                            validationError: error,
                            diskSnapshot: diskSnapshot,
                            includeMediaPresenceIssues: true,
                            offset: offset,
                            limit: limit
                        ),
                        for: request
                    )
                }
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.storageRepair:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "notRun",
                            message: "Preview only. Repair can recreate missing App-owned directories and the default scoped-settings file; it never edits Track, Playlist, Source or cache contents."
                        ),
                        for: request
                    )
                }
                try LibraryScaffoldingRepair.repairIfNeeded(at: session.context.rootURL)
                await session.libraryViewModel.reloadLibrary()
                return AutomationResponseSupport.encodeResult(
                    storageResult(
                        for: session,
                        validation: "notRun",
                        message: "Library scaffolding repair completed. Run storage.validate to verify all invariants."
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Library scaffolding repair failed.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageOrphans:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let snapshot = try await storageDiskSnapshot(for: session)
                return AutomationResponseSupport.encodeResult(
                    AutomationStorageOrphansResult(
                        libraryID: session.context.id,
                        playlistReferenceIssues: makePlaylistReferenceIssues(
                            snapshot.playlistReferenceIssues
                        ),
                        message: snapshot.playlistReferenceIssues.isEmpty
                            ? "No Playlist references point to missing Track sidecars."
                            : "Playlist references were inspected; no data was changed."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to inspect Playlist references.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageBackup:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let context = session.context
                let result = try await session.runLibraryOperation(as: .other) {
                    try await Task.detached(priority: .utility) {
                        try Self.createStorageBackup(
                            context: context,
                            bundleIdentifier: self.automationBundleIdentifier,
                            appSupportDirectoryURL: self.appSupportDirectoryURL
                        )
                    }.value
                }
                return AutomationResponseSupport.encodeResult(result, for: request)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to create the Library metadata backup.",
                        retryable: true,
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageDiff:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let backupPath = try parameters.string("backupPath", required: true)!
                let context = session.context
                let result = try await Task.detached(priority: .utility) {
                    try Self.storageDiff(
                        context: context,
                        backupPath: backupPath,
                        bundleIdentifier: self.automationBundleIdentifier,
                        appSupportDirectoryURL: self.appSupportDirectoryURL
                    )
                }.value
                return AutomationResponseSupport.encodeResult(result, for: request)
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to compare the Library metadata backup.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageReload:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let _: Void = try await session.runLibraryOperation(as: .other) {
                    await session.libraryViewModel.reloadLibrary()
                }
                return AutomationResponseSupport.encodeResult(
                    storageResult(
                        for: session,
                        validation: "notRun",
                        message: "The active Library was reloaded from its current App-owned storage. Run storage.validate afterward."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to reload the active Library.",
                        retryable: true,
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private nonisolated static let automationStorageBackupRoots: Set<String> = [
        "Settings",
        "Sources",
        "Tracks",
        "Playlists",
        "Artists",
        "Albums"
    ]

    private nonisolated static let automationStorageBackupExtensions: Set<String> = [
        "json",
        "ttml",
        "lrc",
        "txt",
        "png",
        "jpg",
        "jpeg",
        "webp",
        "heic"
    ]

    private func storageDiskSnapshot(
        for session: LibrarySession
    ) async throws -> LibraryUpgradeSessionValidator.DiskSnapshot {
        let context = session.context
        return try await Task.detached(priority: .utility) {
            try LibraryUpgradeSessionValidator.inspectDisk(context: context)
        }.value
    }

    private func makePlaylistReferenceIssues(
        _ issues: [LibraryUpgradeSessionValidator.LibraryStoragePlaylistReferenceIssue]
    ) -> [AutomationPlaylistReferenceIssue] {
        issues.map {
            AutomationPlaylistReferenceIssue(
                playlistID: $0.playlistID,
                playlistName: $0.playlistName,
                missingTrackIDs: $0.missingTrackIDs
            )
        }
    }

    private nonisolated static func automationStorageBackupRoot(
        libraryID: UUID,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) -> URL {
        return AutomationSupportPaths.automationSupportDirectory(
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
    }

    private nonisolated static func storageInventory(
        at rootURL: URL
    ) throws -> AutomationStorageInventory {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootPath = root.path
        guard fileManager.fileExists(atPath: rootPath) else {
            throw AutomationParameterError.missingResource("library storage")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AutomationParameterError.invalidValue("library storage")
        }

        var items: [AutomationStorageInventoryItem] = []
        var omittedFileCount = 0
        var failures: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                omittedFileCount += 1
                if failures.count < 50 {
                    failures.append("Skipped file outside Library root: \(url.path)")
                }
                continue
            }

            guard url.path.hasPrefix(rootPath + "/") else {
                omittedFileCount += 1
                continue
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first,
                  (first == "library.json"
                    || automationStorageBackupRoots.contains(String(first))),
                  automationStorageBackupExtensions.contains(url.pathExtension.lowercased()) else {
                omittedFileCount += 1
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                items.append(
                    AutomationStorageInventoryItem(
                        relativePath: relativePath,
                        sourceURL: url,
                        sha256: digest,
                        byteCount: Int64(data.count)
                    )
                )
            } catch {
                if failures.count < 50 {
                    failures.append("Failed to read \(relativePath): \(error.localizedDescription)")
                }
            }
        }
        return AutomationStorageInventory(
            items: items.sorted { $0.relativePath < $1.relativePath },
            omittedFileCount: omittedFileCount,
            failures: failures
        )
    }

    private nonisolated static func createStorageBackup(
        context: LibraryContext,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> AutomationStorageBackupResult {
        let createdAt = Date()
        let inventory = try storageInventory(at: context.rootURL)
        let fileManager = FileManager.default
        let root = automationStorageBackupRoot(
            libraryID: context.id,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let destination = root.appendingPathComponent(
            "\(stamp)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copiedFiles: [AutomationStorageBackupManifest.File] = []
        var copiedBytes: Int64 = 0
        var failures = inventory.failures
        for item in inventory.items {
            let target = destination.appendingPathComponent(item.relativePath)
            do {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: item.sourceURL, to: target)
                copiedFiles.append(
                    AutomationStorageBackupManifest.File(
                        relativePath: item.relativePath,
                        sha256: item.sha256,
                        byteCount: item.byteCount
                    )
                )
                copiedBytes += item.byteCount
            } catch {
                if failures.count < 50 {
                    failures.append("Failed to back up \(item.relativePath): \(error.localizedDescription)")
                }
            }
        }

        let manifest = AutomationStorageBackupManifest(
            schemaVersion: 1,
            libraryID: context.id,
            mode: context.mode.rawValue,
            createdAt: createdAt,
            files: copiedFiles.sorted { $0.relativePath < $1.relativePath }
        )
        let manifestURL = destination.appendingPathComponent("automation-backup.json")
        try AutomationWireCoding.encoder().encode(manifest).write(
            to: manifestURL,
            options: .atomic
        )
        let pruneResult = AutomationStorageBackupRetention.pruneOlderBackups(
            at: root,
            keeping: destination,
            fileManager: fileManager
        )
        failures.append(contentsOf: pruneResult.failures)
        return AutomationStorageBackupResult(
            libraryID: context.id,
            backupPath: destination.path,
            createdAt: createdAt,
            copiedFileCount: copiedFiles.count,
            omittedFileCount: inventory.omittedFileCount,
            copiedBytes: copiedBytes,
            failures: Array(failures.prefix(50)),
            message: "Created a metadata-only backup and retained only the newest snapshot. Audio files, indexes, caches and live SQLite stores were intentionally omitted."
        )
    }

    private nonisolated static func storageBackupManifest(
        context: LibraryContext,
        backupPath: String,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> (URL, AutomationStorageBackupManifest) {
        let candidate = URL(fileURLWithPath: backupPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = automationStorageBackupRoot(
            libraryID: context.id,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidateValues = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
        guard candidate.path.hasPrefix(root.path + "/"),
              candidateValues?.isDirectory == true else {
            throw AutomationParameterError.invalidValue("backupPath")
        }
        let manifestURL = candidate
            .appendingPathComponent("automation-backup.json")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let manifestValues = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey])
        guard manifestURL.path.hasPrefix(candidate.path + "/"),
              manifestValues?.isRegularFile == true,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? AutomationWireCoding.decoder().decode(
                  AutomationStorageBackupManifest.self,
                  from: data
              ),
              manifest.schemaVersion == 1,
              manifest.libraryID == context.id else {
            throw AutomationParameterError.invalidValue("backupPath")
        }
        return (candidate, manifest)
    }

    private nonisolated static func storageDiff(
        context: LibraryContext,
        backupPath: String,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> AutomationStorageDiffResult {
        let (backupURL, manifest) = try storageBackupManifest(
            context: context,
            backupPath: backupPath,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        let current = try storageInventory(at: context.rootURL)
        let currentByPath = Dictionary(uniqueKeysWithValues: current.items.map {
            ($0.relativePath, $0)
        })
        let backupByPath = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.relativePath, $0)
        })
        let currentPaths = Set(currentByPath.keys)
        let backupPaths = Set(backupByPath.keys)
        let added = currentPaths.subtracting(backupPaths).sorted()
        let removed = backupPaths.subtracting(currentPaths).sorted()
        let changed = currentPaths.intersection(backupPaths).filter { path in
            currentByPath[path]?.sha256 != backupByPath[path]?.sha256
        }.sorted()
        let unchangedCount = currentPaths.intersection(backupPaths).count - changed.count
        let maximumReportedPaths = 500
        let truncated = added.count > maximumReportedPaths
            || removed.count > maximumReportedPaths
            || changed.count > maximumReportedPaths
        return AutomationStorageDiffResult(
            libraryID: context.id,
            backupPath: backupURL.path,
            added: Array(added.prefix(maximumReportedPaths)),
            removed: Array(removed.prefix(maximumReportedPaths)),
            changed: Array(changed.prefix(maximumReportedPaths)),
            unchangedCount: unchangedCount,
            truncated: truncated,
            message: current.failures.isEmpty
                ? "Compared current JSON/sidecar and enrichment files with the selected backup; no files were changed."
                : "Compared the selected backup, but some current files could not be read: \(current.failures.joined(separator: "; "))"
        )
    }

    private func storageResult(
        for session: LibrarySession,
        validation: String,
        validationMessage: String? = nil,
        message: String = "The App-owned Library storage layout was inspected.",
        validationError: Error? = nil,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot? = nil,
        includeMediaPresenceIssues: Bool = false,
        offset: Int = 0,
        limit: Int = 100
    ) -> AutomationStorageResult {
        let fileManager = FileManager.default
        let paths = session.context.paths
        let manifest = try? MusicLibraryManifest.read(from: paths.manifestURL)
        let rootPath = session.context.rootURL.standardizedFileURL.path
        let missingDirectories = paths.requiredDirectories.compactMap { url -> String? in
            guard !fileManager.fileExists(atPath: url.path) else { return nil }
            let path = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        let pageOffset = max(0, offset)
        let pageLimit = max(1, min(100, limit))
        var issues = missingDirectories.map { relativePath in
            AutomationStorageIssue(
                id: "missing-directory:\(relativePath)",
                code: "storage.required-directory.missing",
                path: session.context.rootURL.appendingPathComponent(relativePath).path,
                reason: "The App-owned Library directory is missing."
            )
        }
        if !fileManager.fileExists(atPath: paths.manifestURL.path) {
            issues.append(AutomationStorageIssue(
                id: "manifest-missing",
                code: "storage.manifest.missing",
                path: paths.manifestURL.path,
                reason: "The Library manifest file is missing."
            ))
        } else if manifest == nil {
            issues.append(AutomationStorageIssue(
                id: "manifest-invalid",
                code: "storage.manifest.invalid",
                path: paths.manifestURL.path,
                reason: "The Library manifest could not be decoded."
            ))
        }
        for reference in diskSnapshot?.playlistReferenceIssues ?? [] {
            for trackID in reference.missingTrackIDs {
                issues.append(AutomationStorageIssue(
                    id: "playlist-reference:\(reference.playlistID.uuidString):\(trackID.uuidString)",
                    code: "storage.playlist.reference-missing",
                    trackID: trackID,
                    path: paths.playlistURL(for: reference.playlistID).path,
                    reason: "Playlist \(reference.playlistName) references Track \(trackID.uuidString), which is absent from the Track index."
                ))
            }
        }
        if let validationError,
           let issue = storageValidationIssue(validationError, session: session, diskSnapshot: diskSnapshot) {
            if !issues.contains(where: { $0.id == issue.id }) { issues.append(issue) }
        }
        let media = includeMediaPresenceIssues
            ? mediaPresenceIssues(for: session.libraryViewModel.allTracks, in: session)
            : []
        let sortedIssues = issues.sorted { $0.id < $1.id }
        let sortedMedia = media.sorted { $0.id < $1.id }
        return AutomationStorageResult(
            libraryID: session.context.id,
            mode: session.context.mode.rawValue,
            rootPath: rootPath,
            schemaVersion: manifest?.schemaVersion,
            manifestPresent: fileManager.fileExists(atPath: paths.manifestURL.path),
            missingRequiredDirectories: missingDirectories,
            validation: validation,
            validationMessage: validationMessage,
            issues: Array(sortedIssues.dropFirst(pageOffset).prefix(pageLimit)),
            issueCount: sortedIssues.count,
            offset: pageOffset,
            limit: pageLimit,
            hasMore: pageOffset + pageLimit < sortedIssues.count,
            mediaIssues: Array(sortedMedia.dropFirst(pageOffset).prefix(pageLimit)),
            mediaIssueCount: sortedMedia.count,
            mediaHasMore: pageOffset + pageLimit < sortedMedia.count,
            message: message
        )
    }

    private func mediaPresenceIssues(
        for tracks: [Track],
        in session: LibrarySession
    ) -> [AutomationStorageIssue] {
        let fileManager = FileManager.default
        return tracks.compactMap { track in
            let candidates = AutomationFileAccess.automationTrackFileURLs(track, in: session)
                .map { $0.standardizedFileURL }
            if candidates.contains(where: { fileManager.fileExists(atPath: $0.path) && fileManager.isReadableFile(atPath: $0.path) }) {
                return nil
            }
            let paths = candidates.map(\.path)
            let expectedPath = paths.first ?? (track.originalFilePath.isEmpty ? nil : track.originalFilePath)
            let pathSummary = paths.isEmpty ? "No absolute media path is recorded." : "Recorded candidate paths: \(paths.joined(separator: ", "))."
            return AutomationStorageIssue(
                id: "media-path:\(track.id.uuidString)",
                code: "media.path.missing-or-inaccessible",
                trackID: track.id,
                path: expectedPath,
                reason: "None of the recorded paths currently exists and is readable by the App. This check does not decode the audio file, and it does not prove permanent deletion or distinguish an offline source from denied access. Cached availability is \(track.availability.rawValue). \(pathSummary)"
            )
        }
    }

    private func storageValidationIssue(
        _ error: Error,
        session: LibrarySession,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot?
    ) -> AutomationStorageIssue? {
        let paths = session.context.paths
        let reason = String(describing: error)
        let code: String
        let path: String
        switch error as? LibraryUpgradeValidationError {
        case .manifestMismatch:
            code = "storage.manifest.identity-mismatch"
            path = paths.manifestURL.path
        case .damagedTrackSidecar:
            code = "storage.track-sidecar.invalid"
            path = firstInvalidTrackSidecar(in: session) ?? paths.tracksRootURL.path
        case .damagedPlaylistSidecar:
            code = "storage.playlist-sidecar.invalid"
            path = firstInvalidPlaylistSidecar(in: session) ?? paths.playlistsRootURL.path
        case .duplicateTrackID:
            code = "storage.track-id.duplicate"
            path = paths.tracksRootURL.path
        case .trackCountMismatch:
            code = "storage.track-count.mismatch"
            path = session.context.rootURL.path
        case .playlistReferenceMissing:
            if let issue = diskSnapshot?.playlistReferenceIssues.first {
                code = "storage.playlist.reference-missing"
                path = paths.playlistURL(for: issue.playlistID).path
            } else {
                code = "storage.playlist.reference-missing"
                path = paths.playlistsRootURL.path
            }
        case .storageModeMismatch:
            code = "storage.mode.mismatch"
            path = paths.manifestURL.path
        case .trackIndexUnavailable, .trackIndexMismatch:
            code = "storage.track-index.invalid"
            path = paths.trackIndexStoreURL.path
        case .searchIndexMismatch:
            code = "storage.search-index.invalid"
            path = paths.searchIndexStoreURL.path
        case .historyStoreMismatch:
            code = "storage.playback-history.invalid"
            path = paths.playbackHistoryStoreURL.path
        case .sqliteIntegrityFailed(let fileName):
            code = "storage.sqlite.integrity-failed"
            path = [paths.trackIndexStoreURL, paths.searchIndexStoreURL, paths.playbackHistoryStoreURL]
                .first(where: { $0.lastPathComponent == fileName })?.path
                ?? session.context.rootURL.appendingPathComponent(fileName).path
        case .legacyIndexCleanupFailed:
            code = "storage.legacy-index.cleanup-failed"
            path = session.context.rootURL.path
        case .journalIdentityMismatch, .journalNotRegistered:
            code = "storage.journal.invalid"
            path = session.context.rootURL.path
        case nil:
            code = "storage.validation.failed"
            path = session.context.rootURL.path
        }
        let nextStep: String
        switch error as? LibraryUpgradeValidationError {
        case .manifestMismatch, .storageModeMismatch:
            nextStep = "Check the Library manifest against the active Library binding before taking further action."
        case .damagedTrackSidecar, .duplicateTrackID, .trackCountMismatch:
            nextStep = "Inspect the reported Tracks path and compare the sidecar entries with the App-owned Track index."
        case .damagedPlaylistSidecar, .playlistReferenceMissing:
            nextStep = "Inspect the reported Playlist sidecar and compare its Track IDs with the App-owned Track index."
        case .trackIndexUnavailable, .trackIndexMismatch:
            nextStep = "Preserve a backup before using an App-owned recovery flow if the mismatch remains."
        case .searchIndexMismatch:
            nextStep = "Allow the App-owned search index to finish rebuilding, then run storage.validate again."
        case .historyStoreMismatch, .sqliteIntegrityFailed:
            nextStep = "Preserve a backup before using an App-owned recovery or restore flow."
        case .legacyIndexCleanupFailed, .journalIdentityMismatch, .journalNotRegistered:
            nextStep = "Keep the Library unchanged and inspect the App-owned migration or recovery state."
        case nil:
            nextStep = "Inspect this App-owned Library location and rerun storage.validate for a focused result."
        }
        return AutomationStorageIssue(
            id: "\(code):\(path)",
            code: code,
            path: path,
            reason: "\(reason) \(nextStep)"
        )
    }

    private func firstInvalidTrackSidecar(in session: LibrarySession) -> String? {
        let root = session.context.paths.tracksRootURL
        let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = AutomationWireCoding.decoder()
        for directory in directories ?? [] {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metaURL = directory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(TrackSidecar.self, from: data),
                  UUID(uuidString: directory.lastPathComponent) == sidecar.id else {
                return metaURL.path
            }
        }
        return nil
    }

    private func firstInvalidPlaylistSidecar(in session: LibrarySession) -> String? {
        let root = session.context.paths.playlistsRootURL
        let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = AutomationWireCoding.decoder()
        for url in files ?? [] where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  (try? decoder.decode(PlaylistSidecar.self, from: data)) != nil else {
                return url.path
            }
        }
        return nil
    }

    private func diagnosticsIssues(
        tracks: [Track],
        sources: [ReferencedSourceDescriptor],
        jobs: [LibraryOperationTaskDescriptor],
        playlistReferences: [AutomationPlaylistReferenceIssue],
        storageError: Error?,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot?,
        in session: LibrarySession
    ) -> [AutomationDiagnosticIssue] {
        var issues: [AutomationDiagnosticIssue] = []
        for source in sources where source.status != .available {
            issues.append(AutomationDiagnosticIssue(
                id: "source:\(source.id.uuidString)",
                code: "source.\(source.status.rawValue)",
                sourceID: source.id,
                path: source.lastKnownPath,
                reason: "Source status is \(source.status.rawValue)."
            ))
        }
        for track in tracks {
            let path = AutomationFileAccess.automationTrackFileURL(track, in: session)?.path
            if track.availability != .available {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-availability:\(track.id.uuidString)",
                    code: "track.availability.\(track.availability.rawValue)",
                    trackID: track.id,
                    path: path,
                    reason: "Cached Track availability is \(track.availability.rawValue)."
                ))
            }
            if queries.trackLyricsStatus(track) == "none" {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-lyrics:\(track.id.uuidString)",
                    code: "track.lyrics.missing",
                    trackID: track.id,
                    path: path,
                    reason: "The Track has no persisted lyrics."
                ))
            }
            if !track.hasArtwork {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-artwork:\(track.id.uuidString)",
                    code: "track.artwork.missing",
                    trackID: track.id,
                    path: path,
                    reason: "The Track has no App-owned artwork."
                ))
            }
            let incompleteFields = ["title": track.title, "artist": track.artist, "album": track.album]
                .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.key)
                .sorted()
            if !incompleteFields.isEmpty {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-metadata:\(track.id.uuidString)",
                    code: "track.metadata.incomplete",
                    trackID: track.id,
                    path: path,
                    reason: "Missing metadata fields: \(incompleteFields.joined(separator: ", "))."
                ))
            }
        }
        for issue in playlistReferences {
            for trackID in issue.missingTrackIDs {
                issues.append(AutomationDiagnosticIssue(
                    id: "playlist-reference:\(issue.playlistID.uuidString):\(trackID.uuidString)",
                    code: "playlist.reference.missing-track",
                    trackID: trackID,
                    playlistID: issue.playlistID,
                    reason: "Playlist \(issue.playlistName) references a missing Track."
                ))
            }
        }
        for job in jobs where job.state == .failed || job.state == .partialFailure {
            issues.append(AutomationDiagnosticIssue(
                id: "job:\(job.id.uuidString)",
                code: "job.\(job.state.rawValue)",
                reason: job.partialFailureSummaries.prefix(3).joined(separator: "; ").isEmpty
                    ? "Job ended in state \(job.state.rawValue)."
                    : job.partialFailureSummaries.prefix(3).joined(separator: "; ")
            ))
        }
        if let storageError,
           let issue = storageValidationIssue(storageError, session: session, diskSnapshot: diskSnapshot) {
            issues.append(AutomationDiagnosticIssue(
                id: issue.id,
                code: issue.code,
                path: issue.path,
                reason: issue.reason
            ))
        }
        return issues.sorted { $0.id < $1.id }
    }
}
