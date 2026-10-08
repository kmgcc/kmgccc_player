import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationLibraryHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }
    private let selectionStore: AutomationSelectionStore

    init(appSession: AppSessionHost?, selectionStore: AutomationSelectionStore) {
        self.appSession = appSession
        self.selectionStore = selectionStore
    }

    func handle(
        _ request: AutomationRequest,
        grantedScopes: @MainActor () -> Set<AutomationScope>
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.libraryList:
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
            let registry = await appSession.musicLibraryRegistrySnapshot()
            let summaries = registry.libraries.map {
                queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationLibraryListResult(
                    libraries: summaries,
                    activeLibraryID: registry.activeLibraryID
                ),
                for: request
            )

        case AutomationMethod.libraryGet:
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let bookmark = registry.libraries.first(where: { $0.id == libraryID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Library is not registered.", details: .object(["libraryID": .string(libraryID.uuidString)])))
                }
                return AutomationResponseSupport.encodeResult(AutomationLibraryGetResult(
                    library: queries.makeLibrarySummary(bookmark, activeLibraryID: registry.activeLibraryID),
                    activeLibraryID: registry.activeLibraryID
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryCreate:
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
                let modeRaw = try parameters.string("mode", required: true)!
                guard let mode = MusicLibraryMode(rawValue: modeRaw) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 255 else {
                    throw AutomationParameterError.outOfRange("displayName")
                }
                let requestedParentPath = try parameters.string("parentPath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let allowAlternateDestination = try parameters.boolean(
                    "allowAlternateDestinationWhenOccupied",
                    default: false
                )
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: false,
                            dryRun: true,
                            path: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for a parent folder, create the library root without overwriting unknown files, and activate the new library after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "创建资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryCreate),
                            "mode": .string(mode.rawValue),
                            "displayName": .string(displayName)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "创建并切换资料库？",
                    message: "要创建“\(displayName)”资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择资料库位置",
                    prompt: "选择",
                    allowsCreatingDirectories: true
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let result = try await appSession.createMusicLibrary(
                    mode: mode,
                    parentURL: selectedURL,
                    displayName: displayName,
                    initialImportSelection: nil,
                    initialImportPolicy: .background,
                    allowAlternateDestinationWhenOccupied: allowAlternateDestination
                )
                let registry = await appSession.musicLibraryRegistrySnapshot()
                switch result {
                case .created(let context, _):
                    let summary = registry.library(id: context.id).map {
                        queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: true,
                            dryRun: false,
                            confirmed: true,
                            libraryID: context.id,
                            library: summary,
                            activeLibraryID: registry.activeLibraryID,
                            path: context.rootURL.path,
                            message: "Library created and activated."
                        ),
                        for: request
                    )
                case .existingLibrary(let context):
                    let summary = registry.library(id: context.id).map {
                        queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: false,
                            dryRun: false,
                            confirmed: true,
                            libraryID: context.id,
                            library: summary,
                            activeLibraryID: registry.activeLibraryID,
                            path: context.rootURL.path,
                            message: "A library already exists at the selected location; no new library was created."
                        ),
                        for: request
                    )
                case .existingLibraryModeMismatch(let context, let requestedMode):
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "A library already exists at the selected location with a different storage mode.",
                            details: .object([
                                "libraryID": .string(context.id.uuidString),
                                "requestedMode": .string(requestedMode.rawValue),
                                "actualMode": .string(context.mode.rawValue),
                                "path": .string(context.rootURL.path)
                            ])
                        )
                    )
                }
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryOpen:
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
                let requestedPath = try parameters.string("path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryOpen,
                            applied: false,
                            dryRun: true,
                            path: requestedPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for the existing library folder, register it if needed, and activate it after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "打开资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["operation": .string(AutomationMethod.libraryOpen)])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "打开并切换资料库？",
                    message: "要打开所选资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择现有资料库",
                    prompt: "打开",
                    allowsCreatingDirectories: false
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let unavailableSourceIDs = try await appSession.openMusicLibrary(at: selectedURL)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = registry.activeLibraryID
                let active = activeID.flatMap(registry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryOpen,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: activeID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library opened and activated."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.librarySwitch:
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
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.librarySwitch,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. Set dryRun=false and confirm=true to activate this registered library."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "切换当前资料库需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.librarySwitch),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard libraryID != registry.activeLibraryID else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.librarySwitch,
                            applied: false,
                            dryRun: false,
                            confirmed: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "The requested library is already active."
                        ),
                        for: request
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "切换当前资料库？",
                    message: "要切换到“\(target.displayName)”吗？当前播放会话将关闭并重新打开所选资料库。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let unavailableSourceIDs = try await appSession.activateRegisteredLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updatedActiveID = updatedRegistry.activeLibraryID
                let active = updatedActiveID.flatMap(updatedRegistry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.librarySwitch,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: updatedActiveID) },
                        activeLibraryID: updatedActiveID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library switched and activated."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRename:
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
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 255 else {
                    throw AutomationParameterError.outOfRange("displayName")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRename,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. The display name will change; library files and storage mode will remain unchanged."
                        ),
                        for: request
                    )
                }
                try await appSession.renameMusicLibrary(id: libraryID, displayName: displayName)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updated = updatedRegistry.library(id: libraryID)
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRename,
                        applied: true,
                        dryRun: false,
                        libraryID: libraryID,
                        library: updated.map { queries.makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: updated?.lastKnownPath ?? target.lastKnownPath,
                        message: "Library renamed."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRelocate:
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
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let requestedParentPath = try parameters.string("parentPath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRelocate,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for a destination parent folder and move the complete library through its recovery transaction after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "迁移资料库会改变磁盘上的文件位置，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRelocate),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "迁移资料库？",
                    message: "要将“\(target.displayName)”移动到新位置吗？移动后当前播放会话将重新打开。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择新的资料库位置",
                    prompt: "移到这里",
                    allowsCreatingDirectories: true
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let result = try await appSession.relocateMusicLibrary(id: libraryID, to: selectedURL)
                let newContext: LibraryContext
                let message: String
                switch result {
                case .moved(let context, let transfer):
                    newContext = context
                    message = transfer == .copiedAcrossVolumes
                        ? "Library relocated and the old copy was moved to the macOS Trash."
                        : "Library relocated."
                case .movedWithOldCopyRemaining(let context, _):
                    newContext = context
                    message = "Library relocated, but the old copy remains because it could not be moved to the macOS Trash."
                }
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updated = updatedRegistry.library(id: libraryID)
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRelocate,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: updated.map { queries.makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: newContext.rootURL.path,
                        message: message
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRemove:
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
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRemove,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. The App will move the library root to the macOS Trash and select a safe successor when needed after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "将资料库移到 macOS 废纸篓需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRemove),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "将资料库移到废纸篓？",
                    message: "要将“\(target.displayName)”及其资料库数据移到 macOS 废纸篓吗？其他资料库会保留，并继续使用可用的资料库。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                _ = try await appSession.removeMusicLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = updatedRegistry.activeLibraryID
                let active = activeID.flatMap(updatedRegistry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRemove,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: target.lastKnownPath,
                        message: "Library moved to the macOS Trash; the App selected the next active library."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryImport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                guard case .array(let paths) = parameters.values["filePaths"],
                      !paths.isEmpty, paths.count <= 5_000 else {
                    throw AutomationParameterError.invalidValue("filePaths")
                }
                var urls: [URL] = []
                var seen = Set<String>()
                for value in paths {
                    guard case .string(let rawPath) = value,
                          !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          (rawPath as NSString).expandingTildeInPath.hasPrefix("/") else {
                        throw AutomationParameterError.invalidValue("filePaths")
                    }
                    let url = URL(fileURLWithPath: AutomationInteraction.expandPath(rawPath))
                    if seen.insert(url.resolvingSymlinksInPath().path).inserted { urls.append(url) }
                }
                let playlistID = try parameters.uuid("targetPlaylistID")
                if let playlistID,
                   !session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) {
                    throw AutomationParameterError.missingResource("targetPlaylistID")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let enrichmentPolicyRaw = try parameters.string("enrichmentPolicy")
                    ?? LibraryImportEnrichmentPolicy.standard.rawValue
                guard let enrichmentPolicy = LibraryImportEnrichmentPolicy(rawValue: enrichmentPolicyRaw) else {
                    throw AutomationParameterError.invalidValue("enrichmentPolicy")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(AutomationLibraryImportResult(
                        libraryID: session.context.id, mode: session.context.mode.rawValue,
                        filePaths: urls.map(\.path), targetPlaylistID: playlistID,
                        dryRun: true,
                        enrichmentPolicy: enrichmentPolicy.rawValue,
                        message: "Preview only; no scan, conversion, authorization, import or enrichment has started."
                    ), for: request)
                }
                // Directly readable paths use the App's existing access. A
                // sandboxed App requests the same system picker as UI import.
                // Missing files are reported individually by the import pipeline.
                let inaccessible = urls.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                        && !FileManager.default.isReadableFile(atPath: $0.path)
                }
                var selectedURLs = urls
                if !inaccessible.isEmpty {
                    guard let picked = await session.fileImportService.pickImportURLs(triggeredAt: Date()) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                    let pickedPaths = Set(picked.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
                    guard inaccessible.allSatisfy({ pickedPaths.contains($0.resolvingSymlinksInPath().path) }) else {
                        return AutomationResponseSupport.permissionDenied(for: request, path: inaccessible[0].path)
                    }
                    selectedURLs = urls.map { url in
                        picked.first { $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path } ?? url
                    }
                }
                let selection = LibraryInitialImportSelection(urls: selectedURLs)
                defer { selection.release() }
                if let denied = selectedURLs.first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                        && !FileManager.default.isReadableFile(atPath: $0.path)
                }) {
                    return AutomationResponseSupport.permissionDenied(for: request, path: denied.path)
                }
                guard sessionAccess.activeSession(for: request) === session,
                      let job = session.startAutomationImport(
                        selection: selection,
                        playlistID: playlistID,
                        enrichmentPolicy: enrichmentPolicy
                      ) else {
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                return AutomationResponseSupport.encodeResult(AutomationLibraryImportResult(
                    libraryID: session.context.id, mode: session.context.mode.rawValue,
                    filePaths: selectedURLs.map(\.path), targetPlaylistID: playlistID,
                    job: AutomationJobProjection.makeJobSummary(job),
                    enrichmentPolicy: enrichmentPolicy.rawValue,
                    message: "Import started. Use jobs.wait or jobs.get for Track IDs, per-file mappings, failures and enrichment status."
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let query = try parameters.string("query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let playlistID = try parameters.uuid("playlistID")
                let sourceID = try parameters.uuid("sourceID")
                let relativePathPrefix = try parameters.string("relativePathPrefix")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let requestedIDs = try parameters.uuidArray("ids")
                let filter = try parameters.object("filter")
                if let filter {
                    try queries.validateTrackFilter(.object(filter))
                }
                let sort = try parameters.array("sort")
                let includePreferenceStats = try parameters.boolean(
                    "includePreferenceStats", default: false
                )
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                let expectedRevision = try parameters.string("expectedRevision")
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }

                let viewModel = session.libraryViewModel
                let allTracks = viewModel.allTracks
                let usesPreferenceData = includePreferenceStats
                    || filter.map { AutomationTrackPreferenceQuery.requiresHistoryRead(in: .object($0)) } == true
                    || AutomationTrackPreferenceQuery.requiresHistoryRead(sort: sort)
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: allTracks.map(\.id))
                    : [:]
                let playlistTrackIDs: Set<UUID>?
                if let playlistID {
                    guard let playlist = viewModel.playlists.first(where: { $0.id == playlistID }) else {
                        return .failure(
                            for: request,
                            error: AutomationError(
                                code: .invalidRequest,
                                message: "The requested playlist does not exist.",
                                details: .object(["playlistID": .string(playlistID.uuidString)])
                            )
                        )
                    }
                    playlistTrackIDs = Set(playlist.tracks.map(\.id))
                } else {
                    playlistTrackIDs = nil
                }

                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                if let expectedRevision, expectedRevision != revision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: revision
                    )
                }

                var filteredTracks: [Track] = []
                filteredTracks.reserveCapacity(allTracks.count)
                for track in allTracks {
                    if !requestedIDs.isEmpty, !requestedIDs.contains(track.id) { continue }
                    if let playlistTrackIDs, !playlistTrackIDs.contains(track.id) { continue }
                    let memberships = track.mediaLocator.referencedFile?.allSourceMemberships ?? []
                    if let sourceID, !memberships.contains(where: { $0.sourceID == sourceID }) {
                        continue
                    }
                    if let relativePathPrefix, !relativePathPrefix.isEmpty,
                       !memberships.contains(where: {
                           $0.relativePath == relativePathPrefix
                               || $0.relativePath.hasPrefix(relativePathPrefix + "/")
                       }) {
                        continue
                    }
                    if let query, !query.isEmpty,
                       !track.title.localizedCaseInsensitiveContains(query),
                       !track.artist.localizedCaseInsensitiveContains(query),
                       !track.album.localizedCaseInsensitiveContains(query) {
                        continue
                    }
                    if let filter,
                       try !queries.matchesTrackFilter(
                           track,
                           filter: .object(filter),
                           playlists: viewModel.playlists,
                           preferenceStatsByTrackID: preferenceStatsByTrackID
                       ) {
                        continue
                    }
                    filteredTracks.append(track)
                }
                let orderedTracks = try queries.sortTracks(
                    filteredTracks,
                    using: sort,
                    preferenceStatsByTrackID: preferenceStatsByTrackID
                )
                let pageStart = min(offset, orderedTracks.count)
                let pageEnd = min(pageStart + limit, orderedTracks.count)
                let page = Array(orderedTracks[pageStart..<pageEnd]).map {
                    queries.makeTrackSummary(
                        $0,
                        playlists: viewModel.playlists,
                        includeFilePath: grantedScopes().contains(.filesRead),
                        includePreferenceStats: includePreferenceStats,
                        preferenceStats: preferenceStatsByTrackID[$0.id]
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: page,
                        total: orderedTracks.count,
                        offset: offset,
                        limit: limit,
                        nextOffset: pageEnd < orderedTracks.count ? pageEnd : nil,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryStats:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            let viewModel = session.libraryViewModel
            let tracks = viewModel.allTracks
            let revision = queries.libraryTracksRevision(tracks: tracks, playlists: viewModel.playlists)
            let linkedSourceIDs = Set(tracks.flatMap { track in
                track.mediaLocator.referencedFile?.allSourceMemberships.map(\.sourceID) ?? []
            })
            return AutomationResponseSupport.encodeResult(AutomationLibraryStatsResult(
                libraryID: session.context.id,
                mode: session.context.mode.rawValue,
                trackCount: tracks.count,
                availableTrackCount: tracks.filter { $0.availability == .available }.count,
                missingTrackCount: tracks.filter { $0.availability == .missing }.count,
                recoverableTrackCount: tracks.filter { $0.availability.isRecoverable }.count,
                playlistCount: viewModel.playlists.count,
                linkedSourceCount: linkedSourceIDs.count,
                artistCount: viewModel.runtimeArtists.count,
                albumCount: viewModel.runtimeAlbums.count,
                lyricsTrackCount: tracks.filter { $0.ttmlLyricsFileName != nil || $0.lyricsFileName != nil }.count,
                artworkTrackCount: tracks.filter { $0.artworkFileName != nil }.count,
                totalDurationSeconds: tracks.reduce(0) { $0 + max(0, $1.duration) },
                revision: revision
            ), for: request)

        case AutomationMethod.libraryReport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                let playlistLimit = try parameters.integer("playlistLimit", default: 100)
                let playlistOffset = try parameters.integer("playlistOffset", default: 0)
                let expectedRevision = try parameters.string("expectedRevision")
                let includeFilePaths = try parameters.boolean("includeFilePaths", default: false)
                let includePreferenceStats = try parameters.boolean(
                    "includePreferenceStats", default: false
                )
                guard (1...100).contains(limit), offset >= 0,
                      (1...100).contains(playlistLimit), playlistOffset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                guard !includeFilePaths || grantedScopes().contains(.filesRead) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .authorizationRequired,
                            message: "Including local file paths requires the files.read scope.",
                            details: .object(["requiredScope": .string(AutomationScope.filesRead.rawValue)])
                        )
                    )
                }
                let viewModel = session.libraryViewModel
                let allTracks = viewModel.allTracks
                let playlists = viewModel.playlists
                let preferenceStatsByTrackID = includePreferenceStats
                    ? viewModel.preferenceStats(for: allTracks.map(\.id))
                    : [:]
                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: playlists,
                    preferenceStatsByTrackID: includePreferenceStats
                        ? preferenceStatsByTrackID
                        : nil
                )
                if let expectedRevision, expectedRevision != revision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: revision
                    )
                }
                let start = min(offset, allTracks.count)
                let end = min(start + limit, allTracks.count)
                let trackPage = Array(allTracks[start..<end]).map {
                    queries.makeTrackSummary(
                        $0,
                        playlists: playlists,
                        includeFilePath: includeFilePaths,
                        includePreferenceStats: includePreferenceStats,
                        preferenceStats: preferenceStatsByTrackID[$0.id]
                    )
                }
                let playlistStart = min(playlistOffset, playlists.count)
                let playlistEnd = min(playlistStart + playlistLimit, playlists.count)
                let playlistPage = Array(playlists[playlistStart..<playlistEnd])
                let linkedSourceIDs = Set(allTracks.flatMap { track in
                    track.mediaLocator.referencedFile?.allSourceMemberships.map(\.sourceID) ?? []
                })
                let stats = AutomationLibraryStatsResult(
                    libraryID: session.context.id,
                    mode: session.context.mode.rawValue,
                    trackCount: allTracks.count,
                    availableTrackCount: allTracks.filter { $0.availability == .available }.count,
                    missingTrackCount: allTracks.filter { $0.availability == .missing }.count,
                    recoverableTrackCount: allTracks.filter { $0.availability.isRecoverable }.count,
                    playlistCount: playlists.count,
                    linkedSourceCount: linkedSourceIDs.count,
                    artistCount: viewModel.runtimeArtists.count,
                    albumCount: viewModel.runtimeAlbums.count,
                    lyricsTrackCount: allTracks.filter { $0.ttmlLyricsFileName != nil || $0.lyricsFileName != nil }.count,
                    artworkTrackCount: allTracks.filter { $0.artworkFileName != nil }.count,
                    totalDurationSeconds: allTracks.reduce(0) { $0 + max(0, $1.duration) },
                    revision: revision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryReportResult(
                        stats: stats,
                        tracks: trackPage,
                        playlists: playlistPage.map(queries.makePlaylistSummary),
                        offset: offset,
                        limit: limit,
                        nextOffset: end < allTracks.count ? end : nil,
                        playlistOffset: playlistOffset,
                        playlistLimit: playlistLimit,
                        nextPlaylistOffset: playlistEnd < playlists.count ? playlistEnd : nil,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryBundleExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let viewModel = session.libraryViewModel
                let libraryTracks = viewModel.allTracks
                let libraryPlaylists = viewModel.playlists
                let revision = queries.libraryTracksRevision(tracks: libraryTracks, playlists: libraryPlaylists)
                var failures: [String] = []
                let tracks: [LibraryBundleExportTrackInput] = libraryTracks.map { track in
                    let audioURL: URL?
                    do {
                        if case .referenced = track.mediaLocator {
                            audioURL = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                        } else {
                            audioURL = AutomationFileAccess.automationTrackFileURL(track, in: session)
                        }
                    } catch {
                        audioURL = nil
                    }
                    let existingAudio = audioURL.flatMap {
                        FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil
                    }
                    var trackFailures: [String] = []
                    if existingAudio == nil {
                        let failure = "\(track.id.uuidString): audio unavailable"
                        trackFailures.append(failure)
                        failures.append(failure)
                    }
                    func existingAsset(_ url: URL?) -> URL? {
                        guard let url,
                              FileManager.default.fileExists(atPath: url.path),
                              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
                        return url
                    }
                    return LibraryBundleExportTrackInput(
                        metadata: queries.makeMetadataDocumentTrack(
                            track,
                            revision: viewModel.automationTrackRevision(for: track)
                        ),
                        audioURL: existingAudio,
                        artworkURL: existingAsset(track.existingArtworkURL()),
                        lyricsURL: existingAsset(track.resolvedLyricsURL()),
                        ttmlURL: existingAsset(track.resolvedTTMLURL()),
                        failures: trackFailures
                    )
                }
                let playlists = libraryPlaylists.map {
                    LibraryBundleExportPlaylistInput(
                        id: $0.id,
                        name: $0.name,
                        description: $0.userDescription,
                        trackIDs: $0.tracks.map(\.id)
                    )
                }
                let estimatedBytes = LibraryBundleExportService.estimatedBytes(for: tracks)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryBundleExportResult(
                            libraryID: session.context.id,
                            dryRun: true,
                            trackCount: tracks.count,
                            estimatedBytes: estimatedBytes,
                            failures: failures,
                            message: "Preview only. The package will include path-free Track metadata, Playlist membership, and available audio, artwork and lyrics files."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Export a complete Library bundle?",
                        details: .object([
                            "trackCount": .number(Double(tracks.count)),
                            "estimatedBytes": .number(Double(estimatedBytes)),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导出完整资料库？",
                    message: "将把 \(tracks.count) 首歌曲及可用封面、歌词复制到新资料库包，估算 \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let destinationURL = await AutomationInteraction.requestExportDirectory() else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let destination = destinationURL.standardizedFileURL
                let libraryRoot = session.context.rootURL.standardizedFileURL
                guard destination.path != libraryRoot.path,
                      !destination.path.hasPrefix(libraryRoot.path + "/") else {
                    throw AutomationParameterError.invalidValue("destination folder inside active Library")
                }
                let hasScopedAccess = destinationURL.startAccessingSecurityScopedResource()
                guard sessionAccess.activeSession(for: request) === session else {
                    if hasScopedAccess { destinationURL.stopAccessingSecurityScopedResource() }
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                guard let job = session.startAutomationLibraryBundleExport(
                        destinationDirectory: destinationURL,
                        destinationScopeStarted: hasScopedAccess,
                        revision: revision,
                        tracks: tracks,
                        playlists: playlists
                      ) else {
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryBundleExportResult(
                        libraryID: session.context.id,
                        dryRun: false,
                        applied: true,
                        confirmed: true,
                        trackCount: tracks.count,
                        estimatedBytes: estimatedBytes,
                        outputDirectory: destination.path,
                        job: AutomationJobProjection.makeJobSummary(job),
                        failures: failures,
                        message: "Library bundle export started. Poll the returned Job for progress and the completed package location."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.librarySelectionList:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                let viewModel = session.libraryViewModel
                let usesPreferenceData = snapshots.contains { snapshot in
                    snapshot.filter.map(AutomationTrackPreferenceQuery.requiresHistoryRead(in:)) == true
                }
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: viewModel.allTracks.map(\.id))
                    : [:]
                let currentRevision = queries.libraryTracksRevision(
                    tracks: viewModel.allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                let selections = try snapshots.map {
                    try queries.resolveSelection($0, viewModel: viewModel).summary
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionListResult(
                        libraryID: session.context.id,
                        currentRevision: currentRevision,
                        selections: selections
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionCreate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let hasTrackIDs = parameters.values["trackIDs"] != nil
                let filter = parameters.values["filter"]
                guard hasTrackIDs != (filter != nil) else {
                    throw AutomationParameterError.invalidValue("trackIDs/filter")
                }
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    allowEmpty: true,
                    maximumCount: 10_000
                )
                let name = try parameters.string("name")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard requestedTrackIDs.count <= 10_000,
                      Set(requestedTrackIDs).count == requestedTrackIDs.count else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                if let name, (name.isEmpty || name.count > 120) {
                    throw AutomationParameterError.invalidValue("name")
                }
                let viewModel = session.libraryViewModel
                let usesPreferenceData = filter.map {
                    AutomationTrackPreferenceQuery.requiresHistoryRead(in: $0)
                } == true
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: viewModel.allTracks.map(\.id))
                    : [:]
                let currentRevision = queries.libraryTracksRevision(
                    tracks: viewModel.allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                if let expectedRevision, expectedRevision != currentRevision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: currentRevision
                    )
                }
                if let filter {
                    try queries.validateTrackFilter(filter)
                }
                let selectedTrackIDs: [UUID]
                if let filter {
                    selectedTrackIDs = try viewModel.allTracks.compactMap { track in
                        try queries.matchesTrackFilter(
                            track,
                            filter: filter,
                            playlists: viewModel.playlists,
                            preferenceStatsByTrackID: preferenceStatsByTrackID
                        ) ? track.id : nil
                    }
                    guard selectedTrackIDs.count <= 10_000 else {
                        throw AutomationParameterError.outOfRange("filter.resultCount")
                    }
                } else {
                    selectedTrackIDs = requestedTrackIDs
                }
                let availableIDs = Set(viewModel.allTracks.map(\.id))
                let missingIDs = selectedTrackIDs.filter { !availableIDs.contains($0) }
                guard missingIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "A selection snapshot can contain only Tracks in the active Library.",
                            details: .object([
                                "missingTrackIDs": .array(missingIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let now = Date()
                let selectionID = UUID()
                let summary = AutomationSelectionSummary(
                    id: selectionID,
                    name: name?.isEmpty == true ? nil : name,
                    trackCount: selectedTrackIDs.count,
                    revision: queries.selectionRevision(
                        libraryID: session.context.id,
                        trackIDs: selectedTrackIDs
                    ),
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                    isDynamic: filter != nil
                )
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSelectionCreateResult(
                            libraryID: session.context.id,
                            selection: summary,
                            trackIDs: selectedTrackIDs,
                            applied: false,
                            dryRun: true
                        ),
                        for: request
                    )
                }
                var snapshots = try selectionStore.load(libraryID: session.context.id)
                snapshots.append(
                    AutomationSelectionSnapshot(
                        libraryID: session.context.id,
                        summary: summary,
                        trackIDs: filter == nil ? selectedTrackIDs : [],
                        filter: filter
                    )
                )
                try selectionStore.save(snapshots, libraryID: session.context.id, now: now)
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionCreateResult(
                        libraryID: session.context.id,
                        selection: summary,
                        trackIDs: selectedTrackIDs,
                        applied: true,
                        dryRun: false
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                guard let snapshot = snapshots.first(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                let resolved = try queries.resolveSelection(snapshot, viewModel: session.libraryViewModel)
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionDetailResult(
                        libraryID: session.context.id,
                        selection: resolved.summary,
                        trackIDs: resolved.trackIDs,
                        filter: snapshot.filter
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionDelete:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                var snapshots = try selectionStore.load(libraryID: session.context.id)
                guard snapshots.contains(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                if !dryRun {
                    snapshots.removeAll { $0.summary.id == selectionID }
                    try selectionStore.save(snapshots, libraryID: session.context.id)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionDeleteResult(
                        libraryID: session.context.id,
                        selectionID: selectionID,
                        deleted: !dryRun,
                        dryRun: dryRun
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func libraryLifecycleFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        if error is AutomationParameterError || error is AutomationFileOperationError {
            return AutomationResponseSupport.invalidParameters(for: request, error: error)
        }

        let reason = String(describing: error)
        func failure(
            _ code: AutomationErrorCode,
            _ message: String,
            retryable: Bool = false
        ) -> AutomationResponse {
            .failure(
                for: request,
                error: AutomationError(
                    code: code,
                    message: message,
                    retryable: retryable,
                    details: .object(["reason": .string(reason)])
                )
            )
        }

        switch error {
        case let error as RegisteredLibraryActivationError:
            switch error {
            case .notRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .reconnectRequired(let libraryID):
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .interactionRequired,
                        message: "The registered library is unavailable at its last known path. Call library.open and select its current folder before switching again.",
                        details: .object([
                            "libraryID": .string(libraryID.uuidString),
                            "nextAction": .string(AutomationMethod.libraryOpen),
                            "reason": .string(reason)
                        ])
                    )
                )
            }

        case let error as LibraryCreationError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .destinationContainsUnknownItems, .invalidExistingLibrary:
                return failure(.conflict, "The selected library location already queries.contains data that cannot be safely reused.")
            case .stagingFailed, .validationFailed:
                return failure(.internalError, "The new library could not be staged or validated.", retryable: true)
            case .registryCommitFailed, .sessionActivationFailed, .recoveryFailed:
                return failure(.internalError, "The new library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryOpenError:
            switch error {
            case .libraryNotFound, .invalidManifest, .libraryNotRegistered,
                 .reconnectIdentifierMismatch, .reconnectModeMismatch:
                return failure(.invalidRequest, "The selected location is not a usable registered music library.")
            case .pathConflict:
                return failure(.conflict, "The selected library path is already registered to another library.")
            case .bookmarkFailed, .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the selected library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .activationFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRelocationError:
            switch error {
            case .libraryNotRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .destinationExists:
                return failure(.conflict, "The destination already queries.contains a library or other data.")
            case .validationFailed:
                return failure(.invalidRequest, "The registered library failed validation and was not moved.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library or destination location.")
            case .transactionInProgress, .pendingRepair, .recoveryConflict:
                return failure(.conflict, "The library has an unfinished lifecycle transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .copyFailed, .publicationFailed, .newSessionFailed,
                 .registryCommitFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be relocated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRemovalError:
            switch error {
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress, .pendingRepair:
                return failure(.conflict, "The library has an unfinished removal transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .recycleFailed, .intentWriteFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be moved to the macOS Trash safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryDisplayNameUpdateError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .manifestWriteFailed, .registryWriteFailedRolledBack,
                 .registryWriteFailedRollbackFailed:
                return failure(.internalError, "The library name could not be updated safely.", retryable: true)
            }

        default:
            return failure(.internalError, "The library lifecycle operation failed.", retryable: true)
        }
    }

    private func libraryPermissionDenied(
        for request: AutomationRequest,
        path: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .permissionDenied,
                message: "The selected library location could not be authorized; no library lifecycle mutation was applied.",
                retryable: false,
                details: .object([
                    "path": .string(path),
                    "reason": .string("securityScopedAccess")
                ])
            )
        )
    }
}
