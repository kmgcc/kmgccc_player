import Foundation

nonisolated enum LibraryRepairIssueKind: String, Sendable {
    case manifest
    case source
    case transaction
    case track
    case playlist
    case settings
    case ncm
}

nonisolated enum LibraryRepairQuarantineTarget: Sendable, Equatable {
    case sourceDirectory(id: UUID)
    case transactionRecord
    case playlistRecord
    case audioProgramImport(UUID)
}

nonisolated struct LibraryRepairIssue: Sendable, Equatable, Identifiable {
    let kind: LibraryRepairIssueKind
    let path: URL
    let detail: String
    let quarantineTarget: LibraryRepairQuarantineTarget?
    /// Blocking issues prevent a normal writable open. Other issues are
    /// reported for inspection but the library can still load.
    let blocksOpen: Bool

    var id: String { "\(kind.rawValue)|\(path.path)" }
}

nonisolated struct LibraryMutationIntentSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: LibraryMutationKind
    let state: LibraryMutationJournalState
    let createdAt: Date
    let pendingSteps: [String]
    let targetIDs: [String]
    let fileURL: URL
    let recoveryHint: String?

    var isImportPending: Bool { kind == .importCommit }
}

nonisolated struct LibraryRepairReport: Sendable, Equatable {
    let rootURL: URL
    let libraryID: UUID?
    let displayName: String?
    let mode: MusicLibraryMode?
    let issues: [LibraryRepairIssue]
    let unresolvedTransactions: [LibraryMutationIntentSummary]
    let sourceNames: [String]
    let sampleTracks: [String]
    let trackCount: Int
    let trackFolderCount: Int
    let checkedAt: Date
    var audioProgramSnapshots: [AudioProgramRecoverySnapshot] = []

    var blockingIssues: [LibraryRepairIssue] { issues.filter(\.blocksOpen) }
    var quarantinableIssues: [LibraryRepairIssue] { issues.filter { issue in
        if case .some(.audioProgramImport(_)) = issue.quarantineTarget { return true }
        return issue.blocksOpen && issue.quarantineTarget != nil
    } }
    var canQuarantineAndRetry: Bool {
        !quarantinableIssues.isEmpty && blockingIssues.allSatisfy { $0.quarantineTarget != nil }
    }
}

nonisolated struct LibraryRepairQuarantineResult: Sendable, Equatable {
    var moved: [URL] = []
    var skipped: [URL] = []
    var failed: [String] = []
}

