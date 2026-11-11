//
//  LibraryMaintenanceService.swift
//  myPlayer2
//
//  Conservative maintenance for library sidecars and failed import residue.
//

import Darwin
import Foundation

nonisolated enum TrackDirectoryMaintenanceClassification: String, Sendable {
    case validTrackDirectory
    case failedImportAudioOnlyDirectory
    case suspiciousDirectoryDoNotDelete
    case referencedByLibraryDoNotDelete
    case importingDoNotDelete
}

nonisolated struct LibraryMaintenanceFileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

nonisolated struct TrackDirectoryMaintenanceResult: Sendable {
    let trackID: UUID?
    let folderURL: URL
    let classification: TrackDirectoryMaintenanceClassification
    let reason: String
    /// Identity of the sole audio file observed during classification. A
    /// replacement between classification and cleanup changes the inode.
    var audioIdentity: LibraryMaintenanceFileIdentity?
    /// Identity of the directory itself. Renaming a directory keeps its
    /// inode, so comparing it after the move proves which tree was moved even
    /// when the parent path was replaced.
    var folderIdentity: LibraryMaintenanceFileIdentity?
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
    private static let ignoredFileNames: Set<String> = [
        ".DS_Store",
        ImportTrackFolderMarker.fileName,
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func classifyTrackDirectory(
        _ folderURL: URL,
        tracksRootURL: URL,
        referencedTrackIDs: Set<UUID>,
        importActivity: LibraryImportActivitySnapshot,
        protectedTrackIDs: Set<UUID> = []
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

        if protectedTrackIDs.contains(trackID) {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .importingDoNotDelete,
                reason: "retained by the import session that created it"
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

        // A folder without this marker may have been prepared by the user or
        // by another writer. Only a folder this import session created is
        // residue that may be removed.
        guard ImportTrackFolderMarker.marksOwnership(
            of: folderURL,
            trackID: trackID,
            fileManager: fileManager
        ) else {
            return TrackDirectoryMaintenanceResult(
                trackID: trackID,
                folderURL: folderURL,
                classification: .suspiciousDirectoryDoNotDelete,
                reason: "folder has no import ownership marker"
            )
        }

        return TrackDirectoryMaintenanceResult(
            trackID: trackID,
            folderURL: folderURL,
            classification: .failedImportAudioOnlyDirectory,
            reason: "unreferenced managed track folder contains only audio file and no meta.json",
            audioIdentity: fileIdentity(of: onlyFile),
            folderIdentity: directoryIdentity(of: folderURL)
        )
    }

    private func directoryIdentity(of url: URL) -> LibraryMaintenanceFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return LibraryMaintenanceFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func fileIdentity(of url: URL) -> LibraryMaintenanceFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return LibraryMaintenanceFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    func cleanupFailedImportTrackDirectories(
        tracksRootURL: URL,
        referencedTrackIDs: Set<UUID>,
        importActivity: LibraryImportActivitySnapshot,
        protectedTrackIDs: Set<UUID> = [],
        reason: String
    ) -> TrackDirectoryCleanupReport {
        let trackDirectories = directDirectories(at: tracksRootURL)
        var results: [TrackDirectoryMaintenanceResult] = []
        var deletedCount = 0
        var failedDeleteCount = 0

        for folderURL in trackDirectories {
            let result = classifyTrackDirectory(
                folderURL,
                tracksRootURL: tracksRootURL,
                referencedTrackIDs: referencedTrackIDs,
                importActivity: importActivity,
                protectedTrackIDs: protectedTrackIDs
            )
            results.append(result)

            switch result.classification {
            case .failedImportAudioOnlyDirectory:
                switch removeResidueDirectory(
                    folderURL,
                    tracksRootURL: tracksRootURL,
                    expectedTrackID: result.trackID,
                    expectedAudioIdentity: result.audioIdentity,
                    expectedFolderIdentity: result.folderIdentity
                ) {
                case .deleted:
                    deletedCount += 1
                    Log.warning(
                        "[LibraryMaintenance] removed verified failed import residue reason=\(reason) trackID=\(result.trackID?.uuidString ?? "nil") path=\(result.folderURL.path)",
                        category: .library
                    )
                case .changed:
                    failedDeleteCount += 1
                    Log.warning(
                        "[LibraryMaintenance] retained import residue because its contents changed reason=\(reason) path=\(result.folderURL.path)",
                        category: .library
                    )
                case .failed(let detail):
                    failedDeleteCount += 1
                    Log.error(
                        "[LibraryMaintenance] failed removing import residue reason=\(reason) path=\(result.folderURL.path) error=\(detail)",
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

        if deletedCount > 0 || failedDeleteCount > 0 {
            Log.info(
                "[LibraryMaintenance] track cleanup complete reason=\(reason) scanned=\(trackDirectories.count) deleted=\(deletedCount) failedDeletes=\(failedDeleteCount)",
                category: .library
            )
        }

        return TrackDirectoryCleanupReport(
            scannedCount: trackDirectories.count,
            deletedCount: deletedCount,
            failedDeleteCount: failedDeleteCount,
            results: results
        )
    }

    private enum ResidueRemovalResult {
        case deleted
        case changed
        case failed(String)
    }

    /// Renames the candidate inside the same volume before deleting it. The
    /// rename is atomic, so content placed at the original path afterwards is
    /// never part of the deleted tree; the renamed tree is re-checked and
    /// restored when it no longer has exactly the shape that was classified.
    private func removeResidueDirectory(
        _ folderURL: URL,
        tracksRootURL: URL,
        expectedTrackID: UUID?,
        expectedAudioIdentity: LibraryMaintenanceFileIdentity?,
        expectedFolderIdentity: LibraryMaintenanceFileIdentity?
    ) -> ResidueRemovalResult {
        let quarantineName = ".kmgccc-import-residue-\(UUID().uuidString)"
        let quarantineURL = tracksRootURL.appendingPathComponent(quarantineName, isDirectory: true)
        do {
            try fileManager.moveItem(at: folderURL, to: quarantineURL)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let expectedTrackID,
              let expectedFolderIdentity,
              let movedFolderIdentity = directoryIdentity(of: quarantineURL),
              sameObject(expectedFolderIdentity, movedFolderIdentity),
              ImportTrackFolderMarker.marksOwnership(
                  of: quarantineURL,
                  trackID: expectedTrackID,
                  fileManager: fileManager
              ) else {
            restoreQuarantinedDirectory(quarantineURL, to: folderURL)
            return .changed
        }
        let entries = visibleEntries(in: quarantineURL)
        guard entries.count == 1,
              let onlyFile = entries.first,
              isRegularFile(onlyFile),
              onlyFile.lastPathComponent.lowercased().hasPrefix("audio."),
              FileImportService.supportedExtensions.contains(onlyFile.pathExtension.lowercased()),
              expectedAudioIdentity != nil,
              fileIdentity(of: onlyFile) == expectedAudioIdentity else {
            restoreQuarantinedDirectory(quarantineURL, to: folderURL)
            return .changed
        }
        do {
            try fileManager.removeItem(at: quarantineURL)
            return .deleted
        } catch {
            let detail = error.localizedDescription
            restoreQuarantinedDirectory(quarantineURL, to: folderURL)
            return .failed(detail)
        }
    }

    /// Renaming can change metadata even though the object stays the same.
    /// Device and inode identify the directory across the move.
    private func sameObject(
        _ lhs: LibraryMaintenanceFileIdentity,
        _ rhs: LibraryMaintenanceFileIdentity
    ) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    private func restoreQuarantinedDirectory(_ quarantineURL: URL, to originalURL: URL) {
        guard !fileManager.fileExists(atPath: originalURL.path) else {
            // Another process recreated the original path. Keep the renamed
            // copy so nothing is lost, and leave it for manual review.
            Log.warning(
                "[LibraryMaintenance] import residue kept at \(quarantineURL.path); original path was recreated",
                category: .library
            )
            return
        }
        do { try fileManager.moveItem(at: quarantineURL, to: originalURL) }
        catch {
            Log.warning(
                "[LibraryMaintenance] import residue kept at \(quarantineURL.path) after restore failure: \(error.localizedDescription)",
                category: .library
            )
        }
    }

    func cleanupOrphanMetadataEntries(
        artistEntries: [ArtistEntry],
        albumEntries: [AlbumEntry],
        reason: String
    ) -> MetadataOrphanCleanupReport {
        var deletedArtistIDs: [UUID] = []
        var deletedAlbumIDs: [UUID] = []

        for entry in artistEntries where entry.trackCount == 0 {
            // Zero tracks is not proof of an orphan: an incomplete scan can
            // hide every track of an artist that still owns user-edited
            // metadata. Only entries the sync itself declared orphaned and
            // free of user content may be removed.
            guard entry.isOrphaned, entry.hasUserEditedContent == false else { continue }
            Log.warning(
                "[LibraryMaintenance] deleting zero-track artist reason=\(reason) artistID=\(entry.id.uuidString) name=\(entry.displayName) references=0 orphan=\(entry.isOrphaned)",
                category: .library
            )
            deletedArtistIDs.append(entry.id)
        }

        for entry in albumEntries where entry.trackCount == 0 {
            guard entry.isOrphaned, entry.hasUserEditedContent == false else { continue }
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
