//
//  AudioLocatorResolution.swift
//  myPlayer2
//
//  Authorized local-audio resolution shared by playback and prefetch.
//

import Foundation

nonisolated protocol BookmarkResolving: Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func refreshBookmark(for url: URL) throws -> Data
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

nonisolated struct SystemBookmarkResolver: BookmarkResolving {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func refreshBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

nonisolated final class SecurityScopedResourceLease: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseAction: @Sendable () -> Void
    private var released = false

    init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseAction()
    }

    deinit { release() }

    static let none = SecurityScopedResourceLease(releaseAction: {})
}

nonisolated enum LocalAudioResolutionError: Error, Equatable, Sendable {
    case malformedLocator
    case pathTraversal
    case missing
    case permissionDenied
    case volumeUnavailable
    case notDownloaded
    case bookmarkUnresolved
}

nonisolated struct AudioLocatorResolution: @unchecked Sendable {
    let url: URL
    let lease: SecurityScopedResourceLease
    let refreshedLocator: TrackMediaLocator?
    let availability: TrackAvailability
}

nonisolated struct AuthorizedSourceRoot: @unchecked Sendable {
    let url: URL
    private let scopeOwner: SecurityScopedResourceLease

    init(url: URL, scopeOwner: SecurityScopedResourceLease) {
        self.url = url
        self.scopeOwner = scopeOwner
    }
}

nonisolated struct LocalAudioResourceResolver: Sendable {
    let paths: LibraryPaths
    let authorizedSourceRoots: [UUID: AuthorizedSourceRoot]
    let bookmarkResolver: any BookmarkResolving
    let requiresSecurityScope: Bool

    init(
        paths: LibraryPaths,
        authorizedSourceRoots: [UUID: AuthorizedSourceRoot] = [:],
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.paths = paths
        self.authorizedSourceRoots = authorizedSourceRoots
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
    }

    func resolve(_ locator: TrackMediaLocator) throws -> AudioLocatorResolution {
        switch locator {
        case let .managed(relativePath):
            guard TrackMediaLocator.isSafeRelativePath(relativePath) else {
                throw LocalAudioResolutionError.pathTraversal
            }
            guard let url = paths.libraryURL(from: relativePath) else {
                throw LocalAudioResolutionError.pathTraversal
            }
            try validateReadableFile(url)
            return AudioLocatorResolution(
                url: url,
                lease: .none,
                refreshedLocator: nil,
                availability: .available
            )
        case let .referenced(referenced):
            return try resolveReferenced(referenced)
        }
    }

    private func resolveReferenced(_ locator: ReferencedFileLocator) throws -> AudioLocatorResolution {
        var lastError: LocalAudioResolutionError = .missing

        for (locationIndex, location) in locator.locations.enumerated() {
            let orderedMemberships = location.sourceMemberships.sorted { lhs, rhs in
                if locationIndex == 0 {
                    return lhs.sourceID == locator.primarySourceID && rhs.sourceID != locator.primarySourceID
                }
                return lhs.relativePath.count < rhs.relativePath.count
            }
            for membership in orderedMemberships {
                guard TrackMediaLocator.isSafeRelativePath(membership.relativePath) else {
                    throw LocalAudioResolutionError.pathTraversal
                }
                guard let authorizedRoot = authorizedSourceRoots[membership.sourceID] else { continue }
                let lexicalRoot = authorizedRoot.url.standardizedFileURL
                let lexicalCandidate = lexicalRoot.appendingPathComponent(membership.relativePath).standardizedFileURL
                guard Self.contains(lexicalCandidate, root: lexicalRoot) else {
                    throw LocalAudioResolutionError.pathTraversal
                }
                let canonicalRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
                let canonicalCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL
                guard Self.contains(canonicalCandidate, root: canonicalRoot) else {
                    lastError = .permissionDenied
                    continue
                }
                // A previously poisoned authorized root may point into the
                // Trash (bookmark inode-follow); never play from there.
                guard !Self.isInTrash(canonicalCandidate) else { continue }
                if FileManager.default.fileExists(atPath: canonicalCandidate.path) {
                    do {
                        try validateReadableFile(canonicalCandidate)
                        return AudioLocatorResolution(
                            url: canonicalCandidate,
                            lease: .none,
                            refreshedLocator: nil,
                            availability: .available
                        )
                    } catch let error as LocalAudioResolutionError {
                        lastError = error
                    } catch {
                        lastError = .missing
                    }
                }
            }

            guard !location.fileBookmarkData.isEmpty else { continue }
            let resolved: (url: URL, isStale: Bool)
            do {
                resolved = try bookmarkResolver.resolve(location.fileBookmarkData)
            } catch {
                lastError = .bookmarkUnresolved
                continue
            }
            // Bookmarks follow the inode: a file moved to the Trash still
            // resolves and would keep playing from there. Treat trashed files
            // as missing instead — relocation tracking to real folders stays.
            guard !Self.isInTrash(resolved.url) else {
                lastError = .missing
                continue
            }

            let didStart = bookmarkResolver.startAccessing(resolved.url)
            guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: resolved.url.path)) else {
                lastError = .permissionDenied
                continue
            }
            let lease = didStart
                ? SecurityScopedResourceLease { bookmarkResolver.stopAccessing(resolved.url) }
                : .none
            do {
                try validateReadableFile(resolved.url)
            } catch let error as LocalAudioResolutionError {
                lease.release()
                lastError = error
                continue
            } catch {
                lease.release()
                lastError = .missing
                continue
            }

            var refreshedLocator: TrackMediaLocator?
            if resolved.isStale, let data = try? bookmarkResolver.refreshBookmark(for: resolved.url) {
                var updated = locator
                if locationIndex == 0 {
                    updated.fileBookmarkData = data
                    updated.lastKnownPath = resolved.url.path
                } else if locationIndex - 1 < updated.alternateLocations.count {
                    updated.alternateLocations[locationIndex - 1].fileBookmarkData = data
                    updated.alternateLocations[locationIndex - 1].lastKnownPath = resolved.url.path
                }
                refreshedLocator = .referenced(updated)
            }
            return AudioLocatorResolution(
                url: resolved.url,
                lease: lease,
                refreshedLocator: refreshedLocator,
                availability: resolved.isStale ? .stale : .available
            )
        }

        throw lastError
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func isInTrash(_ url: URL) -> Bool {
        let components = url.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    private func validateReadableFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                throw LocalAudioResolutionError.volumeUnavailable
            }
            throw LocalAudioResolutionError.missing
        }
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        if values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus != .current {
            throw LocalAudioResolutionError.notDownloaded
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LocalAudioResolutionError.permissionDenied
        }
    }
}
