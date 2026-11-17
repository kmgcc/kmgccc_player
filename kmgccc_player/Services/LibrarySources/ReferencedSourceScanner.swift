import Foundation

nonisolated enum ReferencedSourceScanError: Error, Equatable {
    case sourceOffline
    case permissionDenied
    case cancelled
    /// The source's scan manifest comes from a newer build. The bindings it
    /// carries cannot be read here, so the source must be skipped rather than
    /// rescanned from scratch.
    case manifestFromNewerBuild(Int)
}

actor NCMScanReservationFilter {
    private let registry: NCMConversionRegistry

    init(registry: NCMConversionRegistry) { self.registry = registry }

    func isReserved(url: URL, identity: ReferencedFileIdentity?) async -> Bool {
        do {
            return try await registry.isReserved(url: url, identity: identity)
        } catch {
            Log.warning(
                "[ReferencedSource] NCM reservation lookup failed; conservatively skipping \(url.lastPathComponent)",
                category: .library
            )
            return true
        }
    }
}

actor ReferencedSourceScanner {
    typealias ReservationCheck = @Sendable (URL, ReferencedFileIdentity?) async -> Bool
    typealias IgnoreCheck = @Sendable (ReferencedFileFingerprint) async -> Bool
    typealias FingerprintProvider = @Sendable (URL) throws -> ReferencedFileFingerprint

    private let paths: LibraryPaths
    private let fingerprintProvider: FingerprintProvider
    private let fileManager: FileManager
    private let manifestStore: ReferencedSourceScanManifestStore
    private let isReserved: ReservationCheck
    private let isIgnored: IgnoreCheck
    private let supportedExtensions: Set<String>

    init(
        paths: LibraryPaths,
        fingerprintProvider: @escaping FingerprintProvider = {
            try ReferencedFileIdentityProvider().fingerprint(for: $0)
        },
        fileManager: FileManager = .default,
        supportedExtensions: Set<String> = AudioFormatSupport.importableExtensions,
        isReserved: @escaping ReservationCheck = { _, _ in false },
        isIgnored: @escaping IgnoreCheck = { _ in false }
    ) {
        self.paths = paths
        self.fingerprintProvider = fingerprintProvider
        self.fileManager = fileManager
        manifestStore = ReferencedSourceScanManifestStore(paths: paths)
        self.supportedExtensions = supportedExtensions
        self.isReserved = isReserved
        self.isIgnored = isIgnored
    }

    func scan(
        context: LibraryContext,
        sourceID: UUID,
        rootURL: URL,
        excludedRelativePaths: Set<String> = []
    ) async throws -> ReferencedSourceScanResult {
        guard context.mode == .referenced else { throw ReferencedSourceScanError.sourceOffline }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return unavailableDiff(context: context, sourceID: sourceID, status: .offline)
        }
        guard fileManager.isReadableFile(atPath: rootURL.path) else {
            return unavailableDiff(context: context, sourceID: sourceID, status: .permissionDenied)
        }

        let previous: ReferencedSourceScanManifest?
        do {
            previous = try await manifestStore.load(sourceID: sourceID, libraryID: context.id)
        } catch ReferencedSourceScanManifestStoreError.newerSchema(let version) {
            throw ReferencedSourceScanError.manifestFromNewerBuild(version)
        }
        let generation = (previous?.generation ?? 0) &+ 1
        let snapshot: (entries: [ReferencedSourceScanEntry], ignored: [ReferencedSourceIgnoredFile], failures: [ReferencedSourceScanFailure])
        if isDirectory.boolValue {
            snapshot = try await enumerate(
                rootURL: rootURL,
                generation: generation,
                excludedRelativePaths: excludedRelativePaths
            )
        } else {
            snapshot = try await enumerateSingleFile(rootURL: rootURL, generation: generation)
        }
        try Task.checkCancellation()
        let (diff, entries) = buildDiff(
            context: context,
            sourceID: sourceID,
            generation: generation,
            previous: previous?.entries ?? [],
            current: snapshot.entries,
            ignored: snapshot.ignored,
            failures: snapshot.failures
        )
        return ReferencedSourceScanResult(
            diff: diff,
            proposedManifest: ReferencedSourceScanManifest(
                libraryID: context.id,
                sourceID: sourceID,
                generation: generation,
                lastSuccessfulScan: Date(),
                entries: entries
            )
        )
    }

    /// A file source roots at the audio file itself; the scan is a single
    /// entry keyed by the file name.
    private func enumerateSingleFile(rootURL: URL, generation: UInt64) async throws -> (
        entries: [ReferencedSourceScanEntry],
        ignored: [ReferencedSourceIgnoredFile],
        failures: [ReferencedSourceScanFailure]
    ) {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        do {
            let values = try root.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isHiddenKey])
            guard values.isRegularFile == true,
                  values.isPackage != true,
                  values.isHidden != true,
                  supportedExtensions.contains(root.pathExtension.lowercased()) else {
                return ([], [], [])
            }
            let fingerprint = try fingerprintProvider(root)
            if await isReserved(root, fingerprint.identity) { return ([], [], []) }
            if await isIgnored(fingerprint) {
                return ([], [.init(relativePath: root.lastPathComponent, fingerprint: fingerprint)], [])
            }
            return (
                [try makeEntry(url: root, relativePath: root.lastPathComponent, fingerprint: fingerprint, generation: generation)],
                [],
                []
            )
        } catch {
            return ([], [], [.init(relativePath: root.lastPathComponent, summary: String(describing: error).prefixString(256))])
        }
    }

    private func enumerate(rootURL: URL, generation: UInt64) async throws -> (
        entries: [ReferencedSourceScanEntry],
        ignored: [ReferencedSourceIgnoredFile],
        failures: [ReferencedSourceScanFailure]
    ) {
        return try await enumerate(
            rootURL: rootURL,
            generation: generation,
            excludedRelativePaths: []
        )
    }

    private func enumerate(
        rootURL: URL,
        generation: UInt64,
        excludedRelativePaths: Set<String>
    ) async throws -> (
        entries: [ReferencedSourceScanEntry],
        ignored: [ReferencedSourceIgnoredFile],
        failures: [ReferencedSourceScanFailure]
    ) {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var pending = [root]
        var visitedDirectories = Set<String>()
        var entries: [ReferencedSourceScanEntry] = []
        var ignored: [ReferencedSourceIgnoredFile] = []
        var failures: [ReferencedSourceScanFailure] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .volumeUUIDStringKey, .fileSizeKey, .contentModificationDateKey]

        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let directoryValues = try directory.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey])
            let directoryKey = "\(directoryValues.volumeUUIDString ?? ""):\(String(describing: directoryValues.fileResourceIdentifier))"
            guard visitedDirectories.insert(directoryKey).inserted else { continue }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [])
            } catch {
                failures.append(.init(relativePath: relativePath(directory, root: root), summary: String(describing: error).prefixString(256)))
                continue
            }
            for child in children {
                try Task.checkCancellation()
                do {
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isHidden == true || values.isPackage == true { continue }
                    let resolved = values.isSymbolicLink == true ? child.resolvingSymlinksInPath().standardizedFileURL : child.standardizedFileURL
                    guard contains(resolved, in: root) else { continue }
                    if values.isDirectory == true {
                        if let relative = relativePath(resolved, root: root),
                           isExcluded(relative, paths: excludedRelativePaths) {
                            continue
                        }
                        pending.append(resolved)
                        continue
                    }
                    guard values.isRegularFile == true,
                          resolved.pathExtension.lowercased() != "cue",
                          supportedExtensions.contains(resolved.pathExtension.lowercased()) else { continue }
                    let fingerprint = try fingerprintProvider(resolved)
                    if VideoMusicImporter.isGeneratedAudio(resolved) { continue }
                    if await isReserved(resolved, fingerprint.identity) { continue }
                    if NCMGeneratedOutputMarkerStore.isGeneratedOutput(
                        resolved,
                        fingerprint: fingerprint,
                        fileManager: fileManager
                    ) {
                        continue
                    }
                    guard let relative = relativePath(resolved, root: root) else { continue }
                    guard !isExcluded(relative, paths: excludedRelativePaths) else { continue }
                    if await isIgnored(fingerprint) {
                        ignored.append(.init(relativePath: relative, fingerprint: fingerprint))
                        continue
                    }
                    entries.append(try makeEntry(url: resolved, relativePath: relative, fingerprint: fingerprint, generation: generation))
                } catch {
                    failures.append(.init(relativePath: relativePath(child, root: root), summary: String(describing: error).prefixString(256)))
                }
            }
        }
        entries.sort { $0.relativePath < $1.relativePath }
        ignored.sort { $0.relativePath < $1.relativePath }
        return (entries, ignored, failures)
    }

    private func makeEntry(url: URL, relativePath: String, fingerprint: ReferencedFileFingerprint,
        generation: UInt64) throws -> ReferencedSourceScanEntry {
        var entry = ReferencedSourceScanEntry(relativePath: relativePath, identity: fingerprint.identity,
            fingerprint: fingerprint, trackID: nil, availability: .available, lastSeenGeneration: generation)
        if url.pathExtension.lowercased() != "cue" && url.pathExtension.lowercased() != "iso" {
            let descriptors = try AudioProgramResolver.externalCues(for: url)
            let saved = try AudioProgramSourcePreferences.cues(paths: paths)[AudioMediaSelection.groupID(for: url)]
            if let selected = descriptors.first(where: { $0.lastPathComponent == saved }) ?? (descriptors.count == 1 ? descriptors.first : nil) {
                entry.programFingerprint = try fingerprintProvider(selected)
            }
        }
        if url.pathExtension.lowercased() == "wv" {
            let correction = url.deletingPathExtension().appendingPathExtension("wvc")
            if fileManager.fileExists(atPath: correction.path) { entry.correctionFingerprint = try fingerprintProvider(correction) }
        }
        return entry
    }

    private func buildDiff(
        context: LibraryContext,
        sourceID: UUID,
        generation: UInt64,
        previous: [ReferencedSourceScanEntry],
        current: [ReferencedSourceScanEntry],
        ignored: [ReferencedSourceIgnoredFile],
        failures: [ReferencedSourceScanFailure]
    ) -> (ReferencedSourceDiff, [ReferencedSourceScanEntry]) {
        let oldByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.relativePath, $0) })
        var oldByIdentity: [ReferencedFileIdentity: ReferencedSourceScanEntry] = [:]
        for entry in previous where entry.identity?.isStable == true { oldByIdentity[entry.identity!] = entry }
        let oldFallbackGroups = Dictionary(grouping: previous.filter { $0.identity?.isStable != true }) {
            ReferencedPhysicalIdentityKey($0.fingerprint)
        }
        let currentFallbackGroups = Dictionary(grouping: current.filter { $0.identity?.isStable != true }) {
            ReferencedPhysicalIdentityKey($0.fingerprint)
        }
        var consumedOldPaths = Set<String>()
        var next = current
        var diff = ReferencedSourceDiff(libraryID: context.id, libraryGeneration: context.generation, sourceID: sourceID, scanGeneration: generation, sourceStatus: .available, failures: failures)
        diff.ignored = ignored
        let ignoredKeys = Set(ignored.map { ReferencedPhysicalIdentityKey($0.fingerprint) })

        for index in next.indices {
            var entry = next[index]
            if let old = oldByPath[entry.relativePath] {
                consumedOldPaths.insert(old.relativePath)
                entry.trackID = old.trackID
                entry.trackIDs = old.trackIDs
                if old.boundTrackIDs.isEmpty {
                    // A prior scan saw the file but its import failed. Keep
                    // the manifest entry for auditability, while presenting
                    // it as an addition again so the next scan retries it.
                    diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
                } else if (entry.programFingerprint != nil && old.programFingerprint != entry.programFingerprint)
                    || old.correctionFingerprint != entry.correctionFingerprint {
                    diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
                } else if old.fingerprint != entry.fingerprint {
                    for trackID in old.boundTrackIDs {
                        diff.replacements.append(.init(trackID: trackID, relativePath: entry.relativePath, oldFingerprint: old.fingerprint, newFingerprint: entry.fingerprint))
                    }
                }
            } else if let identity = entry.identity, identity.isStable, let old = oldByIdentity[identity] {
                consumedOldPaths.insert(old.relativePath)
                entry.trackID = old.trackID
                entry.trackIDs = old.trackIDs
                if !old.boundTrackIDs.isEmpty {
                    for trackID in old.boundTrackIDs {
                        diff.moved.append(.init(trackID: trackID, oldRelativePath: old.relativePath, newRelativePath: entry.relativePath, fingerprint: entry.fingerprint))
                    }
                } else {
                    diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
                }
            } else if entry.identity?.isStable != true {
                let key = ReferencedPhysicalIdentityKey(entry.fingerprint)
                let oldMatches = oldFallbackGroups[key] ?? []
                let currentMatches = currentFallbackGroups[key] ?? []
                if oldMatches.count == 1, currentMatches.count == 1,
                   let old = oldMatches.first, !consumedOldPaths.contains(old.relativePath) {
                    consumedOldPaths.insert(old.relativePath)
                    entry.trackID = old.trackID
                    entry.trackIDs = old.trackIDs
                    if !old.boundTrackIDs.isEmpty {
                        for trackID in old.boundTrackIDs {
                            diff.moved.append(.init(trackID: trackID, oldRelativePath: old.relativePath, newRelativePath: entry.relativePath, fingerprint: entry.fingerprint))
                        }
                    } else {
                        diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
                    }
                } else {
                    diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
                }
            } else {
                diff.added.append(.init(relativePath: entry.relativePath, fingerprint: entry.fingerprint))
            }
            next[index] = entry
        }
        for old in previous where !consumedOldPaths.contains(old.relativePath) {
            if ignoredKeys.contains(ReferencedPhysicalIdentityKey(old.fingerprint)) { continue }
            let coveredByFailure = failures.contains { failure in
                guard let failedPath = failure.relativePath else { return true }
                return old.relativePath == failedPath || old.relativePath.hasPrefix(failedPath + "/")
            }
            guard !coveredByFailure else {
                if let preserved = oldByPath[old.relativePath] { next.append(preserved) }
                continue
            }
            for trackID in old.boundTrackIDs { diff.missing.append(.init(trackID: trackID, relativePath: old.relativePath)) }
        }
        next.sort { $0.relativePath < $1.relativePath }
        return (diff, next)
    }

    private func unavailableDiff(context: LibraryContext, sourceID: UUID, status: ReferencedSourceStatus) -> ReferencedSourceScanResult {
        ReferencedSourceScanResult(
            diff: ReferencedSourceDiff(libraryID: context.id, libraryGeneration: context.generation, sourceID: sourceID, scanGeneration: 0, sourceStatus: status),
            proposedManifest: nil
        )
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func isExcluded(_ relativePath: String, paths: Set<String>) -> Bool {
        paths.contains { excluded in
            relativePath == excluded || relativePath.hasPrefix(excluded + "/")
        }
    }

    private func relativePath(_ url: URL, root: URL) -> String? {
        guard contains(url, in: root), url.path != root.path else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }
}

nonisolated private extension ReferencedFileIdentity {
    var isStable: Bool { volumeUUID?.isEmpty == false && resourceIdentifierArchive?.isEmpty == false }
}

nonisolated private extension StringProtocol {
    func prefixString(_ count: Int) -> String { String(prefix(count)) }
}
