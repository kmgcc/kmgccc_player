//
//  LibraryMaintenanceService.swift
//  myPlayer2
//
//  Conservative maintenance for library sidecars and failed import residue.
//

import Foundation

nonisolated enum TrackDirectoryMaintenanceClassification: String, Sendable {
    case validTrackDirectory
    case failedImportAudioOnlyDirectory
    case suspiciousDirectoryDoNotDelete
    case referencedByLibraryDoNotDelete
    case importingDoNotDelete
}

nonisolated struct TrackDirectoryMaintenanceResult: Sendable {
    let trackID: UUID?
    let folderURL: URL
    let classification: TrackDirectoryMaintenanceClassification
    let reason: String
}

nonisolated struct TrackDirectoryCleanupReport: Sendable {
    let scannedCount: Int
    let deletedCount: Int
    let failedDeleteCount: Int
    let results: [TrackDirectoryMaintenanceResult]
}

nonisolated struct MetadataOrphanCleanupReport: Sendable {
    let deletedArtistIDs: [UUID]
    let deletedAlbumIDs: [UUID]
}

nonisolated struct LibraryMaintenanceService {
    private static let ignoredFileNames: Set<String> = [".DS_Store"]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func classifyTrackDirectory(
        _ folderURL: URL,
        tracksRootURL: URL = LocalLibraryPaths.tracksRootURL,
        referencedTrackIDs: Set<UUID>,
        importActivity: LibraryImportActivitySnapshot
    ) -> TrackDirectoryMaintenanceResult {
        guard isDirectChild(folderURL, of: tracksRootURL),
              let trackID = UUID(uuidString: folderURL.lastPathComponent)
        else {
            return TrackDirectoryMaintenanceResult(
                trackID: nil,
                folderURL: folderURL,
                classification: .suspiciousDirectoryDoNotDelete,
                reason: "not a direct UUID child of managed Tracks root"
            )
        }

        if referencedTrackIDs.contains(trackID) {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .referencedByLibraryDoNotDelete,
                reason: "track directory is referenced by loaded library index"
            )
        }

        if importActivity.isImporting || importActivity.activeTrackIDs.contains(trackID) {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .importingDoNotDelete,
                reason: "an import batch is active"
            )
        }

        let metaURL = folderURL.appendingPathComponent("meta.json")
        if fileManager.fileExists(atPath: metaURL.path) {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .validTrackDirectory,
                reason: "meta.json exists"
            )
        }

        let entries = visibleEntries(in: folderURL)
        guard entries.count == 1, let onlyFile = entries.first else {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .suspiciousDirectoryDoNotDelete,
                reason: "missing meta.json but contents are not exactly one app-managed audio file"
            )
        }

        guard isRegularFile(onlyFile),
              onlyFile.lastPathComponent.lowercased().hasPrefix("audio."),
              FileImportService.supportedExtensions.contains(onlyFile.pathExtension.lowercased())
        else {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .suspiciousDirectoryDoNotDelete,
                reason: "missing meta.json but sole file is not an app-managed audio file"
            )
        }

        return TrackDirectoryMaintenanceResult(
            trackID: trackID,
            folderURL: folderURL,
            classification: .failedImportAudioOnlyDirectory,
            reason: "unreferenced managed track folder contains only audio file and no meta.json"
        )
    }

    func cleanupFailedImportTrackDirectories(
        referencedTrackIDs: Set<UUID>,
        importActivity: LibraryImportActivitySnapshot,
        reason: String
    ) -> TrackDirectoryCleanupReport {
        let trackDirectories = directDirectories(at: LocalLibraryPaths.tracksRootURL)
        var results: [TrackDirectoryMaintenanceResult] = []
        var deletedCount = 0
        var failedDeleteCount = 0

        for folderURL in trackDirectories {
            let result = classifyTrackDirectory(
                folderURL,
                referencedTrackIDs: referencedTrackIDs,
                importActivity: importActivity
            )
            results.append(result)

            switch result.classification {
            case .failedImportAudioOnlyDirectory:
                Log.warning(
                    "[LibraryMaintenance] deleting failed import residue reason=\(reason) trackID=\(result.trackID?.uuidString ?? "nil") path=\(result.folderURL.path) classification=\(result.classification.rawValue) detail=\(result.reason)",
                    category: .library
                )
                do {
                    try fileManager.removeItem(at: result.folderURL)
                    deletedCount += 1
                } catch {
                    failedDeleteCount += 1
                    Log.error(
                        "[LibraryMaintenance] failed deleting track residue reason=\(reason) trackID=\(result.trackID?.uuidString ?? "nil") path=\(result.folderURL.path) error=\(error.localizedDescription)",
                        category: .library
                    )
                }
            case .suspiciousDirectoryDoNotDelete:
                Log.warning(
                    "[LibraryMaintenance] suspicious track directory retained reason=\(reason) trackID=\(result.trackID?.uuidString ?? "nil") path=\(result.folderURL.path) detail=\(result.reason)",
                    category: .library
                )
            case .validTrackDirectory, .referencedByLibraryDoNotDelete, .importingDoNotDelete:
                Log.debug(
                    "[LibraryMaintenance] retained track directory reason=\(reason) trackID=\(result.trackID?.uuidString ?? "nil") classification=\(result.classification.rawValue) detail=\(result.reason)",
                    category: .library
                )
            }
        }

        Log.info(
            "[LibraryMaintenance] track cleanup complete reason=\(reason) scanned=\(trackDirectories.count) deleted=\(deletedCount) failedDeletes=\(failedDeleteCount)",
            category: .library
        )

        return TrackDirectoryCleanupReport(
            scannedCount: trackDirectories.count,
            deletedCount: deletedCount,
            failedDeleteCount: failedDeleteCount,
            results: results
        )
    }

    func cleanupOrphanMetadataEntries(
        artistEntries: [ArtistEntry],
        albumEntries: [AlbumEntry],
        reason: String
    ) -> MetadataOrphanCleanupReport {
        var deletedArtistIDs: [UUID] = []
        var deletedAlbumIDs: [UUID] = []

        for entry in artistEntries where entry.trackCount == 0 {
            Log.warning(
                "[LibraryMaintenance] deleting zero-track artist reason=\(reason) artistID=\(entry.id.uuidString) name=\(entry.displayName) references=0 orphan=\(entry.isOrphaned)",
                category: .library
            )
            deletedArtistIDs.append(entry.id)
        }

        for entry in albumEntries where entry.trackCount == 0 {
            Log.warning(
                "[LibraryMaintenance] deleting zero-track album reason=\(reason) albumID=\(entry.id.uuidString) title=\(entry.displayTitle) artist=\(entry.primaryArtistDisplayName) references=0 orphan=\(entry.isOrphaned)",
                category: .library
            )
            deletedAlbumIDs.append(entry.id)
        }

        if !deletedArtistIDs.isEmpty || !deletedAlbumIDs.isEmpty {
            Log.info(
                "[LibraryMaintenance] metadata orphan cleanup complete reason=\(reason) artists=\(deletedArtistIDs.count) albums=\(deletedAlbumIDs.count)",
                category: .library
            )
        }

        return MetadataOrphanCleanupReport(
            deletedArtistIDs: deletedArtistIDs,
            deletedAlbumIDs: deletedAlbumIDs
        )
    }

    private func visibleEntries(in folderURL: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )) ?? [])
        .filter { !Self.ignoredFileNames.contains($0.lastPathComponent) }
    }

    private func directDirectories(at url: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
    }

    private func isDirectChild(_ url: URL, of parent: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == parent.standardizedFileURL.path
    }
}
