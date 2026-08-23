//
//  ReferencedNCMConversionService.swift
//  kmgccc_player
//

import AppKit
import AVFoundation
import Darwin
import Foundation

@MainActor
protocol NCMParentDirectoryAuthorizing: AnyObject {
    func authorizeParentDirectory(of sourceURL: URL) async throws -> NCMParentDirectoryAuthorization
}

nonisolated struct NCMParentDirectoryAuthorization: @unchecked Sendable {
    let directoryURL: URL
    let bookmarkData: Data
    let lease: SecurityScopedResourceLease
    let releasesLease: Bool
}

@MainActor
final class NCMParentDirectoryPanelAuthorizer: NCMParentDirectoryAuthorizing {
    private let bookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool

    init(
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
    }

    func authorizeParentDirectory(of sourceURL: URL) async throws -> NCMParentDirectoryAuthorization {
        let expected = sourceURL.deletingLastPathComponent().standardizedFileURL
        let panel = NSOpenPanel()
        panel.title = "授权写入转换文件"
        panel.message = "请选择“\(expected.lastPathComponent)”文件夹。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expected
        panel.prompt = "授权"
        guard await panel.begin() == .OK, let selected = panel.url,
              selected.standardizedFileURL == expected else {
            throw ReferencedNCMConversionError.parentAuthorizationDenied
        }
        let didStart = bookmarkResolver.startAccessing(selected)
        guard didStart || (!requiresSecurityScope && FileManager.default.isWritableFile(atPath: selected.path)) else {
            throw ReferencedNCMConversionError.parentAuthorizationDenied
        }
        let lease = didStart
            ? SecurityScopedResourceLease { [bookmarkResolver] in bookmarkResolver.stopAccessing(selected) }
            : .none
        do {
            let bookmark = try bookmarkResolver.refreshBookmark(for: selected)
            return NCMParentDirectoryAuthorization(
                directoryURL: selected,
                bookmarkData: bookmark,
                lease: lease,
                releasesLease: true
            )
        } catch {
            lease.release()
            throw ReferencedNCMConversionError.parentAuthorizationDenied
        }
    }
}

nonisolated enum ReferencedNCMConversionError: Error, LocalizedError, Equatable {
    case parentAuthorizationDenied
    case sourceUnavailable
    case outputConflict(String)
    case activeReservation(UUID)
    case recoveryOutputMissing(UUID)
    case committedConversion(trackID: UUID)
    case removedConversion
    case invalidOutput
    case atomicPublishFailed

    var errorDescription: String? {
        switch self {
        case .parentAuthorizationDenied: return "未获得 NCM 所在文件夹的写入权限。"
        case .sourceUnavailable: return "NCM 文件当前不可用。"
        case .outputConflict(let name): return "转换目标“\(name)”已存在，未覆盖该文件。"
        case .activeReservation: return "该 NCM 文件正在转换或等待恢复。"
        case .recoveryOutputMissing: return "NCM 转换记录需要恢复，但预期输出不存在。"
        case .committedConversion: return "该 NCM 文件已经转换并导入。"
        case .removedConversion: return "该 NCM 文件已从资料库移除。请手动重新导入以恢复。"
        case .invalidOutput: return "转换结果无法解码或时长无效。"
        case .atomicPublishFailed: return "无法安全提交 NCM 转换结果。"
        }
    }
}

nonisolated struct ReferencedNCMConversionOutput: Sendable {
    let operationID: UUID
    let sourceURL: URL
    let result: NCMConversionResult
    let locator: ReferencedFileLocator
    let association: NCMConversionAssociation
    let trackID: UUID?
}

@MainActor
final class ReferencedNCMConversionService {
    typealias Convert = @Sendable (URL, URL) async throws -> NCMConversionResult
    typealias Commit = @MainActor (UUID, UUID) async throws -> Void
    typealias Validate = @Sendable (URL) throws -> Void

    private let registry: NCMConversionRegistry
    private let sourceScope: ReferencedSourceScope
    private let parentAuthorizer: any NCMParentDirectoryAuthorizing
    private let bookmarkResolver: any BookmarkResolving
    private let identityProvider: ReferencedFileIdentityProvider
    private let convert: Convert
    private let commitOverride: Commit?
    private let validate: Validate
    private let fileManager: FileManager

