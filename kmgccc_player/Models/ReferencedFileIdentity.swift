//
//  ReferencedFileIdentity.swift
//  myPlayer2
//
//  Stable identity and source-membership values for referenced local files.
//

import Foundation

nonisolated struct ReferencedFileIdentity: Codable, Sendable, Hashable {
    var volumeUUID: String?
    var resourceIdentifierArchive: Data?

    enum CodingKeys: String, CodingKey {
        case volumeUUID
        case resourceIdentifierArchive
    }

    init(volumeUUID: String? = nil, resourceIdentifierArchive: Data? = nil) {
        self.volumeUUID = volumeUUID
        self.resourceIdentifierArchive = resourceIdentifierArchive
    }
}

nonisolated struct ReferencedFileFingerprint: Codable, Sendable, Equatable, Hashable {
    var identity: ReferencedFileIdentity?
    var fileSize: Int64
    var modifiedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case identity
        case fileSize
        case modifiedAt
    }

    init(identity: ReferencedFileIdentity? = nil, fileSize: Int64, modifiedAt: TimeInterval) {
        self.identity = identity
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

nonisolated struct ReferencedSourceMembership: Codable, Sendable, Hashable {
    var sourceID: UUID
    var relativePath: String

    enum CodingKeys: String, CodingKey {
        case sourceID
        case relativePath
    }

    init(sourceID: UUID, relativePath: String) {
        self.sourceID = sourceID
        self.relativePath = relativePath
    }
}

/// One physical, playable location for a referenced track.
///
/// The first location is kept in the legacy fields of `ReferencedFileLocator`
/// for compatibility with existing sidecars. Additional locations are stored
/// in `ReferencedFileLocator.alternateLocations` and are considered in the
/// same resolver order. A location is deliberately independent from a
/// playlist membership: the same file can contribute to several playlists
/// without duplicating the physical identity.
nonisolated struct ReferencedTrackLocation: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    var fileBookmarkData: Data
    var sourceMemberships: [ReferencedSourceMembership]
    var lastKnownPath: String
    var fingerprint: ReferencedFileFingerprint?
    var ncmSourceIdentity: ReferencedFileIdentity?
    /// Technical properties of the physical file at this location (schema 9).
    var audioProperties: TrackAudioProperties?
    /// Hex SHA-256 of the audio bytes at this location. Computed on demand in
    /// a later wave; storage only for now.
    var contentDigest: String?
    /// Availability of this specific location using the existing
    /// `TrackAvailability` raw values. The track-level `availability` remains
    /// the resolver's aggregate.
    var availabilityRaw: String?

    init(
        id: UUID = UUID(),
        fileBookmarkData: Data,
        sourceMemberships: [ReferencedSourceMembership] = [],
        lastKnownPath: String = "",
        fingerprint: ReferencedFileFingerprint? = nil,
        ncmSourceIdentity: ReferencedFileIdentity? = nil,
        audioProperties: TrackAudioProperties? = nil,
        contentDigest: String? = nil,
        availabilityRaw: String? = nil
    ) {
        self.id = id
        self.fileBookmarkData = fileBookmarkData
        self.sourceMemberships = sourceMemberships
        self.lastKnownPath = lastKnownPath
        self.fingerprint = fingerprint
        self.ncmSourceIdentity = ncmSourceIdentity
        self.audioProperties = audioProperties
        self.contentDigest = contentDigest
        self.availabilityRaw = availabilityRaw
    }
}

