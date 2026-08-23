//
//  ManagedLocalBackend.swift
//  kmgccc_player
//

import Foundation

@MainActor
final class ManagedLocalBackend: LibraryStorageBackend {
    let mode: MusicLibraryMode = .managed
    private(set) var lastPreparedInputPlan: ImportInputPlan?
    private let paths: LibraryPaths
    private var selectionLeases: [SecurityScopedResourceLease] = []

    init(paths: LibraryPaths) { self.paths = paths }

    func prepareInputs(_ selectedURLs: [URL]) async -> ImportInputPlan {
        for url in selectedURLs {
            if url.startAccessingSecurityScopedResource() {
                selectionLeases.append(SecurityScopedResourceLease { url.stopAccessingSecurityScopedResource() })
            }
        }
        let plan = await ImportInputScanner.scan(selectedURLs: selectedURLs, directorySources: [:])
        lastPreparedInputPlan = plan
        return plan
    }

    func makePlacement(
        for file: ImportDiscoveredFile,
        trackID: UUID,
        stagingDirectoryURL: URL
    ) async throws -> ImportPlacement {
        let ext = file.url.pathExtension.lowercased()
        let stagedURL = stagingDirectoryURL.appendingPathComponent("\(trackID.uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        try FileManager.default.copyItem(at: file.url, to: stagedURL)
        return .managed(
            stagedAudioURL: stagedURL,
            libraryRelativePath: "Tracks/\(trackID.uuidString)/audio.\(ext)"
        )
    }

    func validate(_ placement: ImportPlacement) throws {
        guard placement.storageKind == .managed else {
            throw LibraryBackendError.modeMismatch(expected: mode, actual: placement.storageKind)
        }
    }

    func finishImportBatch() {
        let leases = selectionLeases
        selectionLeases.removeAll()
        for lease in leases { lease.release() }
    }

    func close() async { finishImportBatch() }
}

nonisolated enum ImportInputScanner {
    static func scan(
        selectedURLs: [URL],
        directorySources: [URL: UUID],
        identityProvider: ReferencedFileIdentityProvider = .init()
    ) async -> ImportInputPlan {
        await Task.detached(priority: .userInitiated) {
            var failures: [ImportInputFailure] = []
            var candidates: [(URL, [ReferencedSourceMembership], UUID?, ReferencedFileFingerprint?, fromDirectory: Bool)] = []
            let roots = directorySources.keys.sorted { $0.path.count > $1.path.count }

            for selected in selectedURLs {
                if selected.hasDirectoryPath {
                    scanDirectory(
                        selected,
                        authorizedRoot: selected,
                        directorySources: directorySources,
                        identityProvider: identityProvider,
                        candidates: &candidates,
                        failures: &failures
                    )
                } else if isAudioFile(selected) {
                    do {
                        let fingerprint = try identityProvider.fingerprint(for: selected)
                        let memberships = memberships(for: selected, roots: roots, sourceIDs: directorySources)
                        candidates.append((selected, memberships.values, memberships.primary, fingerprint, false))
                    } catch {
                        failures.append(.init(url: selected, message: error.localizedDescription))
                    }
                }
            }

            let filteredCandidates = candidates.filter { candidate in
                guard candidate.fromDirectory, let fingerprint = candidate.3 else { return true }
                return !NCMGeneratedOutputMarkerStore.isGeneratedOutput(
                    candidate.0,
                    fingerprint: fingerprint
                )
            }
            var byIdentity: [ReferencedPhysicalIdentityKey: Int] = [:]
            var output: [ImportDiscoveredFile] = []
            for candidate in filteredCandidates {
                guard let fingerprint = candidate.3 else { continue }
                let key = ReferencedPhysicalIdentityKey(fingerprint)
                if let index = byIdentity[key] {
                    let existing = output[index]
                    let merged = mergeMemberships(existing.memberships, candidate.1)
                    output[index] = ImportDiscoveredFile(
                        url: existing.url,
                        memberships: merged,
                        primarySourceID: merged.min { $0.relativePath.count < $1.relativePath.count }?.sourceID,
                        fingerprint: existing.fingerprint
                    )
                } else {
                    byIdentity[key] = output.count
                    output.append(.init(
                        url: candidate.0,
                        memberships: candidate.1,
                        primarySourceID: candidate.2,
                        fingerprint: fingerprint
                    ))
                }
            }
            return ImportInputPlan(files: output, directorySources: [], failures: failures)
        }.value
    }

    private static func scanDirectory(
        _ directory: URL,
        authorizedRoot: URL,
        directorySources: [URL: UUID],
        identityProvider: ReferencedFileIdentityProvider,
        candidates: inout [(URL, [ReferencedSourceMembership], UUID?, ReferencedFileFingerprint?, fromDirectory: Bool)],
        failures: inout [ImportInputFailure]
    ) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
            .isPackageKey, .isHiddenKey, .fileResourceIdentifierKey,
        ]
        let canonicalRoot = authorizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let roots = directorySources.keys.sorted { $0.path.count > $1.path.count }
        var stack = [directory]
        var visitedDirectories = Set<Data>()
        var visitedDirectoryPaths = Set<String>()

