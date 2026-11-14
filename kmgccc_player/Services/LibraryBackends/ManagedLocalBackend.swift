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
    private var sharedPlacements: [String: ImportPlacement] = [:]
    private var sharedMediaReleases: [@Sendable () -> Void] = []

    init(paths: LibraryPaths) { self.paths = paths }

    func prepareInputs(_ selectedURLs: [URL]) async -> ImportInputPlan {
        // A drag of several files commonly comes from Finder locations that
        // are not themselves security-scoped file URLs. Authorize each unique
        // parent directory once; the scanner can then read all children.
        for root in SecurityScopeAuthorization.groupedRoots(for: selectedURLs) {
            if root.startAccessingSecurityScopedResource() {
                selectionLeases.append(SecurityScopedResourceLease { root.stopAccessingSecurityScopedResource() })
            }
        }
        let plan = await ImportInputScanner.scan(selectedURLs: selectedURLs, directorySources: [:], sacdAreas: (try? AudioProgramSourcePreferences.areas(paths: paths)) ?? [:],
            cueSelections: (try? AudioProgramSourcePreferences.cues(paths: paths)) ?? [:])
        lastPreparedInputPlan = plan
        return plan
    }

    func makePlacement(
        for file: ImportDiscoveredFile,
        trackID: UUID,
        stagingDirectoryURL: URL
    ) async throws -> ImportPlacement {
        try verifyUnchanged(file)
        if let selection = file.mediaSelection {
            let version = "\(file.fingerprint?.fileSize ?? 0)-\(file.fingerprint?.modifiedAt ?? 0)"
            let physicalID = AudioMediaSelection.groupID(for: file.url)
            let key = "\(selection.groupID.uuidString)/\(physicalID.uuidString)-\(version)"
            if let existing = sharedPlacements[key] { return existing }
            let relativePath = "MediaAssets/\(key)/\(file.url.lastPathComponent)"
            guard let destination = paths.libraryURL(from: relativePath) else { throw CocoaError(.fileWriteInvalidFileName) }
            sharedMediaReleases.append(SharedMediaAssetStore.retainMedia(relativePath, paths: paths))
            let staged: URL
            if FileManager.default.fileExists(atPath: destination.path) {
                staged = destination
            } else {
                let folder = stagingDirectoryURL.appendingPathComponent("Shared/\(key)", isDirectory: true)
                staged = folder.appendingPathComponent(file.url.lastPathComponent)
                try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file.url, to: staged)
                    try SharedMediaAssetStore.markOwnership(folder: folder, audioFileName: file.url.lastPathComponent)
                    let correction = file.url.deletingPathExtension().appendingPathExtension("wvc")
                    if file.url.pathExtension.lowercased() == "wv", FileManager.default.isReadableFile(atPath: correction.path) {
                        try FileManager.default.copyItem(at: correction, to: folder.appendingPathComponent(correction.lastPathComponent))
                    }
                    if let descriptor = selection.descriptorPath, descriptor != file.url.path {
                        let cue = URL(fileURLWithPath: descriptor)
                        if FileManager.default.isReadableFile(atPath: descriptor) {
                            try FileManager.default.copyItem(at: cue, to: folder.appendingPathComponent(cue.lastPathComponent))
                        }
                    }
                    try Task.checkCancellation()
                }.value
            }
            try verifyUnchanged(file)
            let placement = ImportPlacement.managed(stagedAudioURL: staged, libraryRelativePath: relativePath)
            sharedPlacements[key] = placement
            return placement
        }
        let ext = file.url.pathExtension.lowercased()
        let stagedURL = stagingDirectoryURL.appendingPathComponent("\(trackID.uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        // Video containers are split by the worker directly into staging;
        // copying the complete movie here would double temporary disk use.
        if !AudioFormatSupport.isVideoContainer(file.url) {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: file.url, to: stagedURL)
                if ext == "wv" {
                    let correction = file.url.deletingPathExtension().appendingPathExtension("wvc")
                    if FileManager.default.isReadableFile(atPath: correction.path) {
                        try FileManager.default.copyItem(at: correction, to: stagedURL.deletingPathExtension().appendingPathExtension("wvc"))
                    }
                }
                try Task.checkCancellation()
            }.value
        }
        try verifyUnchanged(file)
        return .managed(
            stagedAudioURL: stagedURL,
            libraryRelativePath: "Tracks/\(trackID.uuidString)/audio.\(ext)"
        )
    }

    private func verifyUnchanged(_ file: ImportDiscoveredFile) throws {
        if let original = file.fingerprint,
           try ReferencedFileIdentityProvider().fingerprint(for: file.url) != original {
            throw AudioDecodingError.failed("文件在导入期间发生变化，请重试")
        }
    }

    func validate(_ placement: ImportPlacement) throws {
        guard placement.storageKind == .managed else {
            throw LibraryBackendError.modeMismatch(expected: mode, actual: placement.storageKind)
        }
    }

    func finishImportBatch() {
        sharedPlacements.removeAll()
        let releases = sharedMediaReleases
        sharedMediaReleases.removeAll()
        releases.forEach { $0() }
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
        identityProvider: ReferencedFileIdentityProvider = .init(),
        sacdAreas: [UUID: Int] = [:],
        cueSelections: [UUID: String] = [:]
    ) async -> ImportInputPlan {
        await Task.detached(priority: .userInitiated) {
            var failures: [ImportInputFailure] = []
            var candidates: [(URL, [ReferencedSourceMembership], UUID?, ReferencedFileFingerprint?, fromDirectory: Bool)] = []
            let roots = directorySources.keys.sorted { $0.path.count > $1.path.count }

            for selected in selectedURLs {
                if selected.hasDirectoryPath {
                    do {
                        try scanDirectory(
                            selected,
                            authorizedRoot: selected,
                            directorySources: directorySources,
                            identityProvider: identityProvider,
                            candidates: &candidates,
                            failures: &failures
                        )
                    } catch {
                        // Sole throw site is Task.checkCancellation(); abort enumeration on cancel.
                        break
                    }
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
                if VideoMusicImporter.isGeneratedAudio(candidate.0) { return false }
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
            var logicalFiles: [ImportDiscoveredFile] = []
            var logicalKeys = Set<String>()
            var cueChoices: [AudioCueDescriptorChoice] = []
            let explicitCuePaths = Set(selectedURLs.filter { $0.pathExtension.lowercased() == "cue" }.map { $0.standardizedFileURL.path })
            for file in output.sorted(by: { $0.url.pathExtension.lowercased() == "cue" && $1.url.pathExtension.lowercased() != "cue" }) {
                if Task.isCancelled { break }
                do {
                    let isCue = file.url.pathExtension.lowercased() == "cue"
                    if isCue && !explicitCuePaths.contains(file.url.standardizedFileURL.path) { continue }
                    var descriptor: URL?
                    if !isCue && file.url.pathExtension.lowercased() != "iso" {
                        let candidates = try AudioProgramResolver.externalCues(for: file.url)
                        let explicit = candidates.filter { explicitCuePaths.contains($0.standardizedFileURL.path) }
                        if explicit.count == 1 { descriptor = explicit[0] }
                        else if let saved = cueSelections[AudioMediaSelection.groupID(for: file.url)],
                                let chosen = candidates.first(where: { $0.lastPathComponent == saved }) { descriptor = chosen }
                        else if candidates.count > 1 {
                            cueChoices.append(.init(file: file, descriptors: candidates))
                            continue
                        }
                    }
                    if let tracks = try AudioProgramResolver.tracks(at: file.url,
                        area: sacdAreas[AudioMediaSelection.groupID(for: file.url)] ?? -1,
                        cueDescriptor: descriptor), !tracks.isEmpty {
                        for track in tracks {
                            guard logicalKeys.insert(track.selection.logicalKey).inserted else { continue }
                            let fingerprint = try identityProvider.fingerprint(for: track.url)
                            let derived = memberships(for: track.url, roots: roots, sourceIDs: directorySources)
                            var logical = ImportDiscoveredFile(url: track.url,
                                memberships: derived.values.isEmpty ? file.memberships : derived.values,
                                primarySourceID: derived.primary ?? file.primarySourceID, fingerprint: fingerprint)
                            logical.mediaSelection = track.selection
                            logical.programMetadata = AudioProgramMetadata(title: track.title, artist: track.artist,
                                album: track.album, albumArtist: track.albumArtist)
                            logicalFiles.append(logical)
                        }
                    } else if !logicalFiles.contains(where: { $0.url.standardizedFileURL == file.url.standardizedFileURL && $0.mediaSelection != nil }) {
                        logicalFiles.append(file)
                    }
                } catch {
                    failures.append(.init(url: file.url, message: error.localizedDescription))
                }
            }
            return ImportInputPlan(files: logicalFiles, directorySources: [], failures: failures, cueChoices: cueChoices)
        }.value
    }

    private static func scanDirectory(
        _ directory: URL,
        authorizedRoot: URL,
        directorySources: [URL: UUID],
        identityProvider: ReferencedFileIdentityProvider,
        candidates: inout [(URL, [ReferencedSourceMembership], UUID?, ReferencedFileFingerprint?, fromDirectory: Bool)],
        failures: inout [ImportInputFailure]
    ) throws {
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
            try Task.checkCancellation()
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
                try Task.checkCancellation()
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
