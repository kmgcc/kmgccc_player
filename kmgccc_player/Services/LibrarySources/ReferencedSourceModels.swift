//
//  ReferencedSourceModels.swift
//  kmgccc_player
//
//  Authoritative descriptors for user-authorized referenced-library roots.
//

import Foundation

nonisolated enum ReferencedSourceMode: String, Codable, Sendable {
    case directory
    /// A single audio file added as its own source (not a folder).
    case file
}

nonisolated enum ReferencedSourceStatus: String, Codable, Sendable {
    case available
    case stale
    case permissionDenied
    case offline
}

nonisolated enum ReferencedSourceMonitorPolicy: String, Codable, Sendable, CaseIterable {
    case inherit
    case on
    case off
}

/// A many-to-many source-to-playlist edge. The edge has its own identity so a
/// playlist can exclude one binding without hiding the same track contributed
/// by another source or a manual membership.
nonisolated struct ReferencedPlaylistSourceBinding: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let playlistID: UUID
    var relativePath: String?
    let createdAt: Date
    var monitorPolicy: ReferencedSourceMonitorPolicy
    var excludedTrackIDs: [UUID]
    /// Compatibility projection for schema-1 source descriptors. New code
    /// derives membership from the binding and the playlist-membership store.
    var legacyManagedTrackIDs: [UUID]?

    init(
        id: UUID = UUID(),
        playlistID: UUID,
        relativePath: String? = nil,
        createdAt: Date = Date(),
        monitorPolicy: ReferencedSourceMonitorPolicy = .inherit,
        excludedTrackIDs: [UUID] = [],
        legacyManagedTrackIDs: [UUID]? = nil
    ) {
        self.id = id
        self.playlistID = playlistID
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.monitorPolicy = monitorPolicy
        self.excludedTrackIDs = Array(Set(excludedTrackIDs)).sorted { $0.uuidString < $1.uuidString }
        self.legacyManagedTrackIDs = legacyManagedTrackIDs
    }
}

