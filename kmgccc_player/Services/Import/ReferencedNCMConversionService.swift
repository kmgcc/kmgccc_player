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
        parentAuthorizer: (any NCMParentDirectoryAuthorizing)? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        identityProvider: ReferencedFileIdentityProvider = ReferencedFileIdentityProvider(),
        fileManager: FileManager = .default,
        convert: Convert? = nil,
        commitOverride: Commit? = nil,
        validate: Validate? = nil
    ) {
        self.registry = NCMConversionRegistry(paths: paths)
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
            let finalName = Self.outputFileName(sourceURL: sourceURL, result: preliminary)
            let finalURL = authorization.directoryURL.appendingPathComponent(finalName)
            guard !fileManager.fileExists(atPath: finalURL.path) else {
                throw ReferencedNCMConversionError.outputConflict(finalName)
            }
            try await registry.updateExpectedOutput(operationID: operationID, path: finalURL.path)
            try await registry.prepareOutputPayload(
                operationID: operationID,
                format: preliminary.format,
                metadata: preliminary.metadata,
                coverData: preliminary.coverData
            )

            try validate(preliminary.audioFileURL)
            try Self.synchronizeFile(at: preliminary.audioFileURL)
            guard renamex_np(preliminary.audioFileURL.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST {
                    throw ReferencedNCMConversionError.outputConflict(finalName)
                }
                throw ReferencedNCMConversionError.atomicPublishFailed
            }
            publishedURL = finalURL
            let outputFingerprint = try identityProvider.fingerprint(for: finalURL)
            let outputBookmark = try bookmarkResolver.refreshBookmark(for: finalURL)
            let outputMemberships = Self.outputMemberships(
                sourceMemberships: file.memberships,
                outputName: finalName
            )
            let locator = ReferencedFileLocator(
                fileBookmarkData: outputBookmark,
                sourceMemberships: outputMemberships,
                primarySourceID: file.primarySourceID,
                lastKnownPath: finalURL.path,
                fingerprint: outputFingerprint,
                ncmSourceIdentity: sourceFingerprint.identity
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
        let outputMemberships = Self.outputMemberships(
            sourceMemberships: record.sourceMemberships,
            outputName: outputURL.lastPathComponent
        )
        let locator: ReferencedFileLocator
        if let persisted = record.outputLocator {
            locator = persisted
        } else {
            locator = ReferencedFileLocator(
                fileBookmarkData: try bookmarkResolver.refreshBookmark(for: outputURL),
                sourceMemberships: outputMemberships,
                primarySourceID: record.sourcePrimaryID,
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

    func isReserved(url: URL, identity: ReferencedFileIdentity? = nil) async throws -> Bool {
        try await registry.isReserved(url: url, identity: identity)
    }

    private func writeAuthorization(for file: ImportDiscoveredFile) async throws -> NCMParentDirectoryAuthorization {
        if let sourceID = file.primarySourceID,
           sourceScope.authorizedRoots[sourceID] != nil {
            return NCMParentDirectoryAuthorization(
                directoryURL: file.url.deletingLastPathComponent(),
                bookmarkData: Data(),
                lease: .none,
                releasesLease: false
            )
        }
        return try await parentAuthorizer.authorizeParentDirectory(of: file.url)
    }

    nonisolated private static func outputFileName(
        sourceURL: URL,
        result: NCMConversionResult
    ) -> String {
        let metadataName = result.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return "\(String(safe.prefix(180))).\(result.format.rawValue)"
    }

    nonisolated private static func outputMemberships(
        sourceMemberships: [ReferencedSourceMembership],
        outputName: String
    ) -> [ReferencedSourceMembership] {
        sourceMemberships.map { membership in
            let parent = (membership.relativePath as NSString).deletingLastPathComponent
            let relative = parent.isEmpty ? outputName : (parent as NSString).appendingPathComponent(outputName)
            return ReferencedSourceMembership(sourceID: membership.sourceID, relativePath: relative)
        }
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
