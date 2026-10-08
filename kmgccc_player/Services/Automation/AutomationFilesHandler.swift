import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
struct AutomationFilesHandler {
    private let fileWorker: AutomationFileWorker
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?, fileWorker: AutomationFileWorker = AutomationFileWorker()) {
        self.fileWorker = fileWorker
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.filesInspect:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesInspect,
                        applied: false,
                        dryRun: true,
                        files: tracks.map { AutomationFileAccess.makeFileSummary($0) },
                        message: "Physical file state inspected; no file system mutation was applied."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesReveal:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                guard trackIDs.count <= 50 else {
                    throw AutomationParameterError.outOfRange("trackIDs")
                }
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                let dryRun = try parameters.boolean("dryRun", default: false)
                var files: [AutomationFileSummary] = []
                var urls: [URL] = []
                var failures: [String] = []
                for track in tracks {
                    do {
                        let url: URL
                        if case .referenced = track.mediaLocator {
                            url = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                        } else if let managedURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                            url = managedURL
                        } else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        urls.append(url)
                        files.append(AutomationFileAccess.makeFileSummary(track, pathOverride: url.path, existsOverride: true))
                    } catch {
                        failures.append("\(track.id.uuidString): \(error.localizedDescription)")
                    }
                }
                if !dryRun, !urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesReveal,
                        applied: !dryRun && !urls.isEmpty,
                        dryRun: dryRun,
                        affectedTrackIDs: files.map(\.trackID),
                        files: files,
                        failures: failures,
                        message: dryRun
                            ? "Preview only. Authorized existing files would be revealed in Finder."
                            : "Authorized existing files were revealed in Finder."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                guard trackIDs.count <= 500 else {
                    throw AutomationParameterError.outOfRange("trackIDs")
                }
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                guard let destinationURL = await AutomationInteraction.requestExportDirectory() else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard sessionAccess.activeSession(for: request) === session else {
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                let hasScopedAccess = destinationURL.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { destinationURL.stopAccessingSecurityScopedResource() }
                }
                let destination = destinationURL.standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw AutomationParameterError.invalidValue("destination folder")
                }
                let libraryRoot = session.context.rootURL.standardizedFileURL
                guard destination.path != libraryRoot.path,
                      !destination.path.hasPrefix(libraryRoot.path + "/") else {
                    throw AutomationParameterError.invalidValue("destination folder inside active Library")
                }

                let (files, failures) = try await session.runLibraryOperation(as: .other) {
                    var files: [AutomationFileSummary] = []
                    var failures: [String] = []
                    for track in tracks {
                        do {
                            let source: URL
                            if case .referenced = track.mediaLocator {
                                source = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                            } else if let managed = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                                source = managed
                            } else {
                                throw AutomationFileOperationError.fileUnavailable(track.id)
                            }
                            let output = try await fileWorker.copy(source: source, trackID: track.id, to: destination)
                            files.append(AutomationFileAccess.makeFileSummary(track, pathOverride: output.path, existsOverride: true))
                        } catch {
                            failures.append("\(track.id.uuidString): \(error.localizedDescription)")
                        }
                    }
                    return (files, failures)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesExport,
                        applied: !files.isEmpty,
                        dryRun: false,
                        affectedTrackIDs: files.map(\.trackID),
                        files: files,
                        failures: failures,
                        message: "Audio files were copied to the App-authorized destination; Library originals were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesRename, AutomationMethod.filesMove:
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
                let operations = try parameters.objectArray("operations", required: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let plans = try makeFilePlans(
                    method: request.method,
                    operations: operations,
                    session: session
                )
                let files = plans.map { AutomationFileAccess.makeFileSummary($0.track) }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationFileOperationResult(
                            operation: request.method,
                            applied: false,
                            dryRun: true,
                            affectedTrackIDs: plans.map(\.trackID),
                            files: files,
                            message: "Preview only. Set dryRun=false to apply the planned file operation."
                        ),
                        for: request
                    )
                }

                let isTrusted = plans.allSatisfy { plan in
                    guard let sourceScope = session.referencedSourceScope else { return false }
                    return sourceScope.isTrustedAutomationPath(plan.from)
                        && (plan.destination.map { sourceScope.isTrustedAutomationPath($0) } ?? true)
                }
                if plans.count > 1 && !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量重命名或移动文件需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(request.method),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: request.method == AutomationMethod.filesRename
                            ? "重命名多个音乐文件？"
                            : "移动多个音乐文件？",
                        message: "这会改变 \(plans.count) 个音乐文件在磁盘上的位置，播放器随后会重新扫描相关来源。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                try await session.runLibraryOperation(as: .other) {
                    try await fileWorker.move(plans.compactMap { plan in
                        plan.destination.map { AutomationFileWorker.Move(from: plan.from, destination: $0) }
                    })
                }
                let sourceIDs = Set(plans.flatMap(\.sourceIDs))
                let jobs = sourceRefreshJobs(
                    sourceIDs: sourceIDs,
                    appSession: appSession,
                    libraryID: session.context.id
                )
                let appliedFiles = plans.map { plan in
                    AutomationFileAccess.makeFileSummary(
                        plan.track,
                        pathOverride: plan.destination?.path,
                        existsOverride: plan.destination.map { FileManager.default.fileExists(atPath: $0.path) }
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: request.method,
                        applied: true,
                        dryRun: false,
                        confirmed: plans.count > 1 && (confirm || isTrusted),
                        affectedTrackIDs: plans.map(\.trackID),
                        files: appliedFiles,
                        jobs: jobs,
                        message: "File operation applied. Source reconciliation Jobs were started to update Track locations."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "The file operation failed; no further file mutation was attempted.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.filesDelete:
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
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let plans = try makeFileDeletePlans(trackIDs: trackIDs, session: session)
                let files = plans.map { AutomationFileAccess.makeFileSummary($0.track) }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationFileOperationResult(
                            operation: AutomationMethod.filesDelete,
                            applied: false,
                            dryRun: true,
                            affectedTrackIDs: plans.map(\.trackID),
                            files: files,
                            message: "Preview only. Files will be moved to the macOS Trash after confirm=true and foreground confirmation. Tracks and Playlist membership will be preserved."
                        ),
                        for: request
                    )
                }
                let isTrusted = plans.allSatisfy { plan in
                    session.referencedSourceScope?.isTrustedAutomationPath(plan.from) == true
                }
                if !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "将音乐文件移到废纸篓需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.filesDelete),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "将音乐文件移到废纸篓？",
                        message: "要将 \(plans.count) 个音乐文件移到 macOS 废纸篓吗？歌曲、元数据、播放记录和播放列表关系会保留。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                let outcome = try await session.runLibraryOperation(as: .other) {
                    var succeeded: [UUID] = []
                    var failures: [String] = []
                    for plan in plans {
                        do {
                            try await MacOSLibraryRecycler().recycle(plan.from)
                            succeeded.append(plan.trackID)
                        } catch {
                            failures.append("\(plan.trackID.uuidString): \(error.localizedDescription)")
                        }
                    }
                    return (succeeded, failures)
                }
                let successfulPlans = plans.filter { outcome.0.contains($0.trackID) }
                let jobs = sourceRefreshJobs(
                    sourceIDs: Set(successfulPlans.flatMap(\.sourceIDs)),
                    appSession: appSession,
                    libraryID: session.context.id
                )
                let appliedFiles = plans.map { plan in
                    AutomationFileAccess.makeFileSummary(
                        plan.track,
                        existsOverride: outcome.0.contains(plan.trackID) ? false : nil
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesDelete,
                        applied: !outcome.0.isEmpty,
                        dryRun: false,
                        confirmed: confirm || isTrusted,
                        affectedTrackIDs: outcome.0,
                        files: appliedFiles,
                        jobs: jobs,
                        failures: outcome.1,
                        message: "Selected files were moved to the macOS Trash; the App started Source refresh Jobs to mark them missing without deleting Library records."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "The file deletion operation failed.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private struct AutomationFilePlan {
        let track: Track
        let trackID: UUID
        let from: URL
        let destination: URL?
        let sourceIDs: Set<UUID>
    }

    private func makeFilePlans(
        method: String,
        operations: [[String: AutomationJSONValue]],
        session: LibrarySession
    ) throws -> [AutomationFilePlan] {
        guard session.context.mode == .referenced,
              let sourceScope = session.referencedSourceScope else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let tracksByID = Dictionary(
            uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
        )
        var seenTrackIDs = Set<UUID>()
        var plans: [AutomationFilePlan] = []

        for operation in operations {
            guard case let .string(rawTrackID) = operation["trackID"],
                  let trackID = UUID(uuidString: rawTrackID),
                  seenTrackIDs.insert(trackID).inserted else {
                throw AutomationParameterError.invalidValue("operations.trackID")
            }
            guard let track = tracksByID[trackID] else {
                throw AutomationFileOperationError.trackNotFound(trackID)
            }
            let current = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session)
            let destination: URL

            if method == AutomationMethod.filesRename {
                guard case let .string(rawName) = operation["name"] else {
                    throw AutomationParameterError.missing("operations.name")
                }
                let name = try normalizedFileName(rawName, preservingExtensionOf: current.url)
                destination = current.url.deletingLastPathComponent()
                    .appendingPathComponent(name)
                    .standardizedFileURL
            } else {
                guard case let .string(rawSourceID) = operation["sourceID"],
                      let sourceID = UUID(uuidString: rawSourceID) else {
                    throw AutomationParameterError.invalidValue("operations.sourceID")
                }
                guard case let .string(rawRelativePath) = operation["relativePath"] else {
                    throw AutomationParameterError.missing("operations.relativePath")
                }
                let relativePath = rawRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let root = try AutomationFileAccess.authorizedDirectoryRoot(sourceID: sourceID, sourceScope: sourceScope)
                guard TrackMediaLocator.isSafeRelativePath(relativePath) else {
                    throw AutomationFileOperationError.unsafeRelativePath(relativePath)
                }
                destination = root.appendingPathComponent(relativePath).standardizedFileURL
                guard AutomationFileAccess.isAuthorizedPath(destination, inside: root) else {
                    throw AutomationFileOperationError.unsafeRelativePath(relativePath)
                }
            }

            guard current.url.path != destination.path else {
                throw AutomationFileOperationError.destinationIsCurrentFile(destination.path)
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw AutomationFileOperationError.destinationExists(destination.path)
            }
            var affectedSourceIDs = current.sourceIDs
            if method == AutomationMethod.filesMove,
               case let .string(rawSourceID) = operation["sourceID"],
               let destinationSourceID = UUID(uuidString: rawSourceID) {
                affectedSourceIDs.insert(destinationSourceID)
            }
            plans.append(
                AutomationFilePlan(
                    track: track,
                    trackID: trackID,
                    from: current.url,
                    destination: destination,
                    sourceIDs: affectedSourceIDs
                )
            )
        }

        let destinationPaths = plans.compactMap(\.destination).map { $0.path }
        guard Set(destinationPaths).count == destinationPaths.count else {
            throw AutomationFileOperationError.duplicateDestination
        }
        let sourcePaths = Set(plans.map { $0.from.path })
        guard plans.compactMap(\.destination).allSatisfy({ !sourcePaths.contains($0.path) }) else {
            throw AutomationFileOperationError.destinationOverlapsSelection
        }
        return plans
    }

    private func makeFileDeletePlans(
        trackIDs: [UUID],
        session: LibrarySession
    ) throws -> [AutomationFilePlan] {
        guard session.context.mode == .referenced else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
        return try tracks.map { track in
            let current = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session)
            return AutomationFilePlan(
                track: track,
                trackID: track.id,
                from: current.url,
                destination: nil,
                sourceIDs: current.sourceIDs
            )
        }
    }

    private func normalizedFileName(
        _ rawName: String,
        preservingExtensionOf source: URL
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw AutomationFileOperationError.invalidFileName
        }
        if source.pathExtension.isEmpty || name.contains(".") {
            return name
        }
        return "\(name).\(source.pathExtension)"
    }

    private func sourceRefreshJobs(
        sourceIDs: Set<UUID>,
        appSession: AppSessionHost,
        libraryID: UUID
    ) -> [AutomationJobSummary] {
        sourceIDs
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { sourceID in
                appSession.startSourceRefreshJob(sourceID: sourceID, libraryID: libraryID)
            }
            .map(AutomationJobProjection.makeJobSummary)
    }
}