nonisolated struct ReferencedFileLocator: Codable, Sendable, Equatable {
    var fileBookmarkData: Data
    var sourceMemberships: [ReferencedSourceMembership]
    var primarySourceID: UUID?
    var lastKnownPath: String
    var fingerprint: ReferencedFileFingerprint?
    var ncmSourceIdentity: ReferencedFileIdentity?
    /// Locations beyond the legacy primary location. This is empty for old
    /// sidecars and is populated when duplicate physical copies are merged.
    var alternateLocations: [ReferencedTrackLocation]
    /// Stable id of the synthesized legacy primary location (schema 9).
    /// Older sidecars never stored one; decoding generates it once and the
    /// next ordinary save persists it, so it stops changing per access
    /// without forcing a disk rewrite.
    var primaryLocationID: UUID
    /// Schema 9 per-location metadata of the legacy primary location. The
    /// primary is synthesized from flat legacy fields, so its copy-specific
    /// values need their own storage slots here and are projected into
    /// `locations[0]`.
    var primaryAudioProperties: TrackAudioProperties?
    var primaryContentDigest: String?
    var primaryAvailabilityRaw: String?

    enum CodingKeys: String, CodingKey {
        case fileBookmarkData
        case sourceMemberships
        case primarySourceID
        case lastKnownPath
        case fingerprint
        case ncmSourceIdentity
        case alternateLocations
        case primaryLocationID
        case primaryAudioProperties
        case primaryContentDigest
        case primaryAvailabilityRaw
    }

    init(
        fileBookmarkData: Data,
        sourceMemberships: [ReferencedSourceMembership] = [],
        primarySourceID: UUID? = nil,
        lastKnownPath: String = "",
        fingerprint: ReferencedFileFingerprint? = nil,
        ncmSourceIdentity: ReferencedFileIdentity? = nil,
        alternateLocations: [ReferencedTrackLocation] = [],
        primaryLocationID: UUID = UUID(),
        primaryAudioProperties: TrackAudioProperties? = nil,
        primaryContentDigest: String? = nil,
        primaryAvailabilityRaw: String? = nil
    ) {
        self.fileBookmarkData = fileBookmarkData
        self.sourceMemberships = sourceMemberships
        self.primarySourceID = primarySourceID
        self.lastKnownPath = lastKnownPath
        self.fingerprint = fingerprint
        self.ncmSourceIdentity = ncmSourceIdentity
        self.alternateLocations = alternateLocations
        self.primaryLocationID = primaryLocationID
        self.primaryAudioProperties = primaryAudioProperties
        self.primaryContentDigest = primaryContentDigest
        self.primaryAvailabilityRaw = primaryAvailabilityRaw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileBookmarkData = try container.decodeIfPresent(Data.self, forKey: .fileBookmarkData) ?? Data()
        sourceMemberships = try container.decodeIfPresent([ReferencedSourceMembership].self, forKey: .sourceMemberships) ?? []
        primarySourceID = try container.decodeIfPresent(UUID.self, forKey: .primarySourceID)
        lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        fingerprint = try container.decodeIfPresent(ReferencedFileFingerprint.self, forKey: .fingerprint)
        ncmSourceIdentity = try container.decodeIfPresent(ReferencedFileIdentity.self, forKey: .ncmSourceIdentity)
        alternateLocations = try container.decodeIfPresent([ReferencedTrackLocation].self, forKey: .alternateLocations) ?? []
        primaryLocationID = try container.decodeIfPresent(UUID.self, forKey: .primaryLocationID) ?? UUID()
        primaryAudioProperties = try container.decodeIfPresent(TrackAudioProperties.self, forKey: .primaryAudioProperties)
        primaryContentDigest = try container.decodeIfPresent(String.self, forKey: .primaryContentDigest)
        primaryAvailabilityRaw = try container.decodeIfPresent(String.self, forKey: .primaryAvailabilityRaw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileBookmarkData, forKey: .fileBookmarkData)
        try container.encode(sourceMemberships, forKey: .sourceMemberships)
        try container.encodeIfPresent(primarySourceID, forKey: .primarySourceID)
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(ncmSourceIdentity, forKey: .ncmSourceIdentity)
        if !alternateLocations.isEmpty {
            try container.encode(alternateLocations, forKey: .alternateLocations)
        }
        try container.encode(primaryLocationID, forKey: .primaryLocationID)
        try container.encodeIfPresent(primaryAudioProperties, forKey: .primaryAudioProperties)
        try container.encodeIfPresent(primaryContentDigest, forKey: .primaryContentDigest)
        try container.encodeIfPresent(primaryAvailabilityRaw, forKey: .primaryAvailabilityRaw)
    }

    /// Two locators are logically equal when they describe the same physical
    /// topology. The generated primary location id is persistence bookkeeping
    /// and must not influence equality, otherwise pre-schema-9 data would not
    /// compare equal to its own re-decoded form before the first re-save.
    static func == (lhs: ReferencedFileLocator, rhs: ReferencedFileLocator) -> Bool {
        lhs.fileBookmarkData == rhs.fileBookmarkData
            && lhs.sourceMemberships == rhs.sourceMemberships
            && lhs.primarySourceID == rhs.primarySourceID
            && lhs.lastKnownPath == rhs.lastKnownPath
            && lhs.fingerprint == rhs.fingerprint
            && lhs.ncmSourceIdentity == rhs.ncmSourceIdentity
            && lhs.alternateLocations == rhs.alternateLocations
            && lhs.primaryAudioProperties == rhs.primaryAudioProperties
            && lhs.primaryContentDigest == rhs.primaryContentDigest
            && lhs.primaryAvailabilityRaw == rhs.primaryAvailabilityRaw
    }

    /// All locations in resolver preference order. The legacy primary
    /// location remains first so old data keeps its existing behavior.
    var locations: [ReferencedTrackLocation] {
        let primary = ReferencedTrackLocation(
            id: primaryLocationID,
            fileBookmarkData: fileBookmarkData,
            sourceMemberships: sourceMemberships,
            lastKnownPath: lastKnownPath,
            fingerprint: fingerprint,
            ncmSourceIdentity: ncmSourceIdentity,
            audioProperties: primaryAudioProperties,
            contentDigest: primaryContentDigest,
            availabilityRaw: primaryAvailabilityRaw
        )
        return [primary] + alternateLocations
    }

    var allSourceMemberships: [ReferencedSourceMembership] {
        var result = sourceMemberships
        for location in alternateLocations {
            result.append(contentsOf: location.sourceMemberships)
        }
        return Self.uniqueMemberships(result)
    }

    func containsSource(_ sourceID: UUID) -> Bool {
        allSourceMemberships.contains { $0.sourceID == sourceID }
    }

    /// Refreshes the physical location that owns a source membership. A
    /// duplicated track may keep the source on an alternate location; source
    /// reconciliation must update that location in place instead of silently
    /// overwriting the preferred copy and losing the fallback.
    mutating func refreshLocation(
        for sourceID: UUID,
        fileBookmarkData: Data,
        lastKnownPath: String,
        fingerprint: ReferencedFileFingerprint?
    ) {
        if sourceMemberships.contains(where: { $0.sourceID == sourceID }) {
            self.fileBookmarkData = fileBookmarkData
            self.lastKnownPath = lastKnownPath
            if let fingerprint { self.fingerprint = fingerprint }
            return
        }
        if let index = alternateLocations.firstIndex(where: {
            $0.sourceMemberships.contains { $0.sourceID == sourceID }
        }) {
            alternateLocations[index].fileBookmarkData = fileBookmarkData
            alternateLocations[index].lastKnownPath = lastKnownPath
            if let fingerprint { alternateLocations[index].fingerprint = fingerprint }
            return
        }
        self.fileBookmarkData = fileBookmarkData
        self.lastKnownPath = lastKnownPath
        if let fingerprint { self.fingerprint = fingerprint }
    }

    /// Reassigns a source membership while retaining the location that
    /// previously owned it. This is the source-aware counterpart to changing
    /// a legacy primary membership and keeps multi-location fallback intact.
    mutating func setSourceMembership(_ membership: ReferencedSourceMembership) {
        let preferredAlternateIndex = alternateLocations.firstIndex(where: {
            $0.sourceMemberships.contains { $0.sourceID == membership.sourceID }
        })
        let wasPrimary = sourceMemberships.contains { $0.sourceID == membership.sourceID }
        sourceMemberships.removeAll { $0.sourceID == membership.sourceID }
        for index in alternateLocations.indices {
            alternateLocations[index].sourceMemberships.removeAll {
                $0.sourceID == membership.sourceID
            }
        }
        if wasPrimary || preferredAlternateIndex == nil {
            sourceMemberships.append(membership)
        } else if let preferredAlternateIndex {
            alternateLocations[preferredAlternateIndex].sourceMemberships.append(membership)
        }
        sourceMemberships = Self.uniqueMemberships(sourceMemberships)
        alternateLocations = alternateLocations.map { location in
            var location = location
            location.sourceMemberships = Self.uniqueMemberships(location.sourceMemberships)
            return location
        }
    }

    /// Replaces the source projection for the preferred physical location
    /// while preserving unrelated alternate locations. NCM recovery records
    /// describe the generated output location and use this to repair legacy
    /// source memberships without flattening duplicate-file fallbacks.
    mutating func replacePrimarySourceMemberships(_ memberships: [ReferencedSourceMembership]) {
        let sourceIDs = Set(memberships.map(\.sourceID))
        sourceMemberships.removeAll { sourceIDs.contains($0.sourceID) }
        for index in alternateLocations.indices {
            alternateLocations[index].sourceMemberships.removeAll {
                sourceIDs.contains($0.sourceID)
            }
        }
        sourceMemberships = Self.uniqueMemberships(sourceMemberships + memberships)
    }

    mutating func removeSource(_ sourceID: UUID) {
        removeSource(sourceID, preservingRecovery: false)
    }

    /// Removes an authority edge while retaining the last physical locator.
    ///
    /// A missing or excluded source still needs a valid sidecar so the track
    /// can remain in the library and recover when the source is re-enabled.
    /// This is deliberately separate from full source removal, where an
    /// orphaned track may be deleted and should not retain an anonymous
    /// playback candidate.
    mutating func removeSourcePreservingRecovery(_ sourceID: UUID) {
        removeSource(sourceID, preservingRecovery: true)
    }

    private mutating func removeSource(_ sourceID: UUID, preservingRecovery: Bool) {
        let primaryHadSource = sourceMemberships.contains { $0.sourceID == sourceID }
        sourceMemberships.removeAll { $0.sourceID == sourceID }
        alternateLocations = alternateLocations.compactMap { location in
            var location = location
            let locationHadSource = location.sourceMemberships.contains { $0.sourceID == sourceID }
            location.sourceMemberships.removeAll { $0.sourceID == sourceID }
            // A location that was owned by a removed source must not remain as
            // an anonymous bookmark candidate. Preserve only a pre-existing
            // bookmark-only fallback, which has no source ownership to remove.
            return location.sourceMemberships.isEmpty && locationHadSource ? nil : location
        }
        if !preservingRecovery && primaryHadSource && sourceMemberships.isEmpty {
            fileBookmarkData = Data()
            lastKnownPath = ""
            fingerprint = nil
            ncmSourceIdentity = nil
            primaryAudioProperties = nil
            primaryContentDigest = nil
            primaryAvailabilityRaw = nil
        }
        if primarySourceID == sourceID {
            primarySourceID = sourceMemberships.first?.sourceID
        }
    }

    /// Removes one source projection without discarding other files from the
    /// same source. This is needed when an older scan recorded an app-generated
    /// NCM output as a source entry and a later scan correctly hides that
    /// output while retaining the original `.ncm` membership.
    mutating func removeSourceMembership(sourceID: UUID, relativePath: String) {
        let primaryHadMembership = sourceMemberships.contains {
            $0.sourceID == sourceID && $0.relativePath == relativePath
        }
        sourceMemberships.removeAll {
            $0.sourceID == sourceID && $0.relativePath == relativePath
        }
        alternateLocations = alternateLocations.compactMap { location in
            var location = location
            let hadMembership = location.sourceMemberships.contains {
                $0.sourceID == sourceID && $0.relativePath == relativePath
            }
            location.sourceMemberships.removeAll {
                $0.sourceID == sourceID && $0.relativePath == relativePath
            }
            return hadMembership && location.sourceMemberships.isEmpty ? nil : location
        }
        if primaryHadMembership && sourceMemberships.isEmpty {
            fileBookmarkData = Data()
            lastKnownPath = ""
            fingerprint = nil
            ncmSourceIdentity = nil
            primaryAudioProperties = nil
            primaryContentDigest = nil
            primaryAvailabilityRaw = nil
        }
        if primarySourceID == sourceID,
           !sourceMemberships.contains(where: { $0.sourceID == sourceID }) {
            primarySourceID = sourceMemberships.first?.sourceID
                ?? alternateLocations.flatMap(\.sourceMemberships).first?.sourceID
        }
    }

    mutating func mergeLocation(_ incoming: ReferencedTrackLocation) {
        let incomingKey = Self.locationKey(incoming)
        if incomingKey == Self.locationKey(locations[0]) {
            sourceMemberships = Self.uniqueMemberships(sourceMemberships + incoming.sourceMemberships)
            if fileBookmarkData.isEmpty { fileBookmarkData = incoming.fileBookmarkData }
            if lastKnownPath.isEmpty { lastKnownPath = incoming.lastKnownPath }
            fingerprint = incoming.fingerprint ?? fingerprint
            ncmSourceIdentity = incoming.ncmSourceIdentity ?? ncmSourceIdentity
            primaryAudioProperties = incoming.audioProperties ?? primaryAudioProperties
            primaryContentDigest = incoming.contentDigest ?? primaryContentDigest
            primaryAvailabilityRaw = incoming.availabilityRaw ?? primaryAvailabilityRaw
            primarySourceID = primarySourceID ?? sourceMemberships.first?.sourceID
            return
        }
        if let index = alternateLocations.firstIndex(where: { Self.locationKey($0) == incomingKey }) {
            var existing = alternateLocations[index]
            existing.sourceMemberships = Self.uniqueMemberships(existing.sourceMemberships + incoming.sourceMemberships)
            if existing.fileBookmarkData.isEmpty { existing.fileBookmarkData = incoming.fileBookmarkData }
            if existing.lastKnownPath.isEmpty { existing.lastKnownPath = incoming.lastKnownPath }
            existing.fingerprint = incoming.fingerprint ?? existing.fingerprint
            existing.ncmSourceIdentity = incoming.ncmSourceIdentity ?? existing.ncmSourceIdentity
            alternateLocations[index] = existing
        } else {
            alternateLocations.append(incoming)
        }
    }

    /// Persists an on-demand content digest onto the location with the given
    /// id. Returns false when no location carries that id.
    mutating func setContentDigest(_ digest: String, atLocationID locationID: UUID) -> Bool {
        if locationID == primaryLocationID {
            primaryContentDigest = digest
            return true
        }
        if let index = alternateLocations.firstIndex(where: { $0.id == locationID }) {
            alternateLocations[index].contentDigest = digest
            return true
        }
        return false
    }

    private static func uniqueMemberships(_ memberships: [ReferencedSourceMembership]) -> [ReferencedSourceMembership] {
        Array(Set(memberships)).sorted {
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            if $0.sourceID != $1.sourceID { return $0.sourceID.uuidString < $1.sourceID.uuidString }
            return $0.relativePath < $1.relativePath
        }
    }

    private static func locationKey(_ location: ReferencedTrackLocation) -> String {
        if let identity = location.fingerprint?.identity {
            let volume = identity.volumeUUID ?? ""
            let resource = identity.resourceIdentifierArchive?.base64EncodedString() ?? ""
            if !volume.isEmpty || !resource.isEmpty { return "identity:\(volume):\(resource)" }
        }
        return "path:\(location.lastKnownPath)"
    }
}
