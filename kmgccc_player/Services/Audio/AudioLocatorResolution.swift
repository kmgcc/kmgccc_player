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

/// Shares one security-scope authorization across several selected files.
/// Each source/operation receives its own child lease, while the underlying
/// parent-directory scope is started and stopped exactly once.
nonisolated final class SecurityScopedResourceLeasePool: @unchecked Sendable {
    private let lock = NSLock()
    private let rootLease: SecurityScopedResourceLease
    private var references = 0
    private var isReleased = false

    init(rootLease: SecurityScopedResourceLease) {
        self.rootLease = rootLease
    }

    func makeLease() -> SecurityScopedResourceLease {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return .none
        }
        references += 1
        lock.unlock()
        return SecurityScopedResourceLease { [self] in
            releaseReference()
        }
    }

    private func releaseReference() {
        lock.lock()
        guard references > 0 else {
            lock.unlock()
            return
        }
        references -= 1
        let shouldReleaseRoot = references == 0 && !isReleased
        if shouldReleaseRoot { isReleased = true }
        lock.unlock()
        if shouldReleaseRoot { rootLease.release() }
    }

    deinit {
        lock.lock()
        let shouldReleaseRoot = !isReleased
        isReleased = true
        lock.unlock()
        if shouldReleaseRoot { rootLease.release() }
    }
}

/// Groups selected files by the directory that actually needs authorization.
/// Directory selections cover descendants, so a parent scope is retained once
/// instead of prompting once for every dropped file.
nonisolated enum SecurityScopeAuthorization {
    static func groupedRoots(for urls: [URL]) -> [URL] {
        let candidates = urls
            .map { authorizationRoot(for: $0) }
            .reduce(into: [URL]()) { result, url in
                let path = canonicalPath(url)
                guard !result.contains(where: { canonicalPath($0) == path }) else { return }
                result.append(url)
            }
            .sorted { canonicalPath($0).count < canonicalPath($1).count }

        var roots: [URL] = []
        for candidate in candidates {
            let path = canonicalPath(candidate)
            guard !roots.contains(where: { root in
                let rootPath = canonicalPath(root)
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }) else { continue }
            roots.append(candidate)
        }
        return roots
    }

    static func authorizationRoot(for url: URL) -> URL {
        let candidate: URL
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            candidate = url
        } else {
            candidate = url.deletingLastPathComponent()
        }
        return candidate.standardizedFileURL
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
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
        let candidates = try resolveCandidates(locator)
        guard let first = candidates.first else {
            throw LocalAudioResolutionError.missing
        }
        // `resolve` is the legacy single-result API. It must not retain
        // security scopes for fallback candidates that the caller cannot see.
        for candidate in candidates.dropFirst() {
            candidate.lease.release()
        }
        return first
    }

    /// Resolves every currently usable physical location in preference order.
    ///
    /// A referenced duplicate may carry a newly selected copy whose metadata is
    /// readable while its codec/container is not playable by AVAudioFile. The
    /// playback preparation actor uses this list to fall back to the original
    /// location instead of treating the first readable path as authoritative.
    func resolveCandidates(_ locator: TrackMediaLocator) throws -> [AudioLocatorResolution] {
        switch locator {
        case let .managed(relativePath):
            guard TrackMediaLocator.isSafeRelativePath(relativePath) else {
                throw LocalAudioResolutionError.pathTraversal
            }
            guard let url = paths.libraryURL(from: relativePath) else {
                throw LocalAudioResolutionError.pathTraversal
            }
            try validateReadableFile(url)
            return [AudioLocatorResolution(
                url: url,
                lease: .none,
                refreshedLocator: nil,
                availability: .available
            )]
        case let .referenced(referenced):
            return try resolveReferencedCandidates(referenced)
        }
    }

    private func resolveReferencedCandidates(_ locator: ReferencedFileLocator) throws -> [AudioLocatorResolution] {
        var lastError: LocalAudioResolutionError = .missing
        var resolutions: [AudioLocatorResolution] = []
        var resolvedPaths = Set<String>()

        for (locationIndex, location) in locator.locations.enumerated() {
            let orderedMemberships = location.sourceMemberships.sorted { lhs, rhs in
                if locationIndex == 0 {
                    return lhs.sourceID == locator.primarySourceID && rhs.sourceID != locator.primarySourceID
                }
                return lhs.relativePath.count < rhs.relativePath.count
            }
            for membership in orderedMemberships {
                guard TrackMediaLocator.isSafeRelativePath(membership.relativePath) else {
                    // A malformed/stale source edge must not hide a valid
                    // bookmark or alternate location. Reject this candidate
                    // in isolation and continue; no unsafe path is ever
                    // constructed or accessed.
                    lastError = .pathTraversal
                    continue
                }
                guard let authorizedRoot = authorizedSourceRoots[membership.sourceID] else { continue }
                let lexicalRoot = authorizedRoot.url.standardizedFileURL
                // A single-file source intentionally keeps its file URL as
                // the authorized root (so it cannot grant access to the
                // surrounding directory). Its membership is the file name,
                // not a child path below that file. Resolve that shape to the
                // root itself; appending the membership would otherwise
                // produce `/song.mp3/song.mp3` and make the imported track
                // appear unavailable during playback.
                let rootIsDirectory: Bool
                if let resourceValues = try? lexicalRoot.resourceValues(forKeys: [.isDirectoryKey]),
                   let isDirectory = resourceValues.isDirectory {
                    rootIsDirectory = isDirectory
                } else {
                    rootIsDirectory = lexicalRoot.hasDirectoryPath
                }
                let lexicalCandidate: URL
                if rootIsDirectory {
                    lexicalCandidate = lexicalRoot
                        .appendingPathComponent(membership.relativePath)
                        .standardizedFileURL
                } else {
                    let canonicalRootName = lexicalRoot
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                        .lastPathComponent
                    guard membership.relativePath == lexicalRoot.lastPathComponent
                        || membership.relativePath == canonicalRootName
                    else {
                        lastError = .permissionDenied
                        continue
                    }
                    lexicalCandidate = lexicalRoot
                }
                guard Self.contains(lexicalCandidate, root: lexicalRoot) else {
                    lastError = .pathTraversal
                    continue
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
                        let canonicalPath = canonicalCandidate.path
                        guard resolvedPaths.insert(canonicalPath).inserted else { continue }
                        let resolution = AudioLocatorResolution(
                            url: canonicalCandidate,
                            lease: .none,
                            refreshedLocator: nil,
                            availability: .available
                        )
                        resolutions.append(resolution)
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
            let canonicalPath = resolved.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPaths.insert(canonicalPath).inserted else {
                lease.release()
                continue
            }
            resolutions.append(AudioLocatorResolution(
                url: resolved.url,
                lease: lease,
                refreshedLocator: refreshedLocator,
                availability: resolved.isStale ? .stale : .available
            ))
        }

        guard !resolutions.isEmpty else { throw lastError }
        return resolutions
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
