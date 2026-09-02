//
//  ArtworkAssetStore.swift
//  myPlayer2
//
//  kmgccc_player - Thread-safe artwork asset caching store
//

import AppKit
import Foundation
import ImageIO

nonisolated private final class ArtworkOperationState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var result: Value?
    private var continuation: CheckedContinuation<Value?, Never>?

    func wait() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let result = self.result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Value?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

actor ArtworkAssetStore {
    static let shared = ArtworkAssetStore()

    private let cache: NSCache<NSString, ArtworkAssetSnapshot> = {
        let cache = NSCache<NSString, ArtworkAssetSnapshot>()
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private let fullImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // The playback preheat warms current + next2 + prev1 (4 hydrated full
        // images); `countLimit = 2` evicted most of that window immediately, so
        // the next track was usually cold again by the time it was displayed.
        cache.countLimit = 6
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var inProgressTokens: [String: UUID] = [:]
    private var waitingContinuations: [String: [UUID: CheckedContinuation<ArtworkAssetSnapshot?, Never>]] = [:]
    private var metadataGeneration: UInt64 = 0
    private var fullImageInProgressTokens: [String: UUID] = [:]
    private var fullImageWaitingContinuations: [String: [UUID: CheckedContinuation<NSImage?, Never>]] = [:]
    private var fullImageGeneration: UInt64 = 0
    
    func clearCache() {
        cache.removeAllObjects()
        fullImageCache.removeAllObjects()
        metadataGeneration &+= 1
        inProgressTokens.removeAll()
        resumeAllMetadataWaiters(returning: nil)
        fullImageGeneration &+= 1
        fullImageInProgressTokens.removeAll()
        resumeAllFullImageWaiters(returning: nil)
    }

    func purgeHydratedImages() {
        fullImageGeneration &+= 1
        fullImageCache.removeAllObjects()
        fullImageInProgressTokens.removeAll()
        resumeAllFullImageWaiters(returning: nil)
    }

    func clearTrackDeletionResidue() {
        purgeHydratedImages()
    }
    
    nonisolated static func checksum(for data: Data?) -> UInt64 {
        guard let data, !data.isEmpty else { return 0 }
        return computeChecksum(data)
    }
    
    func get(trackID: UUID, artworkChecksum: UInt64) -> ArtworkAssetSnapshot? {
        let key = ArtworkAssetSnapshot.cacheKey(trackID: trackID, artworkChecksum: artworkChecksum)
        return cache.object(forKey: key as NSString)
    }
    
    func snapshot(
        trackID: UUID,
        artworkData: Data,
        fullImageMaxPixelSize: Int = 1_400
    ) async -> ArtworkAssetSnapshot? {
        let checksum = Self.computeChecksum(artworkData)
        let snapshot = await snapshotMetadata(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: checksum
        )

        return await hydrateSnapshot(
            snapshot,
            artworkData: artworkData,
            fullImageMaxPixelSize: fullImageMaxPixelSize
        )
    }

    func renderingFallbackSnapshot(
        trackID: UUID,
        fullImageMaxPixelSize: Int = 1_400
    ) async -> ArtworkAssetSnapshot? {
        guard let fallbackData = ArtworkRenderingFallback.data(for: trackID) else {
            return nil
        }
        return await snapshot(
            trackID: trackID,
            artworkData: fallbackData,
            fullImageMaxPixelSize: fullImageMaxPixelSize
        )
    }

    func snapshotMetadata(trackID: UUID, artworkData: Data) async -> ArtworkAssetSnapshot? {
        let checksum = Self.computeChecksum(artworkData)
        return await snapshotMetadata(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: checksum
        )
    }
    
    func cache(_ snapshot: ArtworkAssetSnapshot) {
        let metadataSnapshot = snapshot.replacing(fullImage: nil)
        let thumbnailCost = metadataSnapshot.thumbnailImage.flatMap(Self.estimatedCost(for:)) ?? 0
        let paletteCost = (snapshot.palette.count + snapshot.richPalette.count) * 64
        let cost = thumbnailCost + paletteCost
        cache.setObject(metadataSnapshot, forKey: metadataSnapshot.cacheKey as NSString, cost: cost)

        if let fullImage = snapshot.fullImage {
            fullImageCache.setObject(
                fullImage,
                forKey: snapshot.cacheKey as NSString,
                cost: Self.estimatedCost(for: fullImage)
            )
        }
    }
    
    func getOrCreate(
        trackID: UUID,
        artworkData: Data,
        artworkChecksum: UInt64,
        extract: @Sendable @escaping (Data, UInt64) async -> ArtworkAssetSnapshot?
    ) async -> ArtworkAssetSnapshot? {
        let key = ArtworkAssetSnapshot.cacheKey(trackID: trackID, artworkChecksum: artworkChecksum)

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        
        if inProgressTokens[key] != nil {
            return await waitForMetadataResult(for: key)
        }
        
        let operationToken = UUID()
        inProgressTokens[key] = operationToken
        let generation = metadataGeneration
        var result: ArtworkAssetSnapshot?
        defer {
            finishMetadataExtraction(
                for: key,
                operationToken: operationToken,
                generation: generation,
                result: result
            )
        }

        result = await Self.runBounded(
            timeoutNanoseconds: 15_000_000_000
        ) {
            await extract(artworkData, artworkChecksum)
        }
        
        return result
    }

    private func hydrateSnapshot(
        _ snapshot: ArtworkAssetSnapshot?,
        artworkData: Data,
        fullImageMaxPixelSize: Int
    ) async -> ArtworkAssetSnapshot? {
        guard let snapshot else { return nil }
        if snapshot.fullImage != nil { return snapshot }

        let hydratedKey = "\(snapshot.cacheKey)|full:\(max(1, fullImageMaxPixelSize))"
        let key = hydratedKey as NSString
        if let cachedFullImage = fullImageCache.object(forKey: key) {
            return snapshot.replacing(fullImage: cachedFullImage)
        }

        if fullImageInProgressTokens[hydratedKey] != nil {
            let image = await waitForFullImage(for: hydratedKey)
            return snapshot.replacing(fullImage: image)
        }

        let operationToken = UUID()
        fullImageInProgressTokens[hydratedKey] = operationToken
        let generation = fullImageGeneration
        var fullImage: NSImage?
        defer {
            finishFullImageExtraction(
                for: hydratedKey,
                operationToken: operationToken,
                cacheKey: key,
                generation: generation,
                result: fullImage
            )
        }

        fullImage = await Self.runBounded(timeoutNanoseconds: 10_000_000_000) {
            Self.downsampledImage(
                data: artworkData,
                maxPixelSize: max(1, fullImageMaxPixelSize)
            )
        }

        return snapshot.replacing(fullImage: fullImage)
    }

    private func waitForMetadataResult(for key: String) async -> ArtworkAssetSnapshot? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waitingContinuations[key, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelMetadataWaiter(for: key, waiterID: waiterID)
            }
        }
    }

    private func waitForFullImage(for key: String) async -> NSImage? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                fullImageWaitingContinuations[key, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelFullImageWaiter(for: key, waiterID: waiterID)
            }
        }
    }

    private func finishMetadataExtraction(
        for key: String,
        operationToken: UUID,
        generation: UInt64,
        result: ArtworkAssetSnapshot?
    ) {
        guard inProgressTokens[key] == operationToken else { return }
        let finalResult = generation == metadataGeneration ? result : nil
        if let finalResult {
            cache(finalResult)
        }
        inProgressTokens.removeValue(forKey: key)
        resumeMetadataWaiters(for: key, returning: finalResult)
    }

    private func finishFullImageExtraction(
        for key: String,
        operationToken: UUID,
        cacheKey: NSString,
        generation: UInt64,
        result: NSImage?
    ) {
        guard fullImageInProgressTokens[key] == operationToken else { return }
        let finalResult = generation == fullImageGeneration ? result : nil
        if let finalResult {
            fullImageCache.setObject(
                finalResult,
                forKey: cacheKey,
                cost: Self.estimatedCost(for: finalResult)
            )
        }
        fullImageInProgressTokens.removeValue(forKey: key)
        resumeFullImageWaiters(for: key, returning: finalResult)
    }

    private func cancelMetadataWaiter(for key: String, waiterID: UUID) {
        guard var waiters = waitingContinuations[key],
              let continuation = waiters.removeValue(forKey: waiterID)
        else { return }

        if waiters.isEmpty {
            waitingContinuations.removeValue(forKey: key)
        } else {
            waitingContinuations[key] = waiters
        }
        continuation.resume(returning: nil)
    }

    private func cancelFullImageWaiter(for key: String, waiterID: UUID) {
        guard var waiters = fullImageWaitingContinuations[key],
              let continuation = waiters.removeValue(forKey: waiterID)
        else { return }

        if waiters.isEmpty {
            fullImageWaitingContinuations.removeValue(forKey: key)
        } else {
            fullImageWaitingContinuations[key] = waiters
        }
        continuation.resume(returning: nil)
    }

    private func resumeMetadataWaiters(
        for key: String,
        returning result: ArtworkAssetSnapshot?
    ) {
        guard let waiters = waitingContinuations.removeValue(forKey: key) else { return }
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func resumeAllMetadataWaiters(returning result: ArtworkAssetSnapshot?) {
        let waiters = waitingContinuations.values.flatMap { $0.values }
        waitingContinuations.removeAll()
        for continuation in waiters {
            continuation.resume(returning: result)
        }
    }

    private func resumeFullImageWaiters(for key: String, returning result: NSImage?) {
        guard let waiters = fullImageWaitingContinuations.removeValue(forKey: key) else { return }
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func resumeAllFullImageWaiters(returning result: NSImage?) {
        let waiters = fullImageWaitingContinuations.values.flatMap { $0.values }
        fullImageWaitingContinuations.removeAll()
        for continuation in waiters {
            continuation.resume(returning: result)
        }
    }

    private func snapshotMetadata(
        trackID: UUID,
        artworkData: Data,
        artworkChecksum: UInt64
    ) async -> ArtworkAssetSnapshot? {
        await getOrCreate(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: artworkChecksum
        ) { data, checksum in
            Self.makeSnapshot(trackID: trackID, artworkData: data, checksum: checksum)
        }
    }

    private nonisolated static func runBounded<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        let state = ArtworkOperationState<Value>()
        let operationTask = Task.detached(priority: .utility) {
            state.finish(await operation())
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            state.finish(nil)
        }

        let result = await withTaskCancellationHandler {
            await state.wait()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            state.finish(nil)
        }
        operationTask.cancel()
        timeoutTask.cancel()
        return result
    }
    
    private nonisolated static func makeSnapshot(
        trackID: UUID,
        artworkData: Data,
        checksum: UInt64
    ) -> ArtworkAssetSnapshot? {
        guard !artworkData.isEmpty else { return nil }

        guard
            let imageSource = CGImageSourceCreateWithData(
                artworkData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let thumbnailImage = downsampledImage(source: imageSource, maxPixelSize: 160)
        let analysisSample = ArtworkColorExtractor.sampledBitmap(from: artworkData, side: 72)
        let analysis =
            analysisSample.flatMap {
                ArtworkColorExtractor.analyzeSyntheticSample(pixels: $0.pixels, side: $0.side)
            }
            ?? ArtworkColorExtractor.analyze(from: artworkData)
        let extractedPalette =
            analysisSample.map { ArtworkColorExtractor.uiThemePalette(from: $0, targetCount: 4) }
            ?? []
        let extractedRichPalette =
            analysisSample.map { ArtworkColorExtractor.uiThemePaletteRich(from: $0, targetCount: 6) }
            ?? []
        let palette = analysis?.displayPalette.isEmpty == false
            ? (analysis?.displayPalette ?? extractedPalette)
            : extractedPalette
        let richPalette = analysis?.richPalette.isEmpty == false
            ? (analysis?.richPalette ?? extractedRichPalette)
            : extractedRichPalette
        let accentColor = palette.first
        let averageColor =
            analysisSample.flatMap { ArtworkColorExtractor.averageColor(from: $0) }
            ?? ArtworkColorExtractor.averageColor(from: artworkData)
        let dominantColor = analysis?.primaryHueSourceColor ?? accentColor ?? averageColor

        return ArtworkAssetSnapshot(
            trackID: trackID,
            artworkChecksum: checksum,
            thumbnailImage: thumbnailImage,
            fullImage: nil,
            dominantColor: dominantColor,
            accentColor: accentColor,
            palette: palette,
            richPalette: richPalette,
            averageColor: averageColor,
            analysis: analysis
        )
    }
    
    private nonisolated static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func downsampledImage(
        source: CGImageSource,
        maxPixelSize: Int
    ) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private nonisolated static func estimatedCost(for image: NSImage) -> Int {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage.bytesPerRow * cgImage.height
        }

        return Int(image.size.width * image.size.height * 4)
    }
    
    private nonisolated static func computeChecksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
}
