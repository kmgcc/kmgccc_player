//
//  LibraryBackend.swift
//  kmgccc_player
//

import Foundation

nonisolated enum LibraryBackendError: Error, Equatable, LocalizedError {
    case modeMismatch(expected: MusicLibraryMode, actual: LocalTrackStorageKind)
    case unsupportedReferencedNCM
    case bookmarkCreationFailed
    case sourceOutsideAuthorization

    var errorDescription: String? {
        switch self {
        case .modeMismatch(let expected, let actual):
            return "Import placement \(actual.rawValue) is not valid for a \(expected.rawValue) library."
        case .unsupportedReferencedNCM:
            return "Referenced NCM conversion is not available yet."
        case .bookmarkCreationFailed:
            return "The selected file permission could not be saved."
        case .sourceOutsideAuthorization:
            return "The selected file resolves outside its authorized source."
        }
    }
}

@MainActor
protocol LibraryStorageBackend: AnyObject {
    var mode: MusicLibraryMode { get }
    var lastPreparedInputPlan: ImportInputPlan? { get }
    func prepareInputs(_ selectedURLs: [URL]) async -> ImportInputPlan
    func makePlacement(
        for file: ImportDiscoveredFile,
        trackID: UUID,
        stagingDirectoryURL: URL
    ) async throws -> ImportPlacement
    func validate(_ placement: ImportPlacement) throws
    func finishImportBatch()
    func close() async
}

@MainActor
enum LibraryStorageBackendFactory {
    static func make(
        context: LibraryContext,
        sourceStore: ReferencedSourceStore? = nil,
        sourceScope: ReferencedSourceScope? = nil,
        requiresSecurityScope: Bool = false
    ) throws -> any LibraryStorageBackend {
        switch context.mode {
        case .managed:
            return ManagedLocalBackend(paths: context.paths)
        case .referenced:
            guard let sourceStore, let sourceScope else {
                throw LibrarySessionFactoryError.missingReferencedSourceServices
            }
            return ReferencedLocalBackend(
                paths: context.paths,
                sourceStore: sourceStore,
                sourceScope: sourceScope,
                requiresSecurityScope: requiresSecurityScope
            )
        }
    }
}