        while let nextDirectory = stack.popLast() {
            let canonicalDirectory = nextDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard contains(canonicalDirectory, root: canonicalRoot) else { continue }
            let directoryValues = try? canonicalDirectory.resourceValues(forKeys: [.fileResourceIdentifierKey])
            let identifierData = directoryValues?.fileResourceIdentifier.flatMap { identifier in
                if let data = identifier as? Data { return data }
                return try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: false)
            }
            if let identifierData {
                guard visitedDirectories.insert(identifierData).inserted else { continue }
            } else {
                guard visitedDirectoryPaths.insert(canonicalDirectory.path).inserted else { continue }
            }

            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: nextDirectory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                failures.append(.init(url: nextDirectory, message: error.localizedDescription))
                continue
            }

            for item in children {
                guard let lexicalValues = try? item.resourceValues(forKeys: keys) else {
                    failures.append(.init(url: item, message: "Unable to inspect item"))
                    continue
                }
                if lexicalValues.isHidden == true || lexicalValues.isPackage == true { continue }

                let target: URL
                if lexicalValues.isAliasFile == true {
                    do {
                        target = try URL(resolvingAliasFileAt: item, options: [.withoutUI, .withoutMounting])
                            .resolvingSymlinksInPath().standardizedFileURL
                    } catch {
                        failures.append(.init(url: item, message: "Unable to resolve Finder alias"))
                        continue
                    }
                } else {
                    target = item.resolvingSymlinksInPath().standardizedFileURL
                }
                guard contains(target, root: canonicalRoot) else { continue }
                guard let targetValues = try? target.resourceValues(forKeys: keys) else {
                    failures.append(.init(url: item, message: "Unable to inspect resolved item"))
                    continue
                }
                if targetValues.isHidden == true || targetValues.isPackage == true { continue }
                if targetValues.isDirectory == true {
                    stack.append(target)
                    continue
                }
                guard targetValues.isRegularFile == true, isAudioFile(target) else { continue }
                do {
                    let fingerprint = try identityProvider.fingerprint(for: target)
                    let memberships = memberships(for: target, roots: roots, sourceIDs: directorySources)
                    candidates.append((target, memberships.values, memberships.primary, fingerprint, true))
                } catch {
                    failures.append(.init(url: item, message: error.localizedDescription))
                }
            }
        }
    }

    private static func memberships(
        for file: URL,
        roots: [URL],
        sourceIDs: [URL: UUID]
    ) -> (values: [ReferencedSourceMembership], primary: UUID?) {
        let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL
        var values: [ReferencedSourceMembership] = []
        for root in roots {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard contains(canonicalFile, root: canonicalRoot), let sourceID = sourceIDs[root] else { continue }
            // A file source's root is the file itself; its membership path is
            // just the file name, matching the scanner's single-entry layout.
            let relative = canonicalFile.path == canonicalRoot.path
                ? canonicalFile.lastPathComponent
                : String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
            values.append(.init(sourceID: sourceID, relativePath: relative))
        }
        return (values, values.first?.sourceID)
    }

    private static func mergeMemberships(
        _ lhs: [ReferencedSourceMembership],
        _ rhs: [ReferencedSourceMembership]
    ) -> [ReferencedSourceMembership] {
        Array(Set(lhs).union(rhs)).sorted {
            if $0.relativePath.count != $1.relativePath.count { return $0.relativePath.count < $1.relativePath.count }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        AudioFormatSupport.importableExtensions.contains(url.pathExtension.lowercased())
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
