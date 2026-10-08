import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
enum AutomationFileAccess {

    static func automationTrackFileURLs(_ track: Track, in session: LibrarySession) -> [URL] {
        if track.mediaLocator.managedLibraryRelativePath != nil {
            return automationTrackFileURL(track, in: session).map { [$0] } ?? []
        }
        let recordedPaths = (track.mediaLocator.referencedFile?.locations.map(\.lastKnownPath) ?? [])
            + [track.originalFilePath]
        var seen = Set<String>()
        return recordedPaths.compactMap { path in
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    static func automationTrackFileURL(_ track: Track, in session: LibrarySession) -> URL? {
        if let relativePath = track.mediaLocator.managedLibraryRelativePath,
           TrackMediaLocator.isSafeRelativePath(relativePath) {
            let root = session.context.rootURL.standardizedFileURL
            let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/") else { return nil }
            return candidate
        }
        let path = track.mediaLocator.referencedFile?.locations.first?.lastKnownPath ?? track.originalFilePath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func embeddedAudioFileURL(for track: Track, session: LibrarySession) throws -> URL {
        if case .referenced = track.mediaLocator {
            return try currentAuthorizedFile(for: track, session: session).url
        }
        guard let url = automationTrackFileURL(track, in: session),
              FileManager.default.fileExists(atPath: url.path) else {
            throw AutomationParameterError.invalidValue("audio file unavailable")
        }
        return url
    }

    static func trackPath(_ track: Track) -> String {
        track.mediaLocator.referencedFile?.locations.first?.lastKnownPath
            ?? track.originalFilePath
    }

    static func makeFileSummary(
        _ track: Track,
        pathOverride: String? = nil,
        existsOverride: Bool? = nil
    ) -> AutomationFileSummary {
        let locator = track.mediaLocator.referencedFile
        let memberships = locator?.allSourceMemberships ?? []
        let path = pathOverride ?? trackPath(track)
        return AutomationFileSummary(
            trackID: track.id,
            path: path,
            exists: existsOverride ?? FileManager.default.fileExists(atPath: path),
            availability: track.availability.rawValue,
            sourceIDs: memberships.map(\.sourceID),
            relativePaths: memberships.map(\.relativePath)
        )
    }

    static func currentAuthorizedFile(
        for track: Track,
        session: LibrarySession
    ) throws -> (url: URL, sourceIDs: Set<UUID>) {
        guard case let .referenced(locator) = track.mediaLocator else {
            throw AutomationFileOperationError.referencedFileRequired(track.id)
        }
        guard let sourceScope = session.referencedSourceScope else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let sourceIDs = Set(locator.allSourceMemberships.map(\.sourceID))
        for location in locator.locations {
            for membership in location.sourceMemberships {
                guard let authorizedRoot = sourceScope.authorizedRoots[membership.sourceID],
                      isDirectoryRoot(authorizedRoot.url),
                      TrackMediaLocator.isSafeRelativePath(membership.relativePath) else {
                    continue
                }
                let candidate = authorizedRoot.url
                    .appendingPathComponent(membership.relativePath)
                    .standardizedFileURL
                guard isAuthorizedPath(candidate, inside: authorizedRoot.url),
                      FileManager.default.fileExists(atPath: candidate.path),
                      !isDirectoryRoot(candidate) else {
                    continue
                }
                return (candidate, sourceIDs)
            }
        }
        if sourceIDs.isEmpty {
            throw AutomationFileOperationError.noSourceMembership(track.id)
        }
        throw AutomationFileOperationError.fileUnavailable(track.id)
    }

    static func authorizedDirectoryRoot(
        sourceID: UUID,
        sourceScope: ReferencedSourceScope
    ) throws -> URL {
        guard let root = sourceScope.authorizedRoots[sourceID]?.url else {
            throw AutomationFileOperationError.sourceNotAuthorized(sourceID)
        }
        guard isDirectoryRoot(root) else {
            throw AutomationFileOperationError.sourceMustBeDirectory(sourceID)
        }
        return root.standardizedFileURL
    }

    static func isDirectoryRoot(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if let isDirectory = values?.isDirectory {
            return isDirectory
        }
        return url.hasDirectoryPath
    }

    static func isAuthorizedPath(_ candidate: URL, inside root: URL) -> Bool {
        let standardizedCandidate = candidate.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard standardizedCandidate.path == standardizedRoot.path
            || standardizedCandidate.path.hasPrefix(standardizedRoot.path + "/") else {
            return false
        }

        // The lexical check above blocks traversal. Resolve the nearest
        // existing ancestor as well so a symlinked directory cannot redirect
        // a newly-created destination outside the authorized Source.
        var existingAncestor = standardizedCandidate
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != existingAncestor.deletingLastPathComponent().path {
            existingAncestor.deleteLastPathComponent()
        }
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL.path
        return canonicalAncestor == canonicalRoot
            || canonicalAncestor.hasPrefix(canonicalRoot + "/")
    }

    static func automationTracks(ids: [UUID], in allTracks: [Track]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        let missing = ids.filter { byID[$0] == nil }
        guard missing.isEmpty else {
            throw AutomationParameterError.invalidValue("trackIDs")
        }
        return ids.compactMap { byID[$0] }
    }
}
