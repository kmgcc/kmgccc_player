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
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    static func load(paths: LibraryPaths) throws -> [Self] {
        let root = root(paths)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Self.self, from: Data(contentsOf: $0)) }
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

    static func recoverInterruptedUpdates(paths: LibraryPaths) throws {
        for record in try load(paths: paths) where !record.committed && record.recoverySnapshotID != nil {
            try record.recover(paths: paths)
        }
    }

    static func pendingTrackIDs(paths: LibraryPaths) throws -> Set<UUID> {
        try load(paths: paths).filter { !$0.committed && $0.recoverySnapshotID == nil }.reduce(into: Set<UUID>()) { $0.formUnion($1.trackIDs) }
    }
}
