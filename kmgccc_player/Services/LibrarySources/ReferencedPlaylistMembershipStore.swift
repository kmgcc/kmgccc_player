//
//  ReferencedPlaylistMembershipStore.swift
//  kmgccc_player
//
//  Durable source-aware membership edges for referenced playlists.
//

import Foundation

/// Runtime-independent authority for the difference between a manually
/// curated playlist item and an item contributed by one or more source
/// bindings. Playlist sidecars still own the ordered list used by the player;
/// this store prevents a source scan from reviving an explicitly removed item.
nonisolated struct ReferencedPlaylistMembership: Codable, Sendable, Equatable, Hashable {
    let playlistID: UUID
    let trackID: UUID
    var manual: Bool
    var sourceBindingIDs: [UUID]
    var excludedBindingIDs: [UUID]
    var addedAt: Date

    init(
        playlistID: UUID,
        trackID: UUID,
        manual: Bool = false,
        sourceBindingIDs: [UUID] = [],
        excludedBindingIDs: [UUID] = [],
        addedAt: Date = Date()
    ) {
        self.playlistID = playlistID
        self.trackID = trackID
        self.manual = manual
        self.sourceBindingIDs = Array(Set(sourceBindingIDs)).sorted { $0.uuidString < $1.uuidString }
        self.excludedBindingIDs = Array(Set(excludedBindingIDs)).sorted { $0.uuidString < $1.uuidString }
        self.addedAt = addedAt
    }

    var isLive: Bool { manual || !sourceBindingIDs.isEmpty }
}

nonisolated struct ReferencedPlaylistMembershipFile: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var memberships: [ReferencedPlaylistMembership]

    init(memberships: [ReferencedPlaylistMembership] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.memberships = memberships
    }
}

