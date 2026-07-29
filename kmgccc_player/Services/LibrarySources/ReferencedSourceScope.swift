//
//  ReferencedSourceScope.swift
//  kmgccc_player
//

import Foundation

nonisolated enum ReferencedSourceScopeIssue: Error, Equatable, Sendable {
    case offline(UUID)
    case permissionDenied(UUID)
    case staleRefreshFailed(UUID)
    case statusPersistenceFailed(UUID)
}

@MainActor
final class AuthorizedSourceRootsProvider {
    private var roots: [UUID: AuthorizedSourceRoot] = [:]

    func snapshot() -> [UUID: AuthorizedSourceRoot] { roots }
    func set(_ root: AuthorizedSourceRoot, for sourceID: UUID) { roots[sourceID] = root }
    func remove(sourceID: UUID) { roots.removeValue(forKey: sourceID) }
    func removeAll() { roots.removeAll() }
}

@MainActor
final class ReferencedSourceScope {
    let rootsProvider: AuthorizedSourceRootsProvider
    private var leases: [UUID: SecurityScopedResourceLease] = [:]

    init(rootsProvider: AuthorizedSourceRootsProvider = AuthorizedSourceRootsProvider()) {
        self.rootsProvider = rootsProvider
    }

    var authorizedRoots: [UUID: AuthorizedSourceRoot] { rootsProvider.snapshot() }

    func start(
        descriptors: [ReferencedSourceDescriptor],
        store: ReferencedSourceStore,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) async -> [ReferencedSourceScopeIssue] {
        close()
        var issues: [ReferencedSourceScopeIssue] = []
        for descriptor in descriptors {
            let resolved: (url: URL, isStale: Bool)
            do {
                resolved = try bookmarkResolver.resolve(descriptor.rootBookmarkData)
            } catch {
                issues.append(contentsOf: await persistFailureStatus(
                    sourceID: descriptor.id,
                    status: .offline,
                    issue: .offline(descriptor.id),
                    store: store
                ))
                continue
            }

            let didStart = bookmarkResolver.startAccessing(resolved.url)
            guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: resolved.url.path)) else {
                issues.append(contentsOf: await persistFailureStatus(
                    sourceID: descriptor.id,
                    status: .permissionDenied,
                    issue: .permissionDenied(descriptor.id),
                    store: store
                ))
                continue
            }
            let lease = didStart
                ? SecurityScopedResourceLease { bookmarkResolver.stopAccessing(resolved.url) }
                : .none

            if resolved.isStale {
                do {
                    let refreshed = try bookmarkResolver.refreshBookmark(for: resolved.url)
                    _ = try await store.updateResolvedBookmark(
                        sourceID: descriptor.id,
                        bookmarkData: refreshed,
                        lastKnownPath: resolved.url.path
                    )
                } catch {
                    lease.release()
                    issues.append(contentsOf: await persistFailureStatus(
                        sourceID: descriptor.id,
                        status: .stale,
                        issue: .staleRefreshFailed(descriptor.id),
                        store: store
                    ))
                    continue
                }
            } else if descriptor.status != .available {
                do {
                    _ = try await store.updateStatus(sourceID: descriptor.id, status: .available)
                } catch {
                    lease.release()
                    issues.append(.statusPersistenceFailed(descriptor.id))
                    continue
                }
            }

            leases[descriptor.id] = lease
            rootsProvider.set(
                AuthorizedSourceRoot(url: resolved.url, scopeOwner: lease),
                for: descriptor.id
            )
        }
        return issues
    }

    func add(sourceID: UUID, url: URL, lease: SecurityScopedResourceLease) {
        if let previous = leases.removeValue(forKey: sourceID) { previous.release() }
        leases[sourceID] = lease
        rootsProvider.set(AuthorizedSourceRoot(url: url, scopeOwner: lease), for: sourceID)
    }

    func remove(sourceID: UUID) {
        rootsProvider.remove(sourceID: sourceID)
        leases.removeValue(forKey: sourceID)?.release()
    }

    func close() {
        rootsProvider.removeAll()
        let activeLeases = leases.values
        leases.removeAll()
        for lease in activeLeases { lease.release() }
    }

    private func persistFailureStatus(
        sourceID: UUID,
        status: ReferencedSourceStatus,
        issue: ReferencedSourceScopeIssue,
        store: ReferencedSourceStore
    ) async -> [ReferencedSourceScopeIssue] {
        do {
            _ = try await store.updateStatus(sourceID: sourceID, status: status)
            return [issue]
        } catch {
            return [issue, .statusPersistenceFailed(sourceID)]
        }
    }

    deinit {
        for lease in leases.values { lease.release() }
    }
}
