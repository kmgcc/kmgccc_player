import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

@MainActor
struct AutomationJobsHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken?
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.jobsList:
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
            guard sessionAccess.activeSession(for: request) != nil else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationJobListResult(
                    jobs: appSession.libraryJobDescriptors().map(AutomationJobProjection.makeJobSummary)
                ),
                for: request
            )

        case AutomationMethod.jobsGet:
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
            guard sessionAccess.activeSession(for: request) != nil else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let jobID = try parameters.uuid("jobID", required: true)!
                guard let job = appSession.libraryJobDescriptors().first(where: { $0.id == jobID }) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                return AutomationResponseSupport.encodeResult(AutomationJobProjection.makeJobSummary(job), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsWait:
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
                let jobID = try parameters.uuid("jobID", required: true)!
                let timeoutMs = try parameters.integer("timeoutMs", default: 20_000)
                guard (0...25_000).contains(timeoutMs) else {
                    throw AutomationParameterError.outOfRange("timeoutMs")
                }
                let startedAt = Date()
                let requestedDeadline = startedAt.addingTimeInterval(Double(timeoutMs) / 1_000)
                let requestDeadline = request.context.deadline
                let deadline = min(requestedDeadline, requestDeadline ?? requestedDeadline)
                let contextDeadlineIsEarlier = requestDeadline.map { $0 < requestedDeadline } ?? false

                while true {
                    if cancellation?.isCancelled == true {
                        return .failure(
                            for: request,
                            error: AutomationError(
                                code: .serverUnavailable,
                                message: "The Job wait was cancelled. The Job continues running.",
                                retryable: true,
                                details: .object(["jobID": .string(jobID.uuidString)])
                            )
                        )
                    }
                    guard appSession.activeLibraryBinding.activeSession === session else {
                        return sessionAccess.noActiveLibraryResponse(for: request)
                    }
                    guard let descriptor = session.libraryJobDescriptorsSnapshot().first(where: {
                        $0.id == jobID
                    }) else {
                        throw AutomationParameterError.missingResource("jobID")
                    }
                    let job = AutomationJobProjection.makeJobSummary(descriptor)
                    let completed: Bool
                    switch job.state {
                    case .completed, .partialFailure, .failed, .cancelled:
                        completed = true
                    case .queued, .running, .checkpointed:
                        completed = false
                    }
                    if completed {
                        return AutomationResponseSupport.encodeResult(
                            AutomationJobWaitResult(
                                job: job,
                                completed: true,
                                timedOut: false,
                                waitedMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
                            ),
                            for: request
                        )
                    }

                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        return AutomationResponseSupport.encodeResult(
                            AutomationJobWaitResult(
                                job: job,
                                completed: false,
                                timedOut: true,
                                deadlineReached: contextDeadlineIsEarlier,
                                waitedMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
                            ),
                            for: request
                        )
                    }
                    let sleepMs = min(200, max(1, Int(remaining * 1_000)))
                    try await Task.sleep(for: .milliseconds(sleepMs))
                }
            } catch is CancellationError {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The Job wait was cancelled. The Job continues running.",
                        retryable: true
                    )
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsCancel:
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
            guard sessionAccess.activeSession(for: request) != nil else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let jobID = try parameters.uuid("jobID", required: true)!
                guard appSession.cancelLibraryJob(
                    id: jobID,
                    libraryID: request.context.libraryID
                ) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationJSONValue.object([
                        "jobID": .string(jobID.uuidString),
                        "cancelRequested": .boolean(true)
                    ]),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsRetry:
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
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let jobID = try parameters.uuid("jobID", required: true)!
                guard let descriptor = appSession.libraryJobDescriptors()
                    .first(where: { $0.id == jobID }) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                guard descriptor.retrySpec != nil else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                guard descriptor.state == .failed
                    || descriptor.state == .partialFailure
                    || descriptor.state == .cancelled else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                if descriptor.retrySpec?.kind == .dspScriptTest {
                    guard parameters.values["filePaths"] == nil,
                          let job = try await AutomationDSPScriptsHandler(appSession: appSession)
                            .retryTestJob(descriptor, session: session) else {
                        throw AutomationParameterError.invalidValue("jobID")
                    }
                    return AutomationResponseSupport.encodeResult(AutomationJobRetryResult(
                        originalJobID: jobID, accepted: true, job: AutomationJobProjection.makeJobSummary(job),
                        message: "Script fixture retry accepted for the unchanged source revision."), for: request)
                }
                let importSelection: LibraryInitialImportSelection?
                if descriptor.retrySpec?.kind == .libraryImport {
                    if let playlistID = descriptor.retrySpec?.targetPlaylistID,
                       !session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) {
                        throw AutomationParameterError.missingResource("targetPlaylistID")
                    }
                    guard case .array(let paths)? = parameters.values["filePaths"],
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
                        if seen.insert(url.resolvingSymlinksInPath().path).inserted {
                            urls.append(url)
                        }
                    }
                    let inaccessible = urls.filter {
                        FileManager.default.fileExists(atPath: $0.path)
                            && !FileManager.default.isReadableFile(atPath: $0.path)
                    }
                    var selectedURLs = urls
                    if !inaccessible.isEmpty {
                        guard let picked = await session.fileImportService.pickImportURLs(
                            triggeredAt: Date()
                        ) else {
                            return AutomationResponseSupport.interactionCancelled(for: request)
                        }
                        let pickedPaths = Set(picked.map {
                            $0.resolvingSymlinksInPath().standardizedFileURL.path
                        })
                        guard inaccessible.allSatisfy({
                            pickedPaths.contains($0.resolvingSymlinksInPath().path)
                        }) else {
                            return AutomationResponseSupport.permissionDenied(for: request, path: inaccessible[0].path)
                        }
                        selectedURLs = urls.map { url in
                            picked.first {
                                $0.resolvingSymlinksInPath().path
                                    == url.resolvingSymlinksInPath().path
                            } ?? url
                        }
                    }
                    if let denied = selectedURLs.first(where: {
                        FileManager.default.fileExists(atPath: $0.path)
                            && !FileManager.default.isReadableFile(atPath: $0.path)
                    }) {
                        return AutomationResponseSupport.permissionDenied(for: request, path: denied.path)
                    }
                    importSelection = LibraryInitialImportSelection(urls: selectedURLs)
                } else {
                    guard parameters.values["filePaths"] == nil else {
                        throw AutomationParameterError.invalidValue("filePaths")
                    }
                    importSelection = nil
                }
                defer { importSelection?.release() }
                guard let retryJob = appSession.retryLibraryJob(
                    id: jobID,
                    libraryID: request.context.libraryID,
                    importSelection: importSelection
                ) else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationJobRetryResult(
                        originalJobID: jobID,
                        accepted: true,
                        job: AutomationJobProjection.makeJobSummary(retryJob),
                        message: descriptor.retrySpec?.kind == .libraryImport
                            ? "Import retry accepted with the caller-supplied file paths; query jobs.get for the new Job's progress."
                            : "Job retry accepted; query jobs.get for the new Job's progress."
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

}
