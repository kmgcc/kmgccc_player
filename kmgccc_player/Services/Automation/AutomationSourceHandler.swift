import CryptoKit
import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationSourceHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.sourceList:
            guard sessionAccess.activeSession(for: request) != nil else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
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
                let descriptors = try await appSession.referencedSources()
                let sources = descriptors.map { descriptor in
                    makeSourceSummary(descriptor)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceListResult(sources: sources),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to read referenced source state.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.sourceGet:
            guard sessionAccess.activeSession(for: request)?.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                guard let descriptor = try await appSession.referencedSources().first(where: { $0.id == sourceID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Source does not exist.", details: .object(["sourceID": .string(sourceID.uuidString)])))
                }
                return AutomationResponseSupport.encodeResult(AutomationSourceGetResult(source: makeSourceSummary(descriptor)), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceConfigExport:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let descriptors = try await appSession.referencedSources()
                let configurations = descriptors.map(makeSourceConfiguration)
                let document = AutomationSourceConfigurationDocument(
                    originLibraryID: session.context.id,
                    sources: configurations
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceConfigurationExportResult(
                        libraryID: session.context.id,
                        revision: sourceConfigurationRevision(
                            libraryID: session.context.id,
                            configurations: configurations
                        ),
                        document: document
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to export Source policy configuration.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.sourceConfigImport:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                guard let rawDocument = parameters.values["document"] else {
                    throw AutomationParameterError.missing("document")
                }
                let documentData = try AutomationWireCoding.encoder().encode(rawDocument)
                let document = try AutomationWireCoding.decoder().decode(
                    AutomationSourceConfigurationDocument.self,
                    from: documentData
                )
                guard document.schemaVersion == 1,
                      document.sources.count <= 100,
                      Set(document.sources.map(\.sourceID)).count == document.sources.count else {
                    throw AutomationParameterError.invalidValue("document")
                }
                let sourceIDMapValues = try parameters.object("sourceIDMap") ?? [:]
                guard sourceIDMapValues.count <= 100 else {
                    throw AutomationParameterError.outOfRange("sourceIDMap")
                }
                var sourceIDMap: [UUID: UUID] = [:]
                for (rawSourceID, rawTargetID) in sourceIDMapValues {
                    guard let sourceID = UUID(uuidString: rawSourceID),
                          case .string(let targetIDString) = rawTargetID,
                          let targetID = UUID(uuidString: targetIDString) else {
                        throw AutomationParameterError.invalidValue("sourceIDMap")
                    }
                    sourceIDMap[sourceID] = targetID
                }
                let exportedIDs = Set(document.sources.map(\.sourceID))
                guard Set(sourceIDMap.keys).isSubset(of: exportedIDs) else {
                    throw AutomationParameterError.invalidValue("sourceIDMap")
                }
                if document.originLibraryID != session.context.id,
                   !document.sources.isEmpty,
                   Set(sourceIDMap.keys) != exportedIDs {
                    throw AutomationParameterError.invalidValue("sourceIDMap.crossLibraryRequired")
                }

                let currentSources = try await appSession.referencedSources()
                let currentByID = Dictionary(uniqueKeysWithValues: currentSources.map { ($0.id, $0) })
                let currentConfigurations = currentSources.map(makeSourceConfiguration)
                let currentRevision = sourceConfigurationRevision(
                    libraryID: session.context.id,
                    configurations: currentConfigurations
                )
                if let expectedRevision = try parameters.string("expectedRevision"),
                   expectedRevision != currentRevision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: currentRevision)
                }

                var targetConfigurations: [AutomationSourceConfiguration] = []
                var usedTargetIDs = Set<UUID>()
                var totalExcludedPathCount = 0
                for configuration in document.sources {
                    let displayName = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let targetID = sourceIDMap[configuration.sourceID] ?? configuration.sourceID
                    guard !displayName.isEmpty,
                          displayName.count <= 120,
                          let policy = ReferencedSourceMonitorPolicy(rawValue: configuration.monitorPolicy),
                          usedTargetIDs.insert(targetID).inserted,
                          let current = currentByID[targetID] else {
                        throw AutomationParameterError.invalidValue("document.sources")
                    }
                    guard Set(configuration.excludedRelativePaths).count == configuration.excludedRelativePaths.count,
                          configuration.excludedRelativePaths.allSatisfy({
                              TrackMediaLocator.isSafeRelativePath($0) && $0.count <= 1024
                          }) else {
                        throw AutomationParameterError.invalidValue("document.sources.excludedRelativePaths")
                    }
                    totalExcludedPathCount += configuration.excludedRelativePaths.count
                    guard totalExcludedPathCount <= 1_000,
                          current.mode == .directory || configuration.excludedRelativePaths.isEmpty else {
                        throw AutomationParameterError.invalidValue("document.sources")
                    }
                    targetConfigurations.append(AutomationSourceConfiguration(
                        sourceID: targetID,
                        displayName: displayName,
                        monitorPolicy: policy.rawValue,
                        excludedRelativePaths: configuration.excludedRelativePaths
                    ))
                }
                let changed = targetConfigurations.filter { configuration in
                    guard let current = currentByID[configuration.sourceID] else { return true }
                    return makeSourceConfiguration(current) != configuration
                }
                let unchangedIDs = targetConfigurations.map(\.sourceID).filter { targetID in
                    !changed.contains(where: { $0.sourceID == targetID })
                }
                var previewByID = Dictionary(
                    uniqueKeysWithValues: currentConfigurations.map { ($0.sourceID, $0) }
                )
                for configuration in targetConfigurations {
                    previewByID[configuration.sourceID] = configuration
                }
                let previewConfigurations = Array(previewByID.values)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceConfigurationImportResult(
                            libraryID: session.context.id,
                            applied: false,
                            dryRun: true,
                            revision: currentRevision,
                            configurations: previewConfigurations,
                            unchangedSourceIDs: unchangedIDs
                        ),
                        for: request
                    )
                }
                guard !changed.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceConfigurationImportResult(
                            libraryID: session.context.id,
                            applied: false,
                            dryRun: false,
                            revision: currentRevision,
                            configurations: previewConfigurations,
                            unchangedSourceIDs: unchangedIDs
                        ),
                        for: request
                    )
                }
                guard try parameters.boolean("confirm", default: false) else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Apply the Source policy changes from this configuration?",
                        details: .object([
                            "sourceCount": .number(Double(changed.count)),
                            "expectedRevision": .string(currentRevision),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导入来源配置？",
                    message: "这会更新来源显示名、自动监听策略和排除路径；未授权路径与书签会留在本机。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }

                var failures: [AutomationSourceConfigurationFailure] = []
                for configuration in changed {
                    guard let current = currentByID[configuration.sourceID] else { continue }
                    do {
                        if current.displayName != configuration.displayName {
                            _ = try await appSession.renameReferencedSource(
                                id: configuration.sourceID,
                                displayName: configuration.displayName,
                                libraryID: session.context.id
                            )
                        }
                        if current.monitorPolicy.rawValue != configuration.monitorPolicy,
                           let policy = ReferencedSourceMonitorPolicy(rawValue: configuration.monitorPolicy) {
                            try await appSession.setReferencedSourceMonitorPolicy(
                                id: configuration.sourceID,
                                policy: policy,
                                libraryID: session.context.id
                            )
                        }
                        let previousExclusions = Set(current.excludedRelativePaths)
                        let nextExclusions = Set(configuration.excludedRelativePaths)
                        for path in previousExclusions.subtracting(nextExclusions).sorted() {
                            try await appSession.setReferencedSourceExcludedPath(
                                id: configuration.sourceID,
                                relativePath: path,
                                excluded: false,
                                libraryID: session.context.id
                            )
                        }
                        for path in nextExclusions.subtracting(previousExclusions).sorted() {
                            try await appSession.setReferencedSourceExcludedPath(
                                id: configuration.sourceID,
                                relativePath: path,
                                excluded: true,
                                libraryID: session.context.id
                            )
                        }
                    } catch {
                        failures.append(AutomationSourceConfigurationFailure(
                            sourceID: configuration.sourceID,
                            message: "The Source update stopped after an App persistence error."
                        ))
                    }
                }
                let finalSources = try await appSession.referencedSources()
                let finalConfigurations = finalSources.map(makeSourceConfiguration)
                let finalByID = Dictionary(uniqueKeysWithValues: finalSources.map { ($0.id, $0) })
                let updatedIDs = changed.compactMap { configuration -> UUID? in
                    guard let before = currentByID[configuration.sourceID],
                          let after = finalByID[configuration.sourceID],
                          makeSourceConfiguration(before) != makeSourceConfiguration(after) else {
                        return nil
                    }
                    return configuration.sourceID
                }
                let finalRevision = sourceConfigurationRevision(
                    libraryID: session.context.id,
                    configurations: finalConfigurations
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceConfigurationImportResult(
                        libraryID: session.context.id,
                        applied: !updatedIDs.isEmpty,
                        dryRun: false,
                        revision: finalRevision,
                        configurations: finalConfigurations,
                        updatedSourceIDs: updatedIDs,
                        unchangedSourceIDs: unchangedIDs,
                        failures: failures
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRename:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 120 else {
                    throw AutomationParameterError.invalidValue("displayName")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let current = try await appSession.referencedSources().first(where: { $0.id == sourceID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Source does not exist.", details: .object(["sourceID": .string(sourceID.uuidString)])))
                }
                if dryRun {
                    var preview = current
                    preview.displayName = displayName
                    return AutomationResponseSupport.encodeResult(AutomationSourceRenameResult(source: makeSourceSummary(preview), applied: false, dryRun: true), for: request)
                }
                let renamed = try await appSession.renameReferencedSource(
                    id: sourceID,
                    displayName: displayName,
                    libraryID: session.context.id
                )
                return AutomationResponseSupport.encodeResult(AutomationSourceRenameResult(source: makeSourceSummary(renamed), applied: true, dryRun: false), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRefresh:
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
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard session.context.mode == .referenced else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                let descriptors = try await appSession.referencedSources()
                guard let descriptor = descriptors.first(where: { $0.id == sourceID }) else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceRefreshResult(
                            sourceID: sourceID,
                            applied: false,
                            dryRun: true,
                            source: makeSourceSummary(descriptor),
                            libraryTrackCount: session.libraryViewModel.allTracks.count,
                            message: "Preview only. Set dryRun=false to scan and import new files."
                        ),
                        for: request
                    )
                }
                guard let job = appSession.startSourceRefreshJob(
                    sourceID: sourceID,
                    libraryID: session.context.id
                ) else {
                    throw AutomationParameterError.invalidValue("sourceID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceRefreshResult(
                        sourceID: sourceID,
                        applied: false,
                        dryRun: false,
                        source: makeSourceSummary(descriptor),
                        libraryTrackCount: session.libraryViewModel.allTracks.count,
                        issues: [],
                        completed: false,
                        job: AutomationJobProjection.makeJobSummary(job),
                        message: "Source refresh started as a Job; existing Tracks will be reused."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceCreate:
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
                guard session.context.mode == .referenced else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let parameters = try AutomationParameters(request)
                let modeRaw = try parameters.string("mode") ?? ReferencedSourceMode.directory.rawValue
                guard let mode = ReferencedSourceMode(rawValue: modeRaw) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let requestedPath = try parameters.string("path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let playlistID = try parameters.uuid("playlistID")
                let dryRun = try parameters.boolean("dryRun", default: false)
                if let playlistID,
                   !session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            selectedPath: requestedPath,
                            message: "Preview only. The App will request a security-scoped folder/file selection when needed."
                        ),
                        for: request
                    )
                }

                let descriptors = try await appSession.referencedSources()
                let normalizedRequestedPath = requestedPath.map(AutomationInteraction.expandPath(_:))
                if let requestedPath = normalizedRequestedPath,
                   let existing = descriptors.first(where: { descriptor in
                       descriptor.mode == mode
                           && URL(fileURLWithPath: descriptor.lastKnownPath)
                               .standardizedFileURL.path == requestedPath
                   }) {
                    if let playlistID {
                        try await appSession.bindReferencedSource(
                            id: existing.id,
                            to: playlistID,
                            libraryID: session.context.id
                        )
                    }
                    let refreshed = try await appSession.referencedSources()
                        .first(where: { $0.id == existing.id }) ?? existing
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            playlistBindingApplied: playlistID != nil,
                            source: makeSourceSummary(refreshed),
                            selectedPath: refreshed.lastKnownPath,
                            message: playlistID == nil
                                ? "The requested Source already exists; no duplicate Source was created."
                                : "The requested Source already exists; no duplicate Source was created and the Playlist binding was applied."
                        ),
                        for: request
                    )
                }

                let inheritedAuthorization: Bool = {
                    guard let requestedPath = normalizedRequestedPath else { return false }
                    let requestedURL = URL(fileURLWithPath: requestedPath, isDirectory: mode == .directory)
                    guard FileManager.default.fileExists(atPath: requestedURL.path) else { return false }
                    let isDirectory = (try? requestedURL.resourceValues(
                        forKeys: [.isDirectoryKey]
                    ).isDirectory) == true
                    guard isDirectory == (mode == .directory) else { return false }
                    guard let sourceScope = session.referencedSourceScope else { return false }
                    return sourceScope.authorizedDirectorySourceID(containing: requestedURL) != nil
                        || sourceScope.isTrustedAutomationPath(requestedURL)
                }()
                let selectedURL: URL?
                if inheritedAuthorization, let normalizedRequestedPath {
                    selectedURL = URL(
                        fileURLWithPath: normalizedRequestedPath,
                        isDirectory: mode == .directory
                    )
                } else {
                    selectedURL = try await AutomationInteraction.requestSourceURL(
                        mode: mode,
                        requestedPath: normalizedRequestedPath
                    )
                }
                guard let selectedURL else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess || inheritedAuthorization else {
                    let path = selectedURL.path
                    selection.release()
                    return AutomationResponseSupport.permissionDenied(
                        for: request,
                        path: path
                    )
                }
                guard let job = appSession.startSourceImportJob(
                    selection: selection,
                    playlistID: playlistID,
                    libraryID: session.context.id
                ) else {
                    selection.release()
                    throw AutomationParameterError.invalidValue("path")
                }
                selection.release()
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: false,
                        completed: false,
                        selectedPath: selectedURL.path,
                        job: AutomationJobProjection.makeJobSummary(job),
                        message: playlistID == nil
                            ? "Source authorization accepted; import/reconcile started as a Job."
                            : "Source authorization accepted; import/reconcile and Playlist binding started as a Job."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceBindPlaylist:
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
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let relativePath = try parameters.string("relativePath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                if let relativePath, !relativePath.isEmpty,
                   !TrackMediaLocator.isSafeRelativePath(relativePath) {
                    throw AutomationParameterError.invalidValue("relativePath")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. The Source-to-Playlist binding will be persisted."
                        ),
                        for: request
                    )
                }
                try await appSession.bindReferencedSource(
                    id: sourceID,
                    to: playlistID,
                    relativePath: relativePath,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: "Source-to-Playlist binding updated."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetExcludedPath:
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
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let relativePath = try parameters.string("relativePath", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let excluded = try parameters.boolean("excluded", default: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !relativePath.isEmpty,
                      TrackMediaLocator.isSafeRelativePath(relativePath) else {
                    throw AutomationParameterError.invalidValue("relativePath")
                }
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                guard descriptor.mode == .directory else {
                    throw AutomationParameterError.invalidValue("sourceID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: excluded
                                ? "Preview only. The relative path will be excluded from future scans; existing Track authority is preserved."
                                : "Preview only. The relative path will be included in future scans."
                        ),
                        for: request
                    )
                }
                try await appSession.setReferencedSourceExcludedPath(
                    id: sourceID,
                    relativePath: relativePath,
                    excluded: excluded,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: excluded
                            ? "Source path excluded; existing Tracks were retained."
                            : "Source path included and the Source was reconciled."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetMonitorPolicy:
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
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let rawPolicy = try parameters.string("policy", required: true)!
                guard let policy = ReferencedSourceMonitorPolicy(rawValue: rawPolicy),
                      policy != .inherit else {
                    throw AutomationParameterError.invalidValue("policy")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. Automatic monitoring will be \(policy == .on ? "enabled" : "disabled"); explicit source.refresh remains available."
                        ),
                        for: request
                    )
                }
                try await appSession.setReferencedSourceMonitorPolicy(
                    id: sourceID,
                    policy: policy,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: policy == .on
                            ? "Automatic Source monitoring enabled."
                            : "Automatic Source monitoring disabled; manual refresh remains available."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRemove:
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
                let sourceID = try parameters.uuid("id", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("id")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. Removing the Source authority retains user files; Tracks with no other source become missing."
                        ),
                        for: request
                    )
                }
                let isTrusted = session.referencedSourceScope?.isTrustedAutomationPath(
                    URL(fileURLWithPath: descriptor.lastKnownPath)
                ) == true
                if !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "移除来源需要 confirm=true，并由播放器在前台确认。",
                            details: .object(["sourceID": .string(sourceID.uuidString)])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "移除来源？",
                        message: "要从当前资料库移除“\(descriptor.displayName)”吗？原文件不会删除，相关歌曲可能暂时不可用。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }
                try await appSession.removeReferencedSource(
                    id: sourceID,
                    libraryID: session.context.id
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        selectedPath: descriptor.lastKnownPath,
                        message: "Source removed; physical files were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func makeSourceSummary(
        _ descriptor: ReferencedSourceDescriptor
    ) -> AutomationSourceSummary {
        AutomationSourceSummary(
            id: descriptor.id,
            mode: descriptor.mode.rawValue,
            displayName: descriptor.displayName,
            path: descriptor.lastKnownPath,
            status: descriptor.status.rawValue,
            lastScan: descriptor.lastScan,
            playlistIDs: descriptor.playlistBindings.map(\.playlistID),
            excludedRelativePaths: descriptor.excludedRelativePaths,
            monitorPolicy: descriptor.monitorPolicy.rawValue
        )
    }

    private func makeSourceConfiguration(
        _ descriptor: ReferencedSourceDescriptor
    ) -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(
            sourceID: descriptor.id,
            displayName: descriptor.displayName,
            monitorPolicy: descriptor.monitorPolicy.rawValue,
            excludedRelativePaths: descriptor.excludedRelativePaths
        )
    }

    private func sourceConfigurationRevision(
        libraryID: UUID,
        configurations: [AutomationSourceConfiguration]
    ) -> String {
        let document = AutomationSourceConfigurationDocument(
            originLibraryID: libraryID,
            sources: configurations
        )
        guard let data = try? AutomationWireCoding.encoder().encode(document) else {
            return "source-config-v1-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "source-config-v1-" + digest
    }

    private func sourceIssueMessage(_ issue: ReferencedSourceScopeIssue) -> String {
        switch issue {
        case .offline(let sourceID):
            return "\(sourceID.uuidString): offline"
        case .permissionDenied(let sourceID):
            return "\(sourceID.uuidString): permission denied"
        case .staleRefreshFailed(let sourceID):
            return "\(sourceID.uuidString): stale bookmark refresh failed"
        case .statusPersistenceFailed(let sourceID):
            return "\(sourceID.uuidString): status persistence failed"
        }
    }
}
