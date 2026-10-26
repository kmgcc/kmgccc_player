import AVFoundation
import Foundation

nonisolated struct ValidatedMotionVideo: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let fileExtension: String

    static func validateDuration(_ duration: Double) throws {
        guard duration.isFinite, duration > 0 else { throw MotionVideoImportError.unplayable }
        guard duration <= 1_200 else { throw MotionVideoImportError.tooLong }
    }
}

nonisolated enum MotionVideoImportError: LocalizedError {
    case unplayable, tooLong

    var errorDescription: String? {
        switch self {
        case .unplayable: "请选择可播放的视频。"
        case .tooLong: "视频时长须在20分钟以内。"
        }
    }
}

/// Holds the picker grant only for the lifetime of an unsaved editor selection.
nonisolated final class MotionVideoImportSelection: Sendable {
    let url: URL
    private let scoped: Bool

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

extension MusicEnrichmentService {
    func validateMotionVideo(from url: URL) async throws -> ValidatedMotionVideo {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { throw MotionVideoImportError.unplayable }
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw MotionVideoImportError.unplayable }
            let duration = try await asset.load(.duration).seconds
            try ValidatedMotionVideo.validateDuration(duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw MotionVideoImportError.unplayable
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let display = size.applying(transform)
            guard display.width.isFinite, display.height.isFinite,
                  abs(display.width) > 0, abs(display.height) > 0 else { throw MotionVideoImportError.unplayable }
            return ValidatedMotionVideo(
                duration: duration, width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()),
                fileExtension: url.pathExtension.lowercased()
            )
        } catch is CancellationError { throw CancellationError() }
        catch let error as MotionVideoImportError { throw error }
        catch {
            Log.warning("[MusicEnrichment] event=import-validation-failed errorType=\(String(describing: type(of: error)))", category: .library)
            throw MotionVideoImportError.unplayable
        }
    }

    func importMotionVideo(from url: URL, for query: MusicEnrichmentQuery, scope: MotionArtworkScope = .track) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        try Task.checkCancellation()
        if scope == .album, try await importAlbumMotionVideo(from: url, for: query) {
            return try await clearMotion(for: query, resumeAutomatic: true)
        }
        return try await trackIndependent(Task { try await self.performMotionVideoImport(from: url, for: query) })
    }

    private func performMotionVideoImport(from url: URL, for query: MusicEnrichmentQuery) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let validated = try await validateMotionVideo(from: url)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let expectedGeneration = generation
        resetMotionSelectionTasks(for: query.key)
        let identity = "importedVideo:\(UUID().uuidString)"
        let descriptor = MotionArtworkDescriptor(kind: "square", url: identity, width: validated.width, height: validated.height)
        guard let imported = try await store.importMotion(
            from: url, descriptor: descriptor, startTime: 0, duration: validated.duration,
            queryKey: query.key, fileExtension: validated.fileExtension
        ) else { throw CancellationError() }
        var tall = imported
        tall.kind = "tall"
        let assets = [imported, tall]
        let candidate = MusicEnrichmentResult(source: "manualImport", motion: [
            descriptor,
            MotionArtworkDescriptor(kind: "tall", url: identity, width: validated.width, height: validated.height)
        ])
        let record = try await store.updateRecord(key: query.key, fallbackQuery: query, alignQuery: true) { record in
            try Task.checkCancellation()
            record.manualMotionSelection = candidate
            record.assets = assets
            record.query.storedMotionArtwork = nil
            record.albumMotionIdentity = nil
        }
        let snapshot = await store.snapshot(record)
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        if currentKey == query.key, generation == expectedGeneration {
            currentRecord = record
            await publish(generation: expectedGeneration, persist: false)
        } else if currentKey != query.key { onSnapshot?(snapshot) }
        return snapshot
    }
}