/// Read-only diagnosis for a library that fails to open, plus an explicit
/// quarantine action. Nothing is written, moved, or created until the user
/// chooses to isolate a broken record.
nonisolated enum LibraryRepairInspector {
    static func inspect(
        rootURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async -> LibraryRepairReport {
        let paths = LibraryPaths(rootURL: rootURL)
        var issues: [LibraryRepairIssue] = []

        let manifest: MusicLibraryManifest?
        do {
            manifest = try MusicLibraryManifest.read(from: paths.manifestURL)
        } catch {
            manifest = nil
            issues.append(.init(
                kind: .manifest,
                path: paths.manifestURL,
                detail: error.localizedDescription,
                quarantineTarget: nil,
                blocksOpen: true
            ))
        }

        do {
            for record in try AudioProgramImportTransaction.load(paths: paths) where !record.committed {
                issues.append(.init(kind: .transaction,
                    path: AudioProgramImportTransaction.root(paths).appendingPathComponent("\(record.id.uuidString).json"),
                    detail: "分轨导入尚待恢复", quarantineTarget: .audioProgramImport(record.id), blocksOpen: false))
            }
        } catch {
            issues.append(.init(kind: .transaction, path: AudioProgramImportTransaction.root(paths),
                detail: error.localizedDescription, quarantineTarget: nil, blocksOpen: false))
        }
        let projection = LibraryMutationProjectionReader.read(paths: paths, fileManager: fileManager)
        for issue in projection.issues {
            let isPlaylist = issue.path.deletingLastPathComponent().path == paths.playlistsRootURL.path
            issues.append(.init(
                kind: isPlaylist ? .playlist : .track,
                path: issue.path,
                detail: issue.detail,
                quarantineTarget: isPlaylist ? .playlistRecord : nil,
                blocksOpen: false
            ))
        }
        if !projection.settingsIsValid {
            issues.append(.init(
                kind: .settings,
                path: paths.librarySettingsURL,
                detail: "资料库设置无法读取",
                quarantineTarget: nil,
                blocksOpen: false
            ))
        }
        for issue in projection.ncmIssues {
            issues.append(.init(
                kind: .ncm,
                path: issue.path,
                detail: issue.detail,
                quarantineTarget: nil,
                blocksOpen: false
            ))
        }

        var sourceNames: [String] = []
        do {
            let inventory = try await ReferencedSourceStore(paths: paths).inspectAll()
            sourceNames = inventory.descriptors.map(\.displayName)
            for issue in inventory.issues {
                issues.append(.init(
                    kind: .source,
                    path: issue.descriptorURL,
                    detail: issue.reason,
                    quarantineTarget: issue.sourceID.map { .sourceDirectory(id: $0) },
                    blocksOpen: true
                ))
            }
        } catch {
            issues.append(.init(
                kind: .source,
                path: paths.sourcesRootURL,
                detail: error.localizedDescription,
                quarantineTarget: nil,
                blocksOpen: true
            ))
        }

        var transactionSummaries: [LibraryMutationIntentSummary] = []
        let journal = LibraryMutationJournal(paths: paths, libraryID: manifest?.libraryID ?? UUID())
        do {
            let inspection = try await journal.inspectPending()
            for failure in inspection.failures {
                issues.append(.init(
                    kind: .transaction,
                    path: failure.fileURL,
                    detail: failure.reason,
                    quarantineTarget: .transactionRecord,
                    blocksOpen: true
                ))
            }
            for intent in inspection.intents {
                let verdict = LibraryMutationVerifier.verify(intent, snapshot: projection)
                transactionSummaries.append(.init(
                    id: intent.id,
                    kind: intent.kind,
                    state: intent.state,
                    createdAt: intent.createdAt,
                    pendingSteps: intent.steps.filter { $0.state != .completed }.map(\.id),
                    targetIDs: intent.targetIDs,
                    fileURL: paths.pendingTransactionsRootURL
                        .appendingPathComponent("\(intent.id.uuidString).json"),
                    recoveryHint: verdict.isResolved ? verdict.summary : nil
                ))
            }
        } catch {
            issues.append(.init(
                kind: .transaction,
                path: paths.pendingTransactionsRootURL,
                detail: error.localizedDescription,
                quarantineTarget: nil,
                blocksOpen: true
            ))
        }

        return LibraryRepairReport(
            rootURL: paths.rootURL,
            libraryID: manifest?.libraryID,
            displayName: manifest?.displayName,
            mode: manifest?.mode,
            issues: issues,
            unresolvedTransactions: transactionSummaries,
            sourceNames: sourceNames,
            sampleTracks: projection.sampleTrackTitles,
            trackCount: projection.trackCount,
            trackFolderCount: projection.trackFolderCount,
            checkedAt: now,
            audioProgramSnapshots: (try? AudioProgramRecoverySnapshot.loadAll(paths: paths)) ?? []
        )
    }
}

/// Archives journal records the user has reviewed when no verifier applies.
/// The record remains in Completed with an explicit archived state.
nonisolated enum LibraryMutationArchiveService {
    static func archive(
        rootURL: URL,
        libraryID: UUID,
        intentIDs: [UUID]
    ) async -> Int {
        let paths = LibraryPaths(rootURL: rootURL)
        let journal = LibraryMutationJournal(paths: paths, libraryID: libraryID)
        let snapshot = LibraryMutationProjectionReader.read(paths: paths)
        let intents: [LibraryMutationIntent]
        do { intents = try await journal.pendingIntents() }
        catch {
            Log.error("[LibraryRepair] cannot inspect pending records: \(error)", category: .library)
            return 0
        }
        let wanted = Set(intentIDs)
        var archived = 0
        for intent in intents where wanted.contains(intent.id) {
            let verdict = LibraryMutationVerifier.verify(intent, snapshot: snapshot)
            if verdict.isResolved {
                do {
                    _ = try await journal.markResolved(
                        intentID: intent.id,
                        summary: verdict.summary
                    )
                } catch {
                    Log.error(
                        "[LibraryRepair] failed to archive verified intent \(intent.id): \(error)",
                        category: .library
                    )
                }
                continue
            }
            do {
                _ = try await journal.archiveUnresolved(
                    intentID: intent.id,
                    summary: "reviewed by the user; no automatic verifier applies"
                )
                archived += 1
            } catch {
                Log.error(
                    "[LibraryRepair] failed to archive intent \(intent.id): \(error)",
                    category: .library
                )
            }
        }
        return archived
    }
}

/// Moves explicitly selected broken records into the library's Recovery
/// folder. Each target is re-validated immediately before the move, so a
/// transient read failure never removes a record that now loads.
nonisolated struct LibraryRepairQuarantineService {
    let rootURL: URL
    let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func quarantine(
        _ issues: [LibraryRepairIssue],
        libraryID: UUID?,
        now: Date = Date()
    ) -> LibraryRepairQuarantineResult {
        let paths = LibraryPaths(rootURL: rootURL)
        var result = LibraryRepairQuarantineResult()
        for issue in issues {
            guard let target = issue.quarantineTarget else { continue }
            switch target {
            case .sourceDirectory(let id):
                let directory = paths.sourceRootURL(for: id)
                guard fileManager.fileExists(atPath: directory.path) else {
                    result.skipped.append(directory)
                    continue
                }
                guard !sourceDescriptorLoads(at: paths.sourceDescriptorURL(for: id), expectedID: id) else {
                    result.skipped.append(directory)
                    continue
                }
                let destination = uniqueDestination(
                    in: paths.recoverySourcesRootURL,
                    name: id.uuidString,
                    now: now
                )
                move(directory, to: destination, result: &result)

            case .transactionRecord:
                guard fileManager.fileExists(atPath: issue.path.path) else {
                    result.skipped.append(issue.path)
                    continue
                }
                guard !transactionRecordLoads(at: issue.path, expectedLibraryID: libraryID) else {
                    result.skipped.append(issue.path)
                    continue
                }
                let destination = uniqueDestination(
                    in: paths.recoveryTransactionsRootURL,
                    name: issue.path.lastPathComponent,
                    now: now
                )
                move(issue.path, to: destination, result: &result)

            case .audioProgramImport(let id):
                do {
                    guard let record = try AudioProgramImportTransaction.load(paths: paths).first(where: { $0.id == id }) else {
                        result.skipped.append(issue.path)
                        continue
                    }
                    try record.recover(paths: paths)
                    result.moved.append(issue.path)
                } catch { result.failed.append(error.localizedDescription) }

            case .playlistRecord:
                guard fileManager.fileExists(atPath: issue.path.path) else {
                    result.skipped.append(issue.path)
                    continue
                }
                guard !playlistRecordLoads(at: issue.path) else {
                    result.skipped.append(issue.path)
                    continue
                }
                let destination = uniqueDestination(
                    in: paths.recoveryTransactionsRootURL,
                    name: issue.path.lastPathComponent,
                    now: now
                )
                move(issue.path, to: destination, result: &result)
            }
        }
        return result
    }

    private func move(
        _ source: URL,
        to destination: URL,
        result: inout LibraryRepairQuarantineResult
    ) {
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            result.moved.append(destination)
        } catch {
            result.failed.append("\(source.path): \(error.localizedDescription)")
        }
    }

    private func uniqueDestination(in directory: URL, name: String, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("\(name)-\(formatter.string(from: now))-\(suffix)")
    }

    private func sourceDescriptorLoads(at url: URL, expectedID: UUID) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? Int,
              schema == 1 || schema == 2 || schema == ReferencedSourceDescriptor.currentSchemaVersion else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let descriptor = try? decoder.decode(ReferencedSourceDescriptor.self, from: data) else {
            return false
        }
        return descriptor.id == expectedID
    }

    private func transactionRecordLoads(at url: URL, expectedLibraryID: UUID?) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let intent = try? decoder.decode(LibraryMutationIntent.self, from: data) else {
            return false
        }
        guard intent.schemaVersion == 1 || intent.schemaVersion == LibraryMutationIntent.currentSchemaVersion else {
            return false
        }
        return expectedLibraryID.map { intent.libraryID == $0 } ?? true
    }

    private func playlistRecordLoads(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PlaylistSidecar.self, from: data)) != nil
    }
}
