//
//  ImportPlacement.swift
//  kmgccc_player
//

import Foundation

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