    init(
        paths: LibraryPaths,
        sourceScope: ReferencedSourceScope,
        registry: NCMConversionRegistry? = nil,
        parentAuthorizer: (any NCMParentDirectoryAuthorizing)? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        identityProvider: ReferencedFileIdentityProvider = ReferencedFileIdentityProvider(),
        fileManager: FileManager = .default,
        convert: Convert? = nil,
        commitOverride: Commit? = nil,
        validate: Validate? = nil
    ) {
        self.registry = registry ?? NCMConversionRegistry(paths: paths)
        self.sourceScope = sourceScope
        self.bookmarkResolver = bookmarkResolver
        self.parentAuthorizer = parentAuthorizer ?? NCMParentDirectoryPanelAuthorizer(
            bookmarkResolver: bookmarkResolver
        )
        self.identityProvider = identityProvider
        self.fileManager = fileManager
        self.commitOverride = commitOverride
        self.validate = validate ?? Self.validateOutput
        self.convert = convert ?? { source, outputDirectory in
            try await NCMConverter().convert(
                from: source,
                outputDir: outputDirectory,
                fetchCover: true,
                progressHandler: nil
            )
        }
    }

    func convert(_ file: ImportDiscoveredFile) async throws -> ReferencedNCMConversionOutput {
        let sourceURL = file.url.standardizedFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ReferencedNCMConversionError.sourceUnavailable
        }
        let sourceFingerprint = try identityProvider.fingerprint(for: sourceURL)
        if try await registry.removedRecord(matching: sourceFingerprint) != nil {
            throw ReferencedNCMConversionError.removedConversion
        }
        if let committed = try await registry.committedRecord(matching: sourceFingerprint),
           let trackID = committed.trackID {
            throw ReferencedNCMConversionError.committedConversion(trackID: trackID)
        }
        if let active = try await registry.activeRecord(matching: sourceFingerprint) {
            return try await recover(active, sourceURL: sourceURL, sourceFingerprint: sourceFingerprint)
        }

        let authorization = try await writeAuthorization(for: file)
        defer {
            if authorization.releasesLease { authorization.lease.release() }
        }
        // Converted products live in a dedicated subfolder of the NCM's
        // parent directory instead of beside the source file, keeping the
        // user's original folder layout clean.
        let outputDirectory = authorization.directoryURL
            .appendingPathComponent(Self.outputDirectoryName, isDirectory: true)

        // Adopt a product that travelled with the source folder before doing
        // any audio decryption. New products are identified by the hidden
        // marker; legacy products are located from the NCM metadata only and
        // are marked as soon as they are adopted.
        if let existing = reusableOutput(
            sourceURL: sourceURL,
            sourceFingerprint: sourceFingerprint,
            outputDirectory: outputDirectory
        ) {
            return try await adoptExistingOutput(
                existing,
                sourceURL: sourceURL,
                sourceFingerprint: sourceFingerprint,
                file: file,
                authorization: authorization,
                outputDirectory: outputDirectory
            )
        }

