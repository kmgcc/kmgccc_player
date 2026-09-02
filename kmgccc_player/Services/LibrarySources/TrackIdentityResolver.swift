//
//  TrackIdentityResolver.swift
//  kmgccc_player
//

import CryptoKit
import Foundation

// MARK: - Resolution vocabulary (plan §11 / §16)

/// Ordered same-track evidence tiers. A lower raw value is stronger evidence;
/// the metadata-similarity tier deliberately has no case here because it can
/// only ever produce a "possible duplicate" suggestion, never a match.
nonisolated enum TrackMatchTier: Int, Sendable, Comparable {
    /// Managed mode: the original file still sits at its recorded canonical path.
    case canonicalPath = 0
    case stableIdentity = 1
    case ncmAssociation = 2
    case savedFingerprint = 3
    case contentDigest = 4

    static func < (lhs: TrackMatchTier, rhs: TrackMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct TrackMetadataSimilarity: Sendable, Equatable {
    let dedupKey: String
    let durationDeltaSeconds: Double
}

nonisolated enum IdentityResolution: Equatable, Sendable {
    case matched(trackID: UUID, tier: TrackMatchTier)
    case possibleDuplicate(existingTrackID: UUID, similarity: TrackMetadataSimilarity)
    case unmatched
}

// MARK: - Candidate inputs

nonisolated struct ReferencedLocationSnapshot: Sendable, Equatable {
    let id: UUID
    let fingerprint: ReferencedFileFingerprint?
    let ncmSourceIdentity: ReferencedFileIdentity?
    let contentDigest: String?
    let lastKnownPath: String
}

nonisolated struct ReferencedTrackCandidate: Sendable, Equatable {
    let trackID: UUID
    let locations: [ReferencedLocationSnapshot]
}

nonisolated struct ManagedTrackCandidate: Sendable, Equatable {
    let trackID: UUID
    /// Raw `originalFilePath` as stored; canonicalized by the resolver.
    let originalFilePath: String
    let provenance: ImportProvenance?
    /// Absolute URL of the managed audio copy, used only for on-demand digest
    /// computation when no stored digest exists yet.
    let managedAudioURL: URL?
}

nonisolated struct SimilarityCandidate: Sendable, Equatable {
    let trackID: UUID
    let duration: Double
}

nonisolated enum SimilarityClassification: Equatable, Sendable {
    case none
    case possibleDuplicate(existingTrackIDs: [UUID])
}

// MARK: - Digest hashing

nonisolated protocol ContentDigestHashing: Sendable {
    func hexContentDigest(of url: URL) async throws -> String
}

/// Streaming SHA-256 over fixed-size chunks so large audio files never load
/// fully into memory and cancellation is checked between chunks.
nonisolated struct SHA256ContentDigestHasher: ContentDigestHashing {
    static let chunkSize = 1 << 20

    init() {}

    func hexContentDigest(of url: URL) async throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-import-session memo. The laziness contract is "at most one hash per
/// file per session": once a digest tier actually runs for a file, repeated
/// comparisons reuse the memo instead of re-reading the bytes.
actor SessionDigestMemo {
    private var digestsByPath: [String: String] = [:]

    func digest(for url: URL, hasher: ContentDigestHashing) async throws -> String {
        let key = Self.cacheKey(for: url)
        if let cached = digestsByPath[key] { return cached }
        let value = try await hasher.hexContentDigest(of: url)
        digestsByPath[key] = value
        return value
    }

    private nonisolated static func cacheKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// MARK: - Resolver

/// Single owner of same-track identity decisions across managed, referenced,
/// NCM, file-move, duplicate-location and content-digest rules (plan §16).
/// UI and scanner must not implement a second dedup scheme; they call this
/// type instead. Tier order follows plan §11: filesystem identity, known NCM
/// association, saved fingerprint, content digest when needed, and metadata
/// similarity which only ever suggests a possible duplicate.
nonisolated struct TrackIdentityResolver: Sendable {
    private let hasher: ContentDigestHashing
    private let memo: SessionDigestMemo

    init(hasher: ContentDigestHashing = SHA256ContentDigestHasher()) {
        self.hasher = hasher
        self.memo = SessionDigestMemo()
    }

    // MARK: Fingerprint predicates

    /// Strict "same file state" equality shared by the NCM conversion registry
    /// and the generated-output marker store. Stable identities must match
    /// exactly including size and modification time — a touched-in-place NCM
    /// must not silently reuse an old conversion product. Unstable identities
    /// fall back to size + modification time.
    nonisolated static func sameExactFingerprint(
        _ lhs: ReferencedFileFingerprint,
        _ rhs: ReferencedFileFingerprint
    ) -> Bool {
        let leftStable = lhs.identity.flatMap(stableIdentity)
        let rightStable = rhs.identity.flatMap(stableIdentity)
        switch (leftStable, rightStable) {
        case let (.some(left), .some(right)):
            return left == right
                && lhs.fileSize == rhs.fileSize
                && lhs.modifiedAt == rhs.modifiedAt
        case (.some, .none), (.none, .some):
            return false
        case (.none, .none):
            return lhs.fileSize == rhs.fileSize && lhs.modifiedAt == rhs.modifiedAt
        }
    }

    /// Physical-identity equality: stable volume+resource identity when both
    /// sides have one (ignoring size/mtime, since a touched file is still the
    /// same physical file), otherwise size + rounded modification time.
    nonisolated static func samePhysicalIdentity(
        _ lhs: ReferencedFileFingerprint,
        _ rhs: ReferencedFileFingerprint
    ) -> Bool {
        ReferencedPhysicalIdentityKey(lhs) == ReferencedPhysicalIdentityKey(rhs)
    }

    nonisolated private static func stableIdentity(
        _ identity: ReferencedFileIdentity
    ) -> ReferencedFileIdentity? {
        guard identity.volumeUUID?.isEmpty == false,
              identity.resourceIdentifierArchive?.isEmpty == false else { return nil }
        return identity
    }

    // MARK: Canonical path (managed identity tier)

    nonisolated static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Metadata similarity — suggestions only, never merges

    static let duplicateDurationTolerance: Double = 0.5

    /// Title/artist select the candidate group (callers pass the group's
    /// members); duration confirms it is plausibly the same recording. A
    /// half-second tolerance absorbs container metadata rounding without
    /// treating two different songs with the same tags as duplicates. Unknown
    /// durations never match. By construction this can only classify, never
    /// merge: the outcome is a suggestion list, not a track identity.
    nonisolated static func durationsWithinDuplicateTolerance(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        guard lhs.isFinite, rhs.isFinite, lhs > 0, rhs > 0 else { return false }
        return abs(lhs - rhs) <= duplicateDurationTolerance
    }

    nonisolated static func classifyMetadataSimilarity(
        dedupKey: String,
        incomingDuration: Double,
        candidates: [SimilarityCandidate]
    ) -> SimilarityClassification {
        let matching = candidates.filter {
            durationsWithinDuplicateTolerance(incomingDuration, $0.duration)
        }
        guard !matching.isEmpty else { return .none }
        return .possibleDuplicate(existingTrackIDs: matching.map(\.trackID))
    }

    // MARK: Referenced-mode resolution

    nonisolated struct ReferencedResolutionResult: Sendable, Equatable {
        let resolution: IdentityResolution
        /// Digest of the incoming file, present only when the digest tier ran.
        let incomingDigest: String?
        /// Digests computed on demand while reaching the verdict, keyed by the
        /// location id they describe. Callers persist them so later imports
        /// hit the stored-digest fast path instead of re-hashing.
        let computedDigests: [UUID: String]
        /// Distinct candidate tracks that all matched the digest tier. Non-empty
        /// only for ambiguous verdicts, which resolve to `.unmatched`.
        let ambiguousTrackIDs: [UUID]

        static func unmatched() -> Self {
            Self(resolution: .unmatched, incomingDigest: nil, computedDigests: [:], ambiguousTrackIDs: [])
        }
    }

    /// Resolves an incoming referenced file against existing tracks in §11
    /// order. Tiers 1–3 never touch the filesystem beyond what the caller
    /// already scanned; hashing happens only inside the digest tier and only
    /// after an exact size pre-filter.
    func resolveReferencedMatch(
        incomingFingerprint: ReferencedFileFingerprint,
        incomingURL: URL,
        candidates: [ReferencedTrackCandidate]
    ) async -> ReferencedResolutionResult {
        let incomingStable = Self.stableIdentity(from: incomingFingerprint)

        // Tier: filesystem stable identity.
        if let incomingStable {
            for candidate in candidates {
                if candidate.locations.contains(where: { location in
                    location.fingerprint.flatMap(Self.stableIdentity(from:)) == incomingStable
                }) {
                    return .init(
                        resolution: .matched(trackID: candidate.trackID, tier: .stableIdentity),
                        incomingDigest: nil,
                        computedDigests: [:],
                        ambiguousTrackIDs: []
                    )
                }
            }
        }

        // Tier: known NCM source/output association.
        if let incomingStable {
            for candidate in candidates {
                if candidate.locations.contains(where: {
                    $0.ncmSourceIdentity == incomingStable
                }) {
                    return .init(
                        resolution: .matched(trackID: candidate.trackID, tier: .ncmAssociation),
                        incomingDigest: nil,
                        computedDigests: [:],
                        ambiguousTrackIDs: []
                    )
                }
            }
        }

        // Tier: saved physical fingerprint (stable-or-fallback key equality).
        for candidate in candidates {
            if candidate.locations.contains(where: { location in
                guard let existing = location.fingerprint else { return false }
                return Self.samePhysicalIdentity(existing, incomingFingerprint)
            }) {
                return .init(
                    resolution: .matched(trackID: candidate.trackID, tier: .savedFingerprint),
                    incomingDigest: nil,
                    computedDigests: [:],
                    ambiguousTrackIDs: []
                )
            }
        }

        // Tier: content digest when needed. Only reached after every cheaper
        // tier missed; candidates are pre-filtered by exact byte size before
        // any hashing so a full-library sweep can never happen implicitly.
        return await resolveReferencedDigestMatch(
            incomingFingerprint: incomingFingerprint,
            incomingURL: incomingURL,
            candidates: candidates
        )
    }

    private func resolveReferencedDigestMatch(
        incomingFingerprint: ReferencedFileFingerprint,
        incomingURL: URL,
        candidates: [ReferencedTrackCandidate]
    ) async -> ReferencedResolutionResult {
        let sizedCandidates = candidates.compactMap { candidate -> (candidate: ReferencedTrackCandidate, locations: [ReferencedLocationSnapshot])? in
            let matchingSizeLocations = candidate.locations.filter { location in
                location.fingerprint?.fileSize == incomingFingerprint.fileSize
            }
            guard !matchingSizeLocations.isEmpty else { return nil }
            return (candidate, matchingSizeLocations)
        }
        guard !sizedCandidates.isEmpty else { return .unmatched() }

        let incomingDigest: String
        do {
            incomingDigest = try await memo.digest(for: incomingURL, hasher: hasher)
        } catch is CancellationError {
            return .unmatched()
        } catch {
            return .unmatched()
        }

        var computedDigests: [UUID: String] = [:]
        var matchedTrackIDs: [UUID] = []
        for sized in sizedCandidates {
            for location in sized.locations {
                if location.contentDigest == incomingDigest {
                    if matchedTrackIDs.last != sized.candidate.trackID {
                        matchedTrackIDs.append(sized.candidate.trackID)
                    }
                    continue
                }
                guard location.contentDigest == nil else { continue }
                guard !location.lastKnownPath.isEmpty else { continue }
                do {
                    let digest = try await memo.digest(
                        for: URL(fileURLWithPath: location.lastKnownPath),
                        hasher: hasher
                    )
                    computedDigests[location.id] = digest
                    if digest == incomingDigest,
                       matchedTrackIDs.last != sized.candidate.trackID {
                        matchedTrackIDs.append(sized.candidate.trackID)
                    }
                } catch is CancellationError {
                    continue
                } catch {
                    continue
                }
            }
        }

        let uniqueMatchedTrackIDs = Array(Set(matchedTrackIDs)).sorted { $0.uuidString < $1.uuidString }
        if uniqueMatchedTrackIDs.count == 1 {
            return .init(
                resolution: .matched(trackID: uniqueMatchedTrackIDs[0], tier: .contentDigest),
                incomingDigest: incomingDigest,
                computedDigests: computedDigests,
                ambiguousTrackIDs: []
            )
        }
        return .init(
            resolution: .unmatched,
            incomingDigest: incomingDigest,
            computedDigests: computedDigests,
            ambiguousTrackIDs: uniqueMatchedTrackIDs
        )
    }

    // MARK: Managed-mode resolution

    nonisolated struct ManagedResolutionResult: Sendable, Equatable {
        let resolution: IdentityResolution
        /// Digest of the incoming file, present only when the digest tier ran.
        let incomingDigest: String?
        /// Digests computed on demand while reaching the verdict, keyed by
        /// track id (a managed track's digest describes its single audio copy).
        let computedDigests: [UUID: String]
        /// Distinct candidate tracks that all matched the digest tier. Non-empty
        /// only for ambiguous verdicts, which resolve to `.unmatched`.
        let ambiguousTrackIDs: [UUID]

        static func unmatched() -> Self {
            Self(resolution: .unmatched, incomingDigest: nil, computedDigests: [:], ambiguousTrackIDs: [])
        }
    }

    /// Managed dedup order: canonical-path hit → provenance fingerprint hit →
    /// provenance digest (on demand, only when sizes match) → new track.
    func resolveManagedMatch(
        incomingCanonicalPath: String,
        incomingFingerprint: ReferencedFileFingerprint?,
        incomingURL: URL,
        candidates: [ManagedTrackCandidate]
    ) async -> ManagedResolutionResult {
        // Tier: unchanged canonical original path. First match wins, mirroring
        // the historical dictionary behaviour of the managed import branch.
        if !incomingCanonicalPath.isEmpty {
            for candidate in candidates where !candidate.originalFilePath.isEmpty {
                if Self.canonicalPath(candidate.originalFilePath) == incomingCanonicalPath {
                    return .init(
                        resolution: .matched(trackID: candidate.trackID, tier: .canonicalPath),
                        incomingDigest: nil,
                        computedDigests: [:],
                        ambiguousTrackIDs: []
                    )
                }
            }
        }

        // Tier: saved provenance fingerprint captured at import commit time.
        if let incomingFingerprint {
            let fingerprintMatches = candidates.filter { candidate in
                guard let original = candidate.provenance?.originalFingerprint else { return false }
                return Self.sameExactFingerprint(original, incomingFingerprint)
            }
            if let only = fingerprintMatches.first, fingerprintMatches.count == 1 {
                return .init(
                    resolution: .matched(trackID: only.trackID, tier: .savedFingerprint),
                    incomingDigest: nil,
                    computedDigests: [:],
                    ambiguousTrackIDs: []
                )
            }
            if fingerprintMatches.count > 1 {
                return .init(
                    resolution: .unmatched,
                    incomingDigest: nil,
                    computedDigests: [:],
                    ambiguousTrackIDs: fingerprintMatches.map(\.trackID)
                )
            }
        }

        // Tier: provenance content digest, computed on demand and only when
        // the stored import-time size matches the incoming size exactly.
        guard let incomingFingerprint else { return .unmatched() }
        let sizedCandidates = candidates.filter { candidate in
            candidate.provenance?.originalFingerprint?.fileSize == incomingFingerprint.fileSize
        }
        guard !sizedCandidates.isEmpty else { return .unmatched() }

        let incomingDigest: String
        do {
            incomingDigest = try await memo.digest(for: incomingURL, hasher: hasher)
        } catch {
            return .unmatched()
        }

        var computedDigests: [UUID: String] = [:]
        var matchedTrackIDs: [UUID] = []
        for candidate in sizedCandidates {
            if candidate.provenance?.contentDigest == incomingDigest {
                matchedTrackIDs.append(candidate.trackID)
                continue
            }
            guard candidate.provenance?.contentDigest == nil,
                  let audioURL = candidate.managedAudioURL else { continue }
            do {
                let digest = try await memo.digest(for: audioURL, hasher: hasher)
                computedDigests[candidate.trackID] = digest
                if digest == incomingDigest {
                    matchedTrackIDs.append(candidate.trackID)
                }
            } catch {
                continue
            }
        }

        let uniqueMatchedTrackIDs = Array(Set(matchedTrackIDs)).sorted { $0.uuidString < $1.uuidString }
        if uniqueMatchedTrackIDs.count == 1 {
            return .init(
                resolution: .matched(trackID: uniqueMatchedTrackIDs[0], tier: .contentDigest),
                incomingDigest: incomingDigest,
                computedDigests: computedDigests,
                ambiguousTrackIDs: []
            )
        }
        return .init(
            resolution: .unmatched,
            incomingDigest: incomingDigest,
            computedDigests: computedDigests,
            ambiguousTrackIDs: uniqueMatchedTrackIDs
        )
    }

    nonisolated private static func stableIdentity(
        from fingerprint: ReferencedFileFingerprint
    ) -> ReferencedFileIdentity? {
        fingerprint.identity.flatMap { identity in
            guard identity.volumeUUID?.isEmpty == false,
                  identity.resourceIdentifierArchive?.isEmpty == false else { return nil }
            return identity
        }
    }
}