actor ReferencedPlaylistMembershipStore {
    nonisolated let paths: LibraryPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loaded = false
    private var memberships: [ReferencedPlaylistMembership] = []
    /// Key `playlistUUID:trackUUID` → position in `memberships`. Maintained
    /// alongside the array so per-track lookups stay O(1) during source
    /// scans; the array remains authoritative for ordering and persistence.
    private var membershipIndex: [String: Int] = [:]

    init(paths: LibraryPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadAll() throws -> [ReferencedPlaylistMembership] {
        try ensureLoaded()
        return memberships
    }

    /// Captures the complete membership projection so a cross-store playlist
    /// commit can restore it if the playlist sidecar write fails.
    func snapshot() throws -> [ReferencedPlaylistMembership] {
        try ensureLoaded()
        return memberships
    }

    /// Restores a previously captured projection and persists it atomically.
    /// This is intentionally explicit: callers use it only as compensation
    /// for a failed transaction, never as a second source of truth.
    func restore(_ snapshot: [ReferencedPlaylistMembership]) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        memberships = normalize(snapshot)
        rebuildMembershipIndex()
        do {
            try persist()
        } catch {
            memberships = originalMemberships
            membershipIndex = originalIndex
            throw error
        }
    }

    /// Converts the legacy playlist sidecar projection into durable source
    /// edges. The caller supplies only IDs and source membership decisions so
    /// this actor never crosses a SwiftData object graph boundary.
    func migrateLegacy(
        playlistID: UUID,
        bindingID: UUID,
        trackIDs: [UUID],
        sourceTrackIDs: [UUID],
        legacyManagedTrackIDs: [UUID]
    ) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        let sourceIDs = Set(sourceTrackIDs).union(legacyManagedTrackIDs)
        var changed = false
        for trackID in Set(trackIDs) {
            var membership = findMembership(playlistID: playlistID, trackID: trackID)
                ?? .init(playlistID: playlistID, trackID: trackID)
            let old = membership
            if sourceIDs.contains(trackID) {
                membership.sourceBindingIDs = Array(
                    Set(membership.sourceBindingIDs).union([bindingID])
                ).sorted { $0.uuidString < $1.uuidString }
                membership.excludedBindingIDs.removeAll { $0 == bindingID }
            } else if !membership.manual {
                membership.manual = true
            }
            guard membership != old else { continue }
            upsert(membership)
            changed = true
        }
        if changed {
            try persistOrRestore(originalMemberships, originalIndex: originalIndex)
        }
    }

    func ensureManualMemberships(playlistID: UUID, trackIDs: [UUID]) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        let existing = Set(memberships.filter { $0.playlistID == playlistID }.map(\.trackID))
        var changed = false
        for trackID in Set(trackIDs) where !existing.contains(trackID) {
            upsert(.init(playlistID: playlistID, trackID: trackID, manual: true))
            changed = true
        }
        if changed {
            try persistOrRestore(originalMemberships, originalIndex: originalIndex)
        }
    }

    func recordManualAddition(playlistID: UUID, trackIDs: [UUID]) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        var changed = false
        for trackID in Set(trackIDs) {
            var membership = findMembership(playlistID: playlistID, trackID: trackID)
                ?? .init(playlistID: playlistID, trackID: trackID)
            if !membership.manual || !membership.excludedBindingIDs.isEmpty {
                membership.manual = true
                membership.excludedBindingIDs.removeAll()
                upsert(membership)
                changed = true
            }
        }
        if changed {
            try persistOrRestore(originalMemberships, originalIndex: originalIndex)
        }
    }

    func recordManualRemoval(
        playlistID: UUID,
        trackIDs: [UUID],
        bindingIDs: [UUID] = []
    ) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        var changed = false
        for trackID in Set(trackIDs) {
            guard var membership = findMembership(playlistID: playlistID, trackID: trackID) else {
                // A missing record represents a purely manual old sidecar
                // item. Persist a tombstone so a later source binding cannot
                // infer that the user wanted it back.
                upsert(.init(
                    playlistID: playlistID,
                    trackID: trackID,
                    manual: false,
                    excludedBindingIDs: bindingIDs
                ))
                changed = true
                continue
            }
            let old = membership
            membership.manual = false
            membership.excludedBindingIDs = Array(
                Set(membership.excludedBindingIDs)
                    .union(membership.sourceBindingIDs)
                    .union(bindingIDs)
            ).sorted { $0.uuidString < $1.uuidString }
            if membership != old {
                upsert(membership)
                changed = true
            }
        }
        if changed {
            try persistOrRestore(originalMemberships, originalIndex: originalIndex)
        }
    }

    func recordSourceContribution(
        playlistID: UUID,
        trackID: UUID,
        bindingIDs: [UUID]
    ) throws {
        guard !bindingIDs.isEmpty else { return }
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        var changed = false
        for bindingID in bindingIDs {
            changed = applyingSourceContribution(
                playlistID: playlistID,
                trackID: trackID,
                bindingID: bindingID
            ) || changed
        }
        if changed {
            try persistOrRestore(originalMemberships, originalIndex: originalIndex)
        }
    }

    /// Batched form of `recordSourceContribution`: applies every edge in
    /// memory and persists the membership file once, so a source scan
    /// contributing thousands of tracks costs one encode + write instead of
    /// one per track. Exclusion semantics are identical to the single-edge
    /// API: recording a contribution never clears a durable exclusion (see
    /// `recordSourceContribution`).
    func recordSourceContributions(
        _ entries: [(playlistID: UUID, trackID: UUID, bindingID: UUID)]
    ) throws {
        guard !entries.isEmpty else { return }
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        var changed = false
        for entry in entries {
            changed = applyingSourceContribution(
                playlistID: entry.playlistID,
                trackID: entry.trackID,
                bindingID: entry.bindingID
            ) || changed
        }
        guard changed else { return }
        try persistOrRestore(originalMemberships, originalIndex: originalIndex)
    }

    @discardableResult
    private func applyingSourceContribution(
        playlistID: UUID,
        trackID: UUID,
        bindingID: UUID
    ) -> Bool {
        var membership = findMembership(playlistID: playlistID, trackID: trackID)
            ?? .init(playlistID: playlistID, trackID: trackID)
        let old = membership
        membership.sourceBindingIDs = Array(
            Set(membership.sourceBindingIDs).union([bindingID])
        ).sorted { $0.uuidString < $1.uuidString }
        // An explicit manual removal is a durable exclusion. A later source
        // scan must not erase it merely because the same file is discovered
        // again. Manual addition is the explicit action that clears it.
        upsert(membership)
        return membership != old
    }

    func removeSourceContribution(
        playlistID: UUID,
        trackID: UUID,
        bindingID: UUID
    ) throws {
        try ensureLoaded()
        guard var membership = findMembership(playlistID: playlistID, trackID: trackID) else { return }
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        membership.sourceBindingIDs.removeAll { $0 == bindingID }
        if !membership.isLive && membership.excludedBindingIDs.isEmpty {
            removeMembership(playlistID: playlistID, trackID: trackID)
        } else {
            upsert(membership)
        }
        try persistOrRestore(originalMemberships, originalIndex: originalIndex)
    }

    func membership(
        playlistID: UUID,
        trackID: UUID
    ) throws -> ReferencedPlaylistMembership? {
        try ensureLoaded()
        return findMembership(playlistID: playlistID, trackID: trackID)
    }

    func memberships(for playlistID: UUID) throws -> [ReferencedPlaylistMembership] {
        try ensureLoaded()
        return memberships.filter { $0.playlistID == playlistID }
    }

    /// Returns whether a track is still intentionally referenced by any
    /// playlist. Source removal may delete an orphaned library row only when
    /// this is false; a manual playlist entry is a valid remaining owner even
    /// after its last source location disappears.
    func hasLiveMembership(trackID: UUID) throws -> Bool {
        try ensureLoaded()
        return memberships.contains { $0.trackID == trackID && $0.isLive }
    }

    func removePlaylist(playlistID: UUID) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        let previousCount = memberships.count
        memberships.removeAll { $0.playlistID == playlistID }
        guard previousCount != memberships.count else { return }
        rebuildMembershipIndex()
        try persistOrRestore(originalMemberships, originalIndex: originalIndex)
    }

    func removeTrack(trackID: UUID) throws {
        try ensureLoaded()
        let originalMemberships = memberships
        let originalIndex = membershipIndex
        let previousCount = memberships.count
        memberships.removeAll { $0.trackID == trackID }
        guard previousCount != memberships.count else { return }
        rebuildMembershipIndex()
        try persistOrRestore(originalMemberships, originalIndex: originalIndex)
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: paths.playlistMembershipsURL.path) else { return }
        do {
            let file = try decoder.decode(
                ReferencedPlaylistMembershipFile.self,
                from: Data(contentsOf: paths.playlistMembershipsURL)
            )
            guard file.schemaVersion == ReferencedPlaylistMembershipFile.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            memberships = normalize(file.memberships)
            rebuildMembershipIndex()
        } catch {
            let quarantine = paths.playlistMembershipsURL
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try? fileManager.moveItem(at: paths.playlistMembershipsURL, to: quarantine)
            memberships = []
            membershipIndex = [:]
            Log.warning(
                "[ReferencedPlaylistMembershipStore] reset corrupt membership file: \(error)",
                category: .library
            )
        }
    }

    private func persist() throws {
        try fileManager.createDirectory(at: paths.sourcesRootURL, withIntermediateDirectories: true)
        let file = ReferencedPlaylistMembershipFile(memberships: normalize(memberships))
        try encoder.encode(file).write(to: paths.playlistMembershipsURL, options: .atomic)
    }

    private func persistOrRestore(
        _ originalMemberships: [ReferencedPlaylistMembership],
        originalIndex: [String: Int]
    ) throws {
        do {
            try persist()
        } catch {
            memberships = originalMemberships
            membershipIndex = originalIndex
            throw error
        }
    }

    private func findMembership(playlistID: UUID, trackID: UUID) -> ReferencedPlaylistMembership? {
        guard let index = membershipIndex[Self.membershipKey(playlistID, trackID)],
              index < memberships.count else { return nil }
        let candidate = memberships[index]
        guard candidate.playlistID == playlistID && candidate.trackID == trackID else { return nil }
        return candidate
    }

    private func upsert(_ value: ReferencedPlaylistMembership) {
        let key = Self.membershipKey(value.playlistID, value.trackID)
        if let index = membershipIndex[key],
           index < memberships.count,
           memberships[index].playlistID == value.playlistID,
           memberships[index].trackID == value.trackID {
            memberships[index] = value
            return
        }
        if let index = memberships.firstIndex(where: {
            $0.playlistID == value.playlistID && $0.trackID == value.trackID
        }) {
            memberships[index] = value
            membershipIndex[key] = index
            return
        }
        memberships.append(value)
        membershipIndex[key] = memberships.count - 1
    }

    private static func membershipKey(_ playlistID: UUID, _ trackID: UUID) -> String {
        "\(playlistID.uuidString):\(trackID.uuidString)"
    }

    private func rebuildMembershipIndex() {
        var index: [String: Int] = [:]
        index.reserveCapacity(memberships.count)
        for (position, membership) in memberships.enumerated() {
            index[Self.membershipKey(membership.playlistID, membership.trackID)] = position
        }
        membershipIndex = index
    }

    private func removeMembership(playlistID: UUID, trackID: UUID) {
        let key = Self.membershipKey(playlistID, trackID)
        guard let position = membershipIndex.removeValue(forKey: key),
              position < memberships.count else { return }
        memberships.remove(at: position)
        for shifted in position..<memberships.count {
            let shiftedMembership = memberships[shifted]
            membershipIndex[Self.membershipKey(shiftedMembership.playlistID, shiftedMembership.trackID)] = shifted
        }
    }

    private func normalize(_ values: [ReferencedPlaylistMembership]) -> [ReferencedPlaylistMembership] {
        var byKey: [String: ReferencedPlaylistMembership] = [:]
        for value in values {
            let key = "\(value.playlistID.uuidString):\(value.trackID.uuidString)"
            if var existing = byKey[key] {
                existing.manual = existing.manual || value.manual
                existing.sourceBindingIDs = Array(
                    Set(existing.sourceBindingIDs).union(value.sourceBindingIDs)
                ).sorted { $0.uuidString < $1.uuidString }
                existing.excludedBindingIDs = Array(
                    Set(existing.excludedBindingIDs).union(value.excludedBindingIDs)
                ).sorted { $0.uuidString < $1.uuidString }
                existing.addedAt = min(existing.addedAt, value.addedAt)
                byKey[key] = existing
            } else {
                byKey[key] = value
            }
        }
        return byKey.values.sorted {
            if $0.playlistID != $1.playlistID { return $0.playlistID.uuidString < $1.playlistID.uuidString }
            return $0.addedAt < $1.addedAt
        }
    }
}