        let operationID = UUID()
        let temporaryDirectory = authorization.directoryURL
            .appendingPathComponent(".kmgccc-ncm-\(operationID.uuidString)", isDirectory: true)
        let sourceBookmark = try bookmarkResolver.refreshBookmark(for: sourceURL)
        let reservationPlaceholder = authorization.directoryURL
            .appendingPathComponent(".kmgccc-ncm-\(operationID.uuidString).pending")
        let record = NCMConversionRecord(
            id: operationID,
            sourceIdentity: sourceFingerprint.identity,
            sourceFingerprint: sourceFingerprint,
            sourceBookmarkData: sourceBookmark,
            parentDirectoryBookmarkData: authorization.bookmarkData.isEmpty ? nil : authorization.bookmarkData,
            sourcePath: sourceURL.path,
            sourceMemberships: file.memberships,
            sourcePrimaryID: file.primarySourceID,
            expectedOutputPath: reservationPlaceholder.path,
            outputIdentity: nil,
            outputFingerprint: nil,
            outputLocator: nil,
            outputFormat: nil,
            outputMetadata: nil,
            outputCoverData: nil,
            trackID: nil,
            state: .pending,
            errorSummary: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await registry.reserve(record)
        var publishedURL: URL?
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
            let preliminary = try await convert(sourceURL, temporaryDirectory)
            try Task.checkCancellation()
            // Created lazily so a failed conversion leaves no empty folder.
            try createOutputDirectoryIfNeeded(outputDirectory)
            let requestedName = Self.outputFileName(sourceURL: sourceURL, result: preliminary)
            let requestedURL = outputDirectory.appendingPathComponent(requestedName)
            let outputChoice = try outputURL(
                for: requestedURL,
                sourceFingerprint: sourceFingerprint
            )
            let finalURL = outputChoice.url
            let finalName = finalURL.lastPathComponent
            try await registry.updateExpectedOutput(operationID: operationID, path: finalURL.path)
            try await registry.prepareOutputPayload(
                operationID: operationID,
                format: preliminary.format,
                metadata: preliminary.metadata,
                coverData: preliminary.coverData
            )

            try validate(preliminary.audioFileURL)
            if outputChoice.reusesExisting {
                // A previous conversion may have already published the same
                // title into this source folder while its library transaction
                // failed. Reuse a valid existing product; never overwrite it
                // and never ask Finder to authorize the same parent again.
                try validate(finalURL)
            } else {
                try Self.synchronizeFile(at: preliminary.audioFileURL)
                guard renamex_np(preliminary.audioFileURL.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST {
                        throw ReferencedNCMConversionError.outputConflict(finalName)
                    }
                    throw ReferencedNCMConversionError.atomicPublishFailed
                }
            }
            publishedURL = finalURL
            let outputFingerprint = try identityProvider.fingerprint(for: finalURL)
            let outputBookmark = try bookmarkResolver.refreshBookmark(for: finalURL)
            let locator = ReferencedFileLocator(
                fileBookmarkData: outputBookmark,
                // The generated file is the playback target, but the NCM
                // source remains the authoritative source membership. The
                // scanner hides generated output after the marker is written;
                // using the output path here would make the first scan remove
                // the track's only membership and mark it missing.
                sourceMemberships: file.memberships,
                primarySourceID: file.primarySourceID,
                lastKnownPath: finalURL.path,
                fingerprint: outputFingerprint,
                ncmSourceIdentity: sourceFingerprint.identity
            )
            try NCMGeneratedOutputMarkerStore.upsert(
                NCMGeneratedOutputRecord(
                    operationID: operationID,
                    sourcePath: sourceURL.path,
                    sourceFingerprint: sourceFingerprint,
                    outputPath: finalURL.path,
                    outputFingerprint: outputFingerprint,
                    format: preliminary.format,
                    metadata: preliminary.metadata,
                    createdAt: record.createdAt,
                    updatedAt: Date()
                ),
                in: outputDirectory,
                fileManager: fileManager
            )
            try await registry.markOutputReady(
                operationID: operationID,
                outputFingerprint: outputFingerprint,
                locator: locator,
                format: preliminary.format,
                metadata: preliminary.metadata,
                coverData: preliminary.coverData
            )
            let association = NCMConversionAssociation(
                operationID: operationID,
                sourceIdentity: sourceFingerprint.identity,
                sourcePath: sourceURL.path,
                outputIdentity: outputFingerprint.identity,
                outputPath: finalURL.path
            )
            return ReferencedNCMConversionOutput(
                operationID: operationID,
                sourceURL: sourceURL,
                result: NCMConversionResult(
                    audioFileURL: finalURL,
                    format: preliminary.format,
                    metadata: preliminary.metadata,
                    coverData: preliminary.coverData
                ),
                locator: locator,
                association: association,
                trackID: nil
            )
        } catch {
            if publishedURL == nil {
                try? await registry.markFailed(operationID: operationID, summary: error.localizedDescription)
            }
            throw error
        }
    }

    private struct ExistingOutput: Sendable {
        let url: URL
        let format: NCMFormat
        let metadata: NCMMetadata
    }

    private func reusableOutput(
        sourceURL: URL,
        sourceFingerprint: ReferencedFileFingerprint,
        outputDirectory: URL
    ) -> ExistingOutput? {
        if let marked = NCMGeneratedOutputMarkerStore.reusableRecord(
            for: sourceURL,
            sourceFingerprint: sourceFingerprint,
            in: outputDirectory,
            fileManager: fileManager,
            identityProvider: identityProvider
        ) {
            guard (try? validate(marked.outputURL)) != nil else { return nil }
            return ExistingOutput(
                url: marked.outputURL,
                format: marked.record.format,
                metadata: marked.record.metadata
            )
        }

        // Compatibility for conversions made before the marker existed. The
        // NCM header contains its title/format, so this lookup never decrypts
        // or writes audio. If the expected product is absent, the normal
        // conversion path below remains responsible for creating it.
        guard fileManager.fileExists(atPath: outputDirectory.path) else { return nil }
        guard let inspection = try? NCMConverter().inspectMetadata(from: sourceURL) else { return nil }
        let names = [
            Self.outputFileName(sourceURL: sourceURL, metadata: inspection.metadata, format: inspection.format),
            Self.outputFileName(
                sourceURL: sourceURL,
                metadata: inspection.metadata,
                format: inspection.format == .mp3 ? .flac : .mp3
            ),
        ]
        for name in names {
            let candidate = outputDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if let generated = NCMGeneratedOutputMarkerStore.record(
                forOutputPath: candidate,
                fileManager: fileManager
            ), !NCMGeneratedOutputMarkerStore.sameExactFingerprint(
                generated.sourceFingerprint,
                sourceFingerprint
            ) {
                continue
            }
            guard (try? validate(candidate)) != nil else { continue }
            return ExistingOutput(
                url: candidate,
                format: candidate.pathExtension.lowercased() == NCMFormat.flac.rawValue ? .flac : .mp3,
                metadata: inspection.metadata
            )
        }
        return nil
    }

    private func adoptExistingOutput(
        _ existing: ExistingOutput,
        sourceURL: URL,
        sourceFingerprint: ReferencedFileFingerprint,
        file: ImportDiscoveredFile,
        authorization: NCMParentDirectoryAuthorization,
        outputDirectory: URL
    ) async throws -> ReferencedNCMConversionOutput {
        try validate(existing.url)
        let operationID = UUID()
        let outputFingerprint = try identityProvider.fingerprint(for: existing.url)
        let outputBookmark = try bookmarkResolver.refreshBookmark(for: existing.url)
        let locator = ReferencedFileLocator(
            fileBookmarkData: outputBookmark,
            sourceMemberships: file.memberships,
            primarySourceID: file.primarySourceID,
            lastKnownPath: existing.url.path,
            fingerprint: outputFingerprint,
            ncmSourceIdentity: sourceFingerprint.identity
        )
        let now = Date()
        let record = NCMConversionRecord(
            id: operationID,
            sourceIdentity: sourceFingerprint.identity,
            sourceFingerprint: sourceFingerprint,
            sourceBookmarkData: try bookmarkResolver.refreshBookmark(for: sourceURL),
            parentDirectoryBookmarkData: authorization.bookmarkData.isEmpty ? nil : authorization.bookmarkData,
            sourcePath: sourceURL.path,
            sourceMemberships: file.memberships,
            sourcePrimaryID: file.primarySourceID,
            expectedOutputPath: existing.url.path,
            outputIdentity: outputFingerprint.identity,
            outputFingerprint: outputFingerprint,
            outputLocator: locator,
            outputFormat: existing.format,
            outputMetadata: existing.metadata,
            outputCoverData: nil,
            trackID: nil,
            state: .outputReady,
            errorSummary: nil,
            createdAt: now,
            updatedAt: now
        )
        try await registry.reserve(record)
        try NCMGeneratedOutputMarkerStore.upsert(
            NCMGeneratedOutputRecord(
                operationID: operationID,
                sourcePath: sourceURL.path,
                sourceFingerprint: sourceFingerprint,
                outputPath: existing.url.path,
                outputFingerprint: outputFingerprint,
                format: existing.format,
                metadata: existing.metadata,
                createdAt: now,
                updatedAt: now
            ),
            in: outputDirectory,
            fileManager: fileManager
        )
        let association = NCMConversionAssociation(
            operationID: operationID,
            sourceIdentity: sourceFingerprint.identity,
            sourcePath: sourceURL.path,
            outputIdentity: outputFingerprint.identity,
            outputPath: existing.url.path
        )
        return ReferencedNCMConversionOutput(
            operationID: operationID,
            sourceURL: sourceURL,
            result: NCMConversionResult(
                audioFileURL: existing.url,
                format: existing.format,
                metadata: existing.metadata,
                coverData: nil
            ),
            locator: locator,
            association: association,
            trackID: nil
        )
    }

    private func recover(
        _ record: NCMConversionRecord,
        sourceURL: URL,
        sourceFingerprint: ReferencedFileFingerprint
    ) async throws -> ReferencedNCMConversionOutput {
        let outputURL = URL(fileURLWithPath: record.expectedOutputPath).standardizedFileURL
        guard !outputURL.lastPathComponent.hasSuffix(".pending"),
              fileManager.fileExists(atPath: outputURL.path) else {
            throw ReferencedNCMConversionError.recoveryOutputMissing(record.id)
        }
        try validate(outputURL)
        let actualFingerprint = try identityProvider.fingerprint(for: outputURL)
        if let expected = record.outputFingerprint,
           !NCMConversionRegistry.sameFingerprint(expected, actualFingerprint) {
            throw ReferencedNCMConversionError.invalidOutput
        }
        guard let format = record.outputFormat, let metadata = record.outputMetadata else {
            throw ReferencedNCMConversionError.invalidOutput
        }
        let locator: ReferencedFileLocator
        if let persisted = record.outputLocator {
            var repaired = persisted
            if !record.sourceMemberships.isEmpty {
                repaired.sourceMemberships = record.sourceMemberships
                repaired.primarySourceID = record.sourcePrimaryID
                    ?? Self.primarySourceID(record.sourceMemberships)
            }
            repaired.lastKnownPath = outputURL.path
            repaired.fingerprint = actualFingerprint
            repaired.fileBookmarkData = (try? bookmarkResolver.refreshBookmark(for: outputURL))
                ?? repaired.fileBookmarkData
            locator = repaired
            if locator != persisted {
                try? await registry.updateOutputLocator(
                    operationID: record.id,
                    locator: locator
                )
            }
        } else {
            locator = ReferencedFileLocator(
                fileBookmarkData: try bookmarkResolver.refreshBookmark(for: outputURL),
                sourceMemberships: record.sourceMemberships,
                primarySourceID: record.sourcePrimaryID
                    ?? Self.primarySourceID(record.sourceMemberships),
                lastKnownPath: outputURL.path,
                fingerprint: actualFingerprint,
                ncmSourceIdentity: sourceFingerprint.identity
            )
            try await registry.markOutputReady(
                operationID: record.id,
                outputFingerprint: actualFingerprint,
                locator: locator,
                format: format,
                metadata: metadata,
                coverData: record.outputCoverData
            )
        }
        try? NCMGeneratedOutputMarkerStore.upsert(
            NCMGeneratedOutputRecord(
                operationID: record.id,
                sourcePath: sourceURL.path,
                sourceFingerprint: sourceFingerprint,
                outputPath: outputURL.path,
                outputFingerprint: actualFingerprint,
                format: format,
                metadata: metadata,
                createdAt: record.createdAt,
                updatedAt: Date()
            ),
            in: outputURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        let association = NCMConversionAssociation(
            operationID: record.id,
            sourceIdentity: record.sourceIdentity,
            sourcePath: record.sourcePath,
            outputIdentity: actualFingerprint.identity,
            outputPath: outputURL.path
        )
        return ReferencedNCMConversionOutput(
            operationID: record.id,
            sourceURL: sourceURL,
            result: NCMConversionResult(
                audioFileURL: outputURL,
                format: format,
                metadata: metadata,
                coverData: record.outputCoverData
            ),
            locator: locator,
            association: association,
            trackID: record.trackID
        )
    }

    func associateTrack(operationID: UUID, trackID: UUID) async throws {
        try await registry.associateTrack(operationID: operationID, trackID: trackID)
    }

    func markCommitted(operationID: UUID, trackID: UUID) async throws {
        if let commitOverride {
            try await commitOverride(operationID, trackID)
        }
        try await registry.markCommitted(operationID: operationID, trackID: trackID)
    }

    /// Returns a committed NCM output locator and repairs records written by
    /// the old implementation, which incorrectly stored the generated output
    /// path as the source membership.
    func restoreCommittedOutputLocator(
        for file: ImportDiscoveredFile
    ) async throws -> ReferencedFileLocator {
        let fingerprint: ReferencedFileFingerprint
        if let existing = file.fingerprint {
            fingerprint = existing
        } else {
            fingerprint = try identityProvider.fingerprint(for: file.url)
        }
        guard let record = try await registry.committedRecord(matching: fingerprint),
              var locator = record.outputLocator else {
            throw ReferencedNCMConversionError.invalidOutput
        }
        let outputURL = URL(fileURLWithPath: locator.lastKnownPath).standardizedFileURL
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ReferencedNCMConversionError.invalidOutput
        }
        try validate(outputURL)
        let actualFingerprint = try identityProvider.fingerprint(for: outputURL)
        if let expected = record.outputFingerprint,
           !NCMConversionRegistry.sameFingerprint(expected, actualFingerprint) {
            throw ReferencedNCMConversionError.invalidOutput
        }
        if !record.sourceMemberships.isEmpty {
            locator.sourceMemberships = record.sourceMemberships
            locator.primarySourceID = record.sourcePrimaryID
                ?? Self.primarySourceID(record.sourceMemberships)
        }
        locator.fileBookmarkData = (try? bookmarkResolver.refreshBookmark(for: outputURL))
            ?? locator.fileBookmarkData
        locator.lastKnownPath = outputURL.path
        locator.fingerprint = actualFingerprint
        if locator != record.outputLocator {
            try await registry.updateOutputLocator(
                operationID: record.id,
                locator: locator
            )
        }
        return locator
    }

    func isReserved(url: URL, identity: ReferencedFileIdentity? = nil) async throws -> Bool {
        try await registry.isReserved(url: url, identity: identity)
    }

    func allowManualRetry(
        _ file: ImportDiscoveredFile
    ) async throws -> [ReferencedFileFingerprint] {
        let fingerprint: ReferencedFileFingerprint
        if let existing = file.fingerprint {
            fingerprint = existing
        } else {
            fingerprint = try identityProvider.fingerprint(for: file.url)
        }
        return try await registry.allowManualRetry(matching: fingerprint)
    }

    private func writeAuthorization(for file: ImportDiscoveredFile) async throws -> NCMParentDirectoryAuthorization {
        if sourceScope.authorizedDirectorySourceID(containing: file.url) != nil {
            return NCMParentDirectoryAuthorization(
                directoryURL: file.url.deletingLastPathComponent(),
                bookmarkData: Data(),
                lease: .none,
                releasesLease: false
            )
        }
        return try await parentAuthorizer.authorizeParentDirectory(of: file.url)
    }

    /// Dedicated subfolder (inside the NCM's parent directory) that holds
    /// all converted audio products for that folder.
    nonisolated static let outputDirectoryName = "NCM 转换"

    /// Creates the product subfolder when absent. An existing directory is
    /// reused; a same-named regular file blocks creation and surfaces as a
    /// conflict rather than being replaced.
    private func createOutputDirectoryIfNeeded(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw ReferencedNCMConversionError.outputConflict(Self.outputDirectoryName)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ReferencedNCMConversionError.atomicPublishFailed
        }
    }

    private func outputURL(
        for requestedURL: URL,
        sourceFingerprint: ReferencedFileFingerprint
    ) throws -> (url: URL, reusesExisting: Bool) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory) else {
            return (requestedURL, false)
        }
        guard !isDirectory.boolValue else {
            throw ReferencedNCMConversionError.outputConflict(requestedURL.lastPathComponent)
        }
        let canReuseMarkedOutput: Bool
        if let generated = NCMGeneratedOutputMarkerStore.record(
            forOutputPath: requestedURL,
            fileManager: fileManager
        ) {
            canReuseMarkedOutput = NCMGeneratedOutputMarkerStore.sameExactFingerprint(
                generated.sourceFingerprint,
                sourceFingerprint
            )
        } else {
            canReuseMarkedOutput = true
        }
        if canReuseMarkedOutput, (try? validate(requestedURL)) != nil {
            return (requestedURL, true)
        }

        let stem = requestedURL.deletingPathExtension().lastPathComponent
        let extensionName = requestedURL.pathExtension
        for suffix in 2...1000 {
            let name = extensionName.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(extensionName)"
            let candidate = requestedURL.deletingLastPathComponent().appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return (candidate, false)
            }
        }
        throw ReferencedNCMConversionError.outputConflict(requestedURL.lastPathComponent)
    }

    nonisolated private static func outputFileName(
        sourceURL: URL,
        result: NCMConversionResult
    ) -> String {
        outputFileName(sourceURL: sourceURL, metadata: result.metadata, format: result.format)
    }

    nonisolated private static func outputFileName(
        sourceURL: URL,
        metadata: NCMMetadata,
        format: NCMFormat
    ) -> String {
        let metadataName = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = sourceURL.deletingPathExtension().lastPathComponent
        let base = (metadataName.isEmpty ? fallback : metadataName)
            .unicodeScalars
            .map { scalar -> Character in
                if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                    return "_"
                }
                return Character(String(scalar))
            }
        let safe = String(base).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(String(safe.prefix(180))).\(format.rawValue)"
    }

    nonisolated private static func primarySourceID(
        _ memberships: [ReferencedSourceMembership]
    ) -> UUID? {
        memberships.min {
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }?.sourceID
    }

    nonisolated private static func validateOutput(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.fileFormat.sampleRate > 0 else {
            throw ReferencedNCMConversionError.invalidOutput
        }
    }

    nonisolated private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}
