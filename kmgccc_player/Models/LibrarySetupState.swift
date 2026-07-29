import Foundation

nonisolated enum SourceReconnectMatchBasis: String, Sendable, Equatable {
    case relativePath
    case physicalIdentity
    case fingerprint
}

nonisolated struct SourceReconnectExpectedFile: Sendable, Equatable {
    let trackID: UUID
    let relativePath: String
    let fingerprint: ReferencedFileFingerprint?
    let duration: Double
}

nonisolated struct SourceReconnectCandidateFile: Sendable, Equatable, Identifiable {
    var id: String { url.standardizedFileURL.path }

    let rootURL: URL
    let url: URL
    let relativePath: String
    let fingerprint: ReferencedFileFingerprint
    let duration: Double
}

nonisolated struct SourceReconnectMatch: Sendable, Equatable {
    let trackID: UUID
    let previousRelativePath: String
    let candidate: SourceReconnectCandidateFile
    let basis: SourceReconnectMatchBasis
}

nonisolated struct SourceReconnectConflict: Sendable, Equatable, Identifiable {
    var id: UUID { expected.trackID }

    let expected: SourceReconnectExpectedFile
    let candidates: [SourceReconnectCandidateFile]
}

nonisolated struct SourceReconnectPlan: Sendable, Equatable, Identifiable {
    var id: String { rootURL.standardizedFileURL.path }

    let rootURL: URL
    let candidates: [SourceReconnectCandidateFile]
    let matches: [SourceReconnectMatch]
    let conflicts: [SourceReconnectConflict]
    let unmatchedTrackIDs: [UUID]

    var recoveredCount: Int { matches.count }
    var unresolvedCount: Int { conflicts.count + unmatchedTrackIDs.count }
}

nonisolated struct SourceReconnectPreparation: Sendable, Equatable {
    let sourceID: UUID
    let sourceDisplayName: String
    let plans: [SourceReconnectPlan]
}

nonisolated struct TrackRelocationProposal: Sendable, Equatable {
    let trackID: UUID
    let selectedURL: URL
    let fingerprint: ReferencedFileFingerprint
    let duration: Double
    let identityMatches: Bool

    var requiresReplacementConfirmation: Bool { !identityMatches }
}