nonisolated struct ReferencedSourceDescriptor: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let id: UUID
    let mode: ReferencedSourceMode
    var rootBookmarkData: Data
    var lastKnownPath: String
    var displayName: String
    let createdAt: Date
    var lastScan: Date?
    var status: ReferencedSourceStatus
    var playlistBindings: [ReferencedPlaylistSourceBinding]
    /// Directory-relative paths ignored by automatic source scans. This is a
    /// non-destructive policy; existing Track authority is retained until a
    /// later explicit cleanup operation.
    var excludedRelativePaths: [String]

    /// Schema-1 compatibility projections. They intentionally map only to
    /// the first binding; all new behavior uses `playlistBindings`.
    var playlistID: UUID? {
        get { playlistBindings.first?.playlistID }
        set {
            guard let newValue else {
                playlistBindings.removeAll()
                return
            }
            if let index = playlistBindings.firstIndex(where: { $0.playlistID == newValue }) {
                if index != 0 {
                    let binding = playlistBindings.remove(at: index)
                    playlistBindings.insert(binding, at: 0)
                }
            } else {
                playlistBindings.insert(.init(playlistID: newValue), at: 0)
            }
        }
    }

    var playlistManagedTrackIDs: [UUID]? {
        get { playlistBindings.first?.legacyManagedTrackIDs }
        set {
            guard !playlistBindings.isEmpty else { return }
            playlistBindings[0].legacyManagedTrackIDs = newValue
        }
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        mode: ReferencedSourceMode = .directory,
        rootBookmarkData: Data,
        lastKnownPath: String,
        displayName: String,
        createdAt: Date = Date(),
        lastScan: Date? = nil,
        status: ReferencedSourceStatus = .available,
        playlistBindings: [ReferencedPlaylistSourceBinding] = [],
        excludedRelativePaths: [String] = [],
        playlistID: UUID? = nil,
        playlistManagedTrackIDs: [UUID]? = nil
    ) {
        self.schemaVersion = max(schemaVersion, Self.currentSchemaVersion)
        self.id = id
        self.mode = mode
        self.rootBookmarkData = rootBookmarkData
        self.lastKnownPath = lastKnownPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastScan = lastScan
        self.status = status
        var bindings = playlistBindings
        if bindings.isEmpty, let playlistID {
            bindings = [.init(playlistID: playlistID, legacyManagedTrackIDs: playlistManagedTrackIDs)]
        }
        self.playlistBindings = bindings
        self.excludedRelativePaths = Self.normalizedExcludedRelativePaths(excludedRelativePaths)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, mode, rootBookmarkData, lastKnownPath, displayName
        case createdAt, lastScan, status, playlistBindings, excludedRelativePaths
        case playlistID, playlistManagedTrackIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard storedSchema == 1 || storedSchema == 2 || storedSchema == Self.currentSchemaVersion else {
            throw ReferencedSourceStoreError.unsupportedSchema(storedSchema)
        }
        schemaVersion = Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(ReferencedSourceMode.self, forKey: .mode)
        rootBookmarkData = try container.decode(Data.self, forKey: .rootBookmarkData)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        displayName = try container.decode(String.self, forKey: .displayName)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastScan = try container.decodeIfPresent(Date.self, forKey: .lastScan)
        status = try container.decodeIfPresent(ReferencedSourceStatus.self, forKey: .status) ?? .available

        var bindings = try container.decodeIfPresent(
            [ReferencedPlaylistSourceBinding].self,
            forKey: .playlistBindings
        ) ?? []
        if bindings.isEmpty,
           let legacyPlaylistID = try container.decodeIfPresent(UUID.self, forKey: .playlistID) {
            bindings = [
                .init(
                    playlistID: legacyPlaylistID,
                    legacyManagedTrackIDs: try container.decodeIfPresent(
                        [UUID].self,
                        forKey: .playlistManagedTrackIDs
                    )
                )
            ]
        }
        playlistBindings = bindings
        let decodedExcludedPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedRelativePaths
        ) ?? []
        guard decodedExcludedPaths.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && TrackMediaLocator.isSafeRelativePath(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                )
        }) else {
            throw ReferencedSourceStoreError.invalidExcludedPath
        }
        excludedRelativePaths = Self.normalizedExcludedRelativePaths(decodedExcludedPaths)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(mode, forKey: .mode)
        try container.encode(rootBookmarkData, forKey: .rootBookmarkData)
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastScan, forKey: .lastScan)
        try container.encode(status, forKey: .status)
        try container.encode(playlistBindings, forKey: .playlistBindings)
        try container.encode(excludedRelativePaths, forKey: .excludedRelativePaths)
        // Keep a read-only compatibility projection for one older release.
        if let first = playlistBindings.first {
            try container.encode(first.playlistID, forKey: .playlistID)
            try container.encodeIfPresent(first.legacyManagedTrackIDs, forKey: .playlistManagedTrackIDs)
        }
    }

    static func normalizedExcludedRelativePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { path in
                guard !path.isEmpty, TrackMediaLocator.isSafeRelativePath(path) else {
                    return false
                }
                return seen.insert(path).inserted
            }
            .sorted {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0 < $1
            }
    }
}

nonisolated enum ReferencedSourceStoreError: Error, Equatable, LocalizedError {
    case incompleteSource(UUID)
    case missingSchema
    case unsupportedSchema(Int)
    case missingMode
    case unsupportedMode(String)
    case identifierMismatch(expected: UUID, actual: UUID)
    case emptyBookmark
    case invalidPath
    case invalidDisplayName
    case invalidExcludedPath

    var errorDescription: String? {
        switch self {
        case .incompleteSource(let id): return "Referenced source \(id) is missing source.json."
        case .missingSchema: return "Referenced source schemaVersion is missing."
        case .unsupportedSchema(let version): return "Unsupported referenced source schema: \(version)"
        case .missingMode: return "Referenced source mode is missing."
        case .unsupportedMode(let mode): return "Unsupported referenced source mode: \(mode)"
        case .identifierMismatch(let expected, let actual):
            return "Referenced source identifier mismatch: expected \(expected), found \(actual)"
        case .emptyBookmark: return "Referenced source bookmark is empty."
        case .invalidPath: return "Referenced source path is invalid."
        case .invalidDisplayName: return "Referenced source display name is empty."
        case .invalidExcludedPath: return "Referenced source exclusion path is invalid."
        }
    }
}
