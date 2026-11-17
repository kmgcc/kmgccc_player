import Foundation

/// One atomic visibility decision for the track sidecars of a physical program.
/// Pending records survive interruption and keep partially written albums out
/// of the library projection until the existing recovery workflow handles them.
nonisolated struct AudioProgramImportTransaction: Codable, Sendable {
    let id: UUID
    let groupID: UUID
    let trackIDs: Set<UUID>
    var committed: Bool
    var recoverySnapshotID: UUID? = nil

    static func root(_ paths: LibraryPaths) -> URL {
        paths.recoveryRootURL.appendingPathComponent("AudioProgramImports", isDirectory: true)
    }

    static func begin(groupID: UUID, trackIDs: Set<UUID>, paths: LibraryPaths, recoverySnapshotID: UUID? = nil) throws -> Self {
        let records = try load(paths: paths)
        guard !records.contains(where: { $0.groupID == groupID && !$0.committed }) else {
            throw AudioDecodingError.failed("此专辑有待恢复的导入，请先修复资料库")
        }
        let record = Self(id: UUID(), groupID: groupID, trackIDs: trackIDs, committed: false, recoverySnapshotID: recoverySnapshotID)
        try record.write(paths: paths)
        return record
    }

    func complete(paths: LibraryPaths) throws {
        var record = self
        record.committed = true
        try record.write(paths: paths)
    }

    private func write(paths: LibraryPaths) throws {
        let root = Self.root(paths)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: recordURL(paths), options: .atomic)
    }

    private func recordURL(_ paths: LibraryPaths) -> URL {
        Self.root(paths).appendingPathComponent("\(id.uuidString).json")
    }

    /// Loads uncommitted records. A single unreadable record is moved to the
    /// quarantine directory and skipped; only a systemic directory failure
    /// throws. Committed records are terminal and removed here so every scan
    /// does not decode them again.
    static func load(paths: LibraryPaths) throws -> [Self] {
        let directory = root(paths)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            Log.error("[AudioProgramImport] cannot list import records: \(error.localizedDescription)", category: .library)
            throw error
        }
        let decoder = JSONDecoder()
        var records: [Self] = []
        for file in files where file.pathExtension == "json" {
            let record: Self
            do {
                record = try decoder.decode(Self.self, from: Data(contentsOf: file))
            } catch {
                Self.quarantine(file, paths: paths, reason: "record is unreadable: \(error.localizedDescription)")
                continue
            }
            if record.committed {
                record.removeRecordFile(paths: paths)
                continue
            }
            records.append(record)
        }
        return records
    }

    /// Moves a record file into the quarantine directory, where later loads do
    /// not read it. A missing or unreadable file is only logged; scanning a
    /// library must not fail because of it.
    private static func quarantine(_ file: URL, paths: LibraryPaths, reason: String) {
        let invalidRoot = root(paths).appendingPathComponent("Invalid", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
            var target = invalidRoot.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                target = invalidRoot.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: file, to: target)
            Log.warning(
                "[AudioProgramImport] quarantined \(file.lastPathComponent) | \(reason)",
                category: .library
            )
        } catch {
            Log.warning(
                "[AudioProgramImport] cannot quarantine \(file.lastPathComponent) | \(reason); \(error.localizedDescription)",
                category: .library
            )
        }
    }

    private func quarantineRecordFile(paths: LibraryPaths, reason: String) {
        Self.quarantine(recordURL(paths), paths: paths, reason: reason)
    }

    private func removeRecordFile(paths: LibraryPaths) {
        let file = recordURL(paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.debug(
                "[AudioProgramImport] cannot remove completed record \(file.lastPathComponent): \(error.localizedDescription)",
                category: .library
            )
        }
    }

    func recover(paths: LibraryPaths) throws {
        if let recoverySnapshotID {
            guard let snapshot = try AudioProgramRecoverySnapshot.loadAll(paths: paths).first(where: { $0.id == recoverySnapshotID }) else {
                throw AudioDecodingError.failed("分轨更新的恢复快照缺失")
            }
            try snapshot.restoreTrackFiles(paths: paths)
            try complete(paths: paths)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecars = trackIDs.compactMap { id -> TrackSidecar? in
            guard let data = try? Data(contentsOf: paths.trackMetaURL(for: id)),
                  let sidecar = try? decoder.decode(TrackSidecar.self, from: data), sidecar.id == id else { return nil }
            return sidecar
        }
        let complete = sidecars.count == trackIDs.count && sidecars.allSatisfy { sidecar in
            let selection = sidecar.audioProperties?.mediaSelection
                ?? sidecar.mediaLocator.referencedFile?.primaryAudioProperties?.mediaSelection
            guard selection?.groupID == groupID else { return false }
            let media = sidecar.mediaLocator.managedLibraryRelativePath.flatMap { paths.libraryURL(from: $0) }
                ?? sidecar.mediaLocator.referencedFile.map { URL(fileURLWithPath: $0.lastKnownPath) }
            return media.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
        }
        if complete { try self.complete(paths: paths); return }
        let target = paths.recoveryRootURL.appendingPathComponent("IncompleteAudioPrograms/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for trackID in trackIDs {
            let source = paths.trackFolderURL(for: trackID)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: target.appendingPathComponent(trackID.uuidString))
            }
        }
        let record = Self.root(paths).appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.moveItem(at: record, to: target.appendingPathComponent("transaction.json"))
    }

    /// Replays interrupted range updates under the library's writer lease. A
    /// record whose recovery fails is quarantined and the remaining records
    /// continue, so a damaged record cannot keep the library from opening.
    static func recoverInterruptedUpdates(paths: LibraryPaths) {
        let records: [Self]
        do {
            records = try load(paths: paths)
        } catch {
            Log.warning(
                "[AudioProgramImport] cannot read import records: \(error.localizedDescription); skipping recovery",
                category: .library
            )
            return
        }
        for record in records where record.recoverySnapshotID != nil {
            do {
                try record.recover(paths: paths)
                record.removeRecordFile(paths: paths)
            } catch {
                record.quarantineRecordFile(paths: paths, reason: error.localizedDescription)
            }
        }
    }

    static func pendingTrackIDs(paths: LibraryPaths) throws -> Set<UUID> {
        try load(paths: paths).filter { !$0.committed && $0.recoverySnapshotID == nil }.reduce(into: Set<UUID>()) { $0.formUnion($1.trackIDs) }
    }
}
