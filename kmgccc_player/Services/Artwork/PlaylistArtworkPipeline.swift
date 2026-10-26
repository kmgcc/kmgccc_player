//
//  PlaylistArtworkPipeline.swift
//  myPlayer2
//
//  Unified artwork pipeline for row/header/effect rendering.
//

import AppKit
import Foundation

enum PlaylistArtworkVariant: String, Sendable {
    case rowLow
    case rowHigh
    case header
    case haloSeed
}

struct PlaylistArtworkRequest: Sendable {
    let sourceIdentity: String
    let variant: PlaylistArtworkVariant
    let artworkData: Data?
    let fileURL: URL?
    let pixelSize: CGSize

    nonisolated var cacheKey: String {
        "\(sourceIdentity)|\(variant.rawValue)|\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}

actor PlaylistArtworkPipeline {
    private final class MemoryEntry {
        let image: NSImage
        let fastCacheGeneration: UInt64

        init(_ image: NSImage, fastCacheGeneration: UInt64) {
            self.image = image
            self.fastCacheGeneration = fastCacheGeneration
        }
    }
    private let memoryCache = NSCache<NSString, MemoryEntry>()
    private let decodeGate = ArtworkDecodeGate(maxConcurrent: 10)
    private let derivativeStore: ArtworkDerivativeCacheStore
    private var memoryGeneration: UInt64 = 0
    /// One decode per cover, shared by the row that mounted and the prefetch
    /// walking ahead of it. Without this a fling decodes the same cover twice.
    private struct InFlightLoad: Sendable {
        let id: UUID
        let fastCacheGeneration: UInt64
        let task: Task<NSImage?, Never>
        var consumers: Set<UUID>
    }
    private var inFlightLoads: [String: InFlightLoad] = [:]

    init(derivativeStore: ArtworkDerivativeCacheStore) {
        self.derivativeStore = derivativeStore
        memoryCache.countLimit = 32
        memoryCache.totalCostLimit = 2 * 1024 * 1024
    }

    func preheat(requests: [PlaylistArtworkRequest]) async {
        for request in requests {
            guard !Task.isCancelled else { return }
            if cachedImage(for: request) != nil { continue }
            _ = await load(request)
        }
    }

    func cachedImage(for request: PlaylistArtworkRequest) -> NSImage? {
        cachedImage(for: request, fastCacheGeneration: FastArtworkMemoryCache.shared.currentGeneration())
    }

    private func cachedImage(for request: PlaylistArtworkRequest, fastCacheGeneration: UInt64) -> NSImage? {
        if let fast = FastArtworkMemoryCache.shared.image(forKey: request.cacheKey) {
            return fast
        }
        if let entry = memoryCache.object(forKey: request.cacheKey as NSString) {
            guard entry.fastCacheGeneration == fastCacheGeneration else {
                memoryCache.removeObject(forKey: request.cacheKey as NSString)
                return nil
            }
            guard FastArtworkMemoryCache.shared.store(
                entry.image,
                forKey: request.cacheKey,
                generation: fastCacheGeneration
            ) else { return nil }
            return entry.image
        }
        return nil
    }

    func load(
        _ request: PlaylistArtworkRequest,
        expectedFastCacheGeneration: UInt64? = nil
    ) async -> NSImage? {
        let fastCacheGeneration = FastArtworkMemoryCache.shared.currentGeneration()
        guard !Task.isCancelled,
              expectedFastCacheGeneration == nil || expectedFastCacheGeneration == fastCacheGeneration
        else { return nil }
        let requestGeneration = memoryGeneration
        if let cached = cachedImage(for: request, fastCacheGeneration: fastCacheGeneration) {
            return cached
        }

        guard !Task.isCancelled else { return nil }

        // A direct fast-cache clear may happen while a shared decode is still
        // running. A new generation must start its own job rather than adopt it.
        if let existing = inFlightLoads[request.cacheKey], existing.fastCacheGeneration != fastCacheGeneration {
            existing.task.cancel()
            inFlightLoads[request.cacheKey] = nil
        }
        let consumerID = UUID()
        let inFlight: InFlightLoad
        if var existing = inFlightLoads[request.cacheKey] {
            existing.consumers.insert(consumerID)
            inFlightLoads[request.cacheKey] = existing
            inFlight = existing
        } else {
            let task = Task { [weak self] () -> NSImage? in
                guard let self else { return nil }
                return await self.performLoad(request, generation: requestGeneration, fastCacheGeneration: fastCacheGeneration)
            }
            inFlight = InFlightLoad(id: UUID(), fastCacheGeneration: fastCacheGeneration, task: task, consumers: [consumerID])
            inFlightLoads[request.cacheKey] = inFlight
        }

        let image = await withTaskCancellationHandler {
            await inFlight.task.value
        } onCancel: {
            Task {
                await self.releaseConsumer(consumerID, cacheKey: request.cacheKey, loadID: inFlight.id)
            }
        }
        releaseConsumer(consumerID, cacheKey: request.cacheKey, loadID: inFlight.id)
        guard !Task.isCancelled, memoryGeneration == requestGeneration,
              FastArtworkMemoryCache.shared.currentGeneration() == fastCacheGeneration else { return nil }
        return image
    }

    private func releaseConsumer(_ consumerID: UUID, cacheKey: String, loadID: UUID) {
        // A cleared or cancelled job may finish after a new job took its key.
        guard var load = inFlightLoads[cacheKey], load.id == loadID else { return }
        load.consumers.remove(consumerID)
        if load.consumers.isEmpty {
            load.task.cancel()
            inFlightLoads[cacheKey] = nil
        } else {
            inFlightLoads[cacheKey] = load
        }
    }

    private func performLoad(
        _ request: PlaylistArtworkRequest,
        generation requestGeneration: UInt64,
        fastCacheGeneration: UInt64
    ) async -> NSImage? {
        guard !Task.isCancelled, memoryGeneration == requestGeneration,
              FastArtworkMemoryCache.shared.currentGeneration() == fastCacheGeneration else { return nil }
        if let cached = cachedImage(for: request, fastCacheGeneration: fastCacheGeneration) {
            return cached
        }

        let maxPixel = max(request.pixelSize.width, request.pixelSize.height)
        
        if maxPixel <= 160, let trackID = parseTrackID(from: request.sourceIdentity) {
            let checksum = request.artworkData.flatMap { ArtworkAssetStore.checksum(for: $0) } ?? 0
            if let snapshot = await ArtworkAssetStore.shared.get(
                trackID: trackID,
                artworkChecksum: checksum
            ),
               let thumbnail = snapshot.thumbnailImage {
                guard !Task.isCancelled, memoryGeneration == requestGeneration,
                      FastArtworkMemoryCache.shared.currentGeneration() == fastCacheGeneration else { return nil }
                memoryCache.setObject(
                    MemoryEntry(thumbnail, fastCacheGeneration: fastCacheGeneration),
                    forKey: request.cacheKey as NSString,
                    cost: max(1, Int(request.pixelSize.width * request.pixelSize.height * 4))
                )
                FastArtworkMemoryCache.shared.store(thumbnail, forKey: request.cacheKey, generation: fastCacheGeneration)
                return thumbnail
            }
        }

        guard let source = rowSource(for: request) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        // Acquire decode slot with cancellation support
        let (acquired, _) = await decodeGate.acquire()
        guard acquired else {
            // Cancelled while waiting for slot
            return nil
        }

        // Release on this call rather than through a new task: while a fling is
        // running the actor is busy, and deferred releases queued behind the
        // waiting loads would hand the slots out late.
        guard !Task.isCancelled else {
            await decodeGate.release()
            return nil
        }

        let image: NSImage?
        switch source {
        case .data(let data):
            image = await derivativeStore.image(
                for: request.cacheKey,
                artworkData: data,
                targetPixelSize: request.pixelSize
            )
        case .file(let fileURL):
            // Decode straight from the artwork file. The derivative store reads
            // its own cached copy first, so the original never has to be loaded
            // into memory just to look a row cover up.
            image = await derivativeStore.image(
                for: request.cacheKey,
                sourceURL: fileURL,
                targetPixelSize: request.pixelSize
            )
        }
        await decodeGate.release()

        guard !Task.isCancelled, memoryGeneration == requestGeneration,
              FastArtworkMemoryCache.shared.currentGeneration() == fastCacheGeneration, let image else {
            return nil
        }

        memoryCache.setObject(
            MemoryEntry(image, fastCacheGeneration: fastCacheGeneration),
            forKey: request.cacheKey as NSString,
            cost: max(1, Int(request.pixelSize.width * request.pixelSize.height * 4))
        )
        FastArtworkMemoryCache.shared.store(image, forKey: request.cacheKey, generation: fastCacheGeneration)

        return image
    }
    
    private func parseTrackID(from sourceIdentity: String) -> UUID? {
        guard sourceIdentity.hasPrefix("row-") else { return nil }
        let start = sourceIdentity.index(sourceIdentity.startIndex, offsetBy: 4)
        let uuidEnd = sourceIdentity.index(start, offsetBy: 36, limitedBy: sourceIdentity.endIndex)
        guard let uuidEnd else { return nil }
        let uuidString = String(sourceIdentity[start..<uuidEnd])
        return UUID(uuidString: uuidString)
    }

    /// Loads the requests in order. It runs inside a unit of the App background
    /// scheduler; the checkpoint between requests lets a more urgent unit take
    /// over and ends the prefetch when it is cancelled.
    nonisolated func prefetch(
        _ requests: [PlaylistArtworkRequest],
        context: BackgroundWorkContext
    ) async {
        for request in requests {
            guard (try? await context.checkpoint()) != nil else { return }
            _ = await self.load(request)
        }
    }

    nonisolated static func fastLookup(cacheKey: String) -> NSImage? {
        FastArtworkMemoryCache.shared.image(forKey: cacheKey)
    }

    func clearMemory() {
        memoryGeneration &+= 1
        for load in inFlightLoads.values {
            load.task.cancel()
        }
        inFlightLoads.removeAll()
        memoryCache.removeAllObjects()
        FastArtworkMemoryCache.shared.removeAll()
    }

    private enum RowArtworkSource {
        case data(Data)
        case file(URL)
    }

    /// Picks the cheapest still-usable source for a row cover. File artwork stays
    /// a URL so the decode runs from disk; only inline artwork is carried as data.
    private func rowSource(for request: PlaylistArtworkRequest) -> RowArtworkSource? {
        if let artworkData = request.artworkData, !artworkData.isEmpty {
            return .data(artworkData)
        }
        guard let fileURL = request.fileURL else { return nil }
        return .file(fileURL)
    }
}

extension PlaylistArtworkPipeline {
    nonisolated static func rowSourceIdentity(trackID: UUID, artworkData: Data?, artworkFileURL: URL? = nil) -> String {
        let checksum = ArtworkLoader.checksum(for: artworkData)
        let fileVersion = stableFileVersion(for: artworkFileURL)
        return "row-\(trackID.uuidString)-\(checksum)-\(fileVersion)"
    }

    private nonisolated static func stableFileVersion(for artworkFileURL: URL?) -> String {
        guard let artworkFileURL,
              let values = try? artworkFileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              )
        else {
            return "no-file"
        }
        let fileSize = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let modifiedNanos = Int64((modified * 1_000_000_000).rounded())
        return "\(artworkFileURL.lastPathComponent):\(fileSize):\(modifiedNanos)"
    }

    nonisolated static func rowLowRequest(
        trackID: UUID,
        artworkData: Data?,
        artworkFileURL: URL? = nil,
        artworkIdentity: String? = nil,
        logicalSize: CGFloat,
        scale: CGFloat
    ) -> PlaylistArtworkRequest {
        let side = max(22, logicalSize * 0.55) * max(1, scale)
        return PlaylistArtworkRequest(
            sourceIdentity: artworkIdentity ?? rowSourceIdentity(trackID: trackID, artworkData: artworkData, artworkFileURL: artworkFileURL),
            variant: .rowLow,
            artworkData: artworkData,
            fileURL: artworkFileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }

    nonisolated static func rowHighRequest(
        trackID: UUID,
        artworkData: Data?,
        artworkFileURL: URL? = nil,
        artworkIdentity: String? = nil,
        logicalSize: CGFloat,
        scale: CGFloat
    ) -> PlaylistArtworkRequest {
        let side = max(1, logicalSize) * max(1, scale)
        return PlaylistArtworkRequest(
            sourceIdentity: artworkIdentity ?? rowSourceIdentity(trackID: trackID, artworkData: artworkData, artworkFileURL: artworkFileURL),
            variant: .rowHigh,
            artworkData: artworkData,
            fileURL: artworkFileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }

    nonisolated static func headerRequest(
        artworkIdentity: String,
        artworkData: Data?,
        fileURL: URL?
    ) -> PlaylistArtworkRequest {
        PlaylistArtworkRequest(
            sourceIdentity: "header-\(artworkIdentity)",
            variant: .header,
            artworkData: artworkData,
            fileURL: fileURL,
            pixelSize: CGSize(width: 640, height: 640)
        )
    }

    nonisolated static func haloSeedRequest(
        artworkIdentity: String,
        artworkData: Data?,
        fileURL: URL?,
        pixelSide: Int = 192
    ) -> PlaylistArtworkRequest {
        let side = max(96, pixelSide)
        return PlaylistArtworkRequest(
            sourceIdentity: "halo-\(artworkIdentity)",
            variant: .haloSeed,
            artworkData: artworkData,
            fileURL: fileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }
}
