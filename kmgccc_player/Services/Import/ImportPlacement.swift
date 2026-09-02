//
//  ImportPlacement.swift
//  kmgccc_player
//

import Foundation

nonisolated enum LibraryImportDestination: Sendable, Equatable {
    case libraryOnly
    case playlist(UUID)
}

nonisolated enum LibraryImportOrigin: String, Sendable, Equatable {
    case toolbar
    case menu
    case windowDrop
    case playlistDrop
    case setup
    case sourceMonitor
}

/// Immutable context captured at the instant an import starts. The target is
/// never recomputed after the picker returns, so navigating to another page or
/// playlist cannot redirect a pending import.
nonisolated struct LibraryImportContext: Sendable, Equatable {
    let libraryID: UUID
    let sessionGeneration: UInt64
    let destination: LibraryImportDestination
    let metadataOverride: ImportMetadataOverride?
    let origin: LibraryImportOrigin

    init(
        libraryID: UUID,
        sessionGeneration: UInt64,
        destination: LibraryImportDestination,
        metadataOverride: ImportMetadataOverride? = nil,
        origin: LibraryImportOrigin
    ) {
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.destination = destination
        self.metadataOverride = metadataOverride
        self.origin = origin
    }
}

nonisolated struct LibraryImportResult: Sendable, Equatable {
    let importedTrackCount: Int
    let reusedTrackCount: Int
    let playlistMembershipAdditions: Int
    let sourceBindingCount: Int
    let failures: [ImportInputFailure]
    let wasRejectedAsStale: Bool
    /// Similarity-only duplicate suggestions encountered during this import.
    /// Interactive imports resolve them by storage mode: referenced libraries
    /// link the existing Track, while managed libraries copy the incoming file.
    /// Automatic source scans keep the conservative "import as new" policy.
    var possibleDuplicatesCount: Int = 0
    /// NCM files queued for conversion during this import.
    var pendingNCMCount: Int = 0
    /// Processed tracks that were already members of the destination playlist
    /// before this import started.
    var alreadyInPlaylistCount: Int = 0

    static let staleContext = LibraryImportResult(
        importedTrackCount: 0,
        reusedTrackCount: 0,
        playlistMembershipAdditions: 0,
        sourceBindingCount: 0,
        failures: [],
        wasRejectedAsStale: true
    )

    var affectedTrackCount: Int { importedTrackCount + reusedTrackCount }
}

nonisolated enum ImportPlacement: Sendable, Equatable {
    case managed(stagedAudioURL: URL, libraryRelativePath: String)
    case referenced(ReferencedFileLocator)

    var storageKind: LocalTrackStorageKind {
        switch self {
        case .managed: return .managed
        case .referenced: return .referenced
        }
    }
}

nonisolated struct ImportDiscoveredFile: Sendable, Equatable {
    let url: URL
    let memberships: [ReferencedSourceMembership]
    let primarySourceID: UUID?
    let fingerprint: ReferencedFileFingerprint?
}

nonisolated struct ImportSourceSelection: Sendable, Equatable {
    let source: ReferencedSourceDescriptor
    let rootURL: URL
}

nonisolated struct ImportInputPlan: Sendable {
    let files: [ImportDiscoveredFile]
    let directorySources: [ImportSourceSelection]
    let failures: [ImportInputFailure]
}

nonisolated struct ImportInputFailure: Sendable, Equatable {
    let url: URL
    let message: String
}

/// A compact, user-visible record of one import attempt.  The import dialog is
/// transient, so the report lives in UI state until the user dismisses it and
/// can still inspect a source-monitor failure after the background scan ends.
nonisolated struct LibraryImportFailureReport: Identifiable, Sendable, Equatable {
    let id: UUID
    let origin: LibraryImportOrigin
    let createdAt: Date
    let failures: [ImportInputFailure]

    init(
        id: UUID = UUID(),
        origin: LibraryImportOrigin,
        failures: [ImportInputFailure],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.origin = origin
        self.createdAt = createdAt
        var seenFailures = Set<String>()
        self.failures = failures.filter { failure in
            let key = "\(LibraryImportSourceEntry.canonicalPath(failure.url))|\(failure.message)"
            return seenFailures.insert(key).inserted
        }
    }
}
