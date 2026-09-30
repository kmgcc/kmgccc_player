//
//  TrackArtworkCache.swift
//  myPlayer2
//
//  Unified local-track artwork cache for playback surfaces.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TrackArtworkSource: Sendable, Equatable {
    let trackID: UUID
    let artworkFileName: String?
    let artworkFileURL: URL?
    let inlineArtworkData: Data?
    let sourceKey: String

    nonisolated init?(
        trackID: UUID,
        artworkFileName: String?,
        artworkFileURL: URL?,
        inlineArtworkData: Data?
    ) {
        guard artworkFileURL != nil || inlineArtworkData?.isEmpty == false else { return nil }
        self.trackID = trackID
        self.artworkFileName = artworkFileName
        self.artworkFileURL = artworkFileURL
        self.inlineArtworkData = inlineArtworkData
        self.sourceKey = Self.makeSourceKey(
            trackID: trackID,
            artworkFileName: artworkFileName,
            artworkFileURL: artworkFileURL,
            inlineArtworkData: inlineArtworkData
        )
    }

    private nonisolated static func makeSourceKey(
        trackID: UUID,
        artworkFileName: String?,
        artworkFileURL: URL?,
        inlineArtworkData: Data?
    ) -> String {
        let version = "track-artwork-v2"
        if let inlineArtworkData, !inlineArtworkData.isEmpty {
            let checksum = ArtworkAssetStore.checksum(for: inlineArtworkData)
            return [
                version,
                ArtworkColorExtractor.cacheVersion,
                trackID.uuidString,
                artworkFileName ?? "inline",
                "\(inlineArtworkData.count)",
                "\(checksum)",
            ].joined(separator: "|")
        }
        if let artworkFileURL,
           let values = try? artworkFileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
           ) {
            let fileSize = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let modifiedNanos = Int64((modified * 1_000_000_000).rounded())
            let fileName = artworkFileName ?? artworkFileURL.lastPathComponent
            return [
                version,
                ArtworkColorExtractor.cacheVersion,
                trackID.uuidString,
                fileName,
                "\(fileSize)",
                "\(modifiedNanos)",
            ].joined(separator: "|")
        }

        let checksum = ArtworkAssetStore.checksum(for: inlineArtworkData)
        return [
            version,
            ArtworkColorExtractor.cacheVersion,
            trackID.uuidString,
            artworkFileName ?? "inline",
            "\(inlineArtworkData?.count ?? 0)",
            "\(checksum)",
        ].joined(separator: "|")
    }
}

extension Track {
    @MainActor
    func trackArtworkSource(fallbackData: Data? = nil) -> TrackArtworkSource? {
        let artworkFileURL = existingArtworkURL()
        let inlineArtworkData = fallbackData.flatMap { $0.isEmpty ? nil : $0 }
            ?? (artworkFileURL == nil ? artworkData : nil)
        return TrackArtworkSource(
            trackID: id,
            artworkFileName: artworkFileName,
            artworkFileURL: artworkFileURL,
            inlineArtworkData: inlineArtworkData
        )
    }
}

actor TrackArtworkCache {
    private static let maxOriginalDiskBytes: Int64 = DiskCacheBudget.trackOriginals.maxBytes
    private static let maxDerivativeDiskBytes: Int64 = DiskCacheBudget.trackDerivatives.maxBytes
    private static let maxCachedSourceDataBytes = 8 * 1024 * 1024

    private nonisolated let originalsRootURL: URL
    private nonisolated let derivativesRootURL: URL
    private let imageCache = NSCache<NSString, CachedArtworkImage>()
    private let sourceDataCache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    private var sourceDataTasks: [String: Task<Data?, Never>] = [:]
    private var imageTasks: [String: Task<NSImage?, Never>] = [:]
    private var sourceDataTaskIDs: [String: UUID] = [:]
    private var imageTaskIDs: [String: UUID] = [:]
    private var memoryGeneration: UInt64 = 0
    private var warmupInProgressKeys: Set<String> = []
    private var completedWarmupKeys: [String] = []
    private var completedWarmupKeySet: Set<String> = []
    private var didScheduleInitialDiskTrim = false
    private var diskWriteCounter = 0

    init(storage: LibraryStorageLocations) {
        self.originalsRootURL = storage.trackArtworkOriginalsURL
        self.derivativesRootURL = storage.trackArtworkDerivativesURL
        imageCache.countLimit = 16
        imageCache.totalCostLimit = 4 * 1024 * 1024
        sourceDataCache.countLimit = 8
        sourceDataCache.totalCostLimit = 2 * 1024 * 1024
        try? FileManager.default.createDirectory(at: originalsRootURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: derivativesRootURL, withIntermediateDirectories: true)
    }

    func thumbnail(
        for source: TrackArtworkSource,
        maxPixelSize: Int = 160,
        purpose: String = "ui"
    ) async -> NSImage? {
        await image(for: source, variant: "thumbnail", maxPixelSize: maxPixelSize, purpose: purpose)
    }

    func fullImage(
        for source: TrackArtworkSource,
        maxPixelSize: Int = 1_024,
        purpose: String = "ui"
    ) async -> NSImage? {
        await image(for: source, variant: "full", maxPixelSize: maxPixelSize, purpose: purpose)
    }

    func snapshot(
        for source: TrackArtworkSource,
        fullImageMaxPixelSize: Int = 1_024,
        purpose: String = "ui"
    ) async -> ArtworkAssetSnapshot? {
        let startedAt = Self.now()
        guard let data = await sourceData(for: source, purpose: purpose) else {
            Self.log(
                "disk miss",
                source: source,
                purpose: purpose,
                detail: "kind=snapshot elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
            )
            return nil
        }
        let metadata = await ArtworkAssetStore.shared.snapshotMetadata(
            trackID: source.trackID,
            artworkData: data
        )
        let fullImage = await fullImage(
            for: source,
            maxPixelSize: fullImageMaxPixelSize,
            purpose: purpose
        )
        Self.log(
            metadata != nil && fullImage != nil ? "memory hit" : "disk miss",
            source: source,
            purpose: purpose,
            detail: "kind=snapshot fullPx=\(fullImageMaxPixelSize) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
        )
        return metadata?.replacing(fullImage: fullImage)
    }

    func clearMemory() {
        memoryGeneration &+= 1
        sourceDataTasks.values.forEach { $0.cancel() }
        imageTasks.values.forEach { $0.cancel() }
        imageCache.removeAllObjects()
        sourceDataCache.removeAllObjects()
        sourceDataTasks.removeAll(keepingCapacity: false)
        imageTasks.removeAll(keepingCapacity: false)
        sourceDataTaskIDs.removeAll(keepingCapacity: false)
        imageTaskIDs.removeAll(keepingCapacity: false)
        warmupInProgressKeys.removeAll(keepingCapacity: false)
        completedWarmupKeys.removeAll(keepingCapacity: false)
        completedWarmupKeySet.removeAll(keepingCapacity: false)
    }

    @discardableResult
    nonisolated func preloadPlaybackArtwork(
        for sources: [TrackArtworkSource],
        reason: String = "playback"
    ) -> Task<Void, Never>? {
        var seen = Set<String>()
        let uniqueSources = sources.filter { source in
            seen.insert(source.sourceKey).inserted
        }
        guard !uniqueSources.isEmpty else { return nil }

        // `.utility` rather than `.background`: this warms the current track plus
        // the upcoming queue window (full 1400px image + colour analysis). At
        // `.background` QoS it can be starved long enough that the next track is
        // still cold when playback advances or the user skips, which surfaces as
        // a late cover / colour pop on the now-playing and fullscreen surfaces.
        return Task.detached(priority: .utility) {
            for source in uniqueSources {
                guard !Task.isCancelled else { return }
                await self.preloadPlaybackArtwork(for: source, reason: reason)
            }
        }
    }

    nonisolated func hasAnyDiskCache(for source: TrackArtworkSource) -> Bool {
        if let artworkFileURL = source.artworkFileURL,
           FileManager.default.fileExists(atPath: artworkFileURL.path) {
            return true
        }
        let originalURL = originalFileURL(for: source)
        if FileManager.default.fileExists(atPath: originalURL.path) {
            return true
        }
        return hasCachedDerivative(for: source, variant: "thumbnail", maxPixelSize: 160)
            || hasCachedDerivative(for: source, variant: "full", maxPixelSize: 1_400)
    }

    nonisolated func hasCachedDerivative(
        for source: TrackArtworkSource,
        variant: String,
        maxPixelSize: Int
    ) -> Bool {
        let imageKey = Self.imageKey(
            for: source,
            variant: variant,
            maxPixelSize: maxPixelSize
        )
        return FileManager.default.fileExists(atPath: derivativeFileURL(for: imageKey).path)
    }

    func sourceData(for source: TrackArtworkSource, purpose: String = "ui") async -> Data? {
        scheduleInitialDiskTrimIfNeeded()
        let requestGeneration = memoryGeneration

        if let cached = sourceDataCache.object(forKey: source.sourceKey as NSString) {
            Self.log(
                "memory hit",
                source: source,
                purpose: purpose,
                detail: "kind=raw bytes=\(cached.length)"
            )
            return cached as Data
        }

        if let task = sourceDataTasks[source.sourceKey] {
            Self.log(
                "in-flight coalesced",
                source: source,
                purpose: purpose,
                detail: "kind=raw"
            )
            let data = await task.value
            guard !Task.isCancelled else { return nil }
            if memoryGeneration == requestGeneration {
                cacheSourceData(data, for: source)
            }
            return data
        }

        let cachedURL = originalFileURL(for: source)
        let taskID = UUID()
        let task = Task.detached(priority: .utility) { [cachedURL] () -> Data? in
            guard !Task.isCancelled else { return nil }

            // 1. Direct stream from source artwork file on disk (no duplicate copy to originalsRootURL)
            if let sourceURL = source.artworkFileURL,
               FileManager.default.isReadableFile(atPath: sourceURL.path) {
                let fileStartedAt = Self.now()
                if let fileData = try? Data(contentsOf: sourceURL), !fileData.isEmpty {
                    Self.log(
                        "disk raw hit (source file)",
                        source: source,
                        purpose: purpose,
                        detail: "bytes=\(fileData.count) file=\(sourceURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: fileStartedAt)))"
                    )
                    return fileData
                }
            }

            // 2. Check cached original for inline data
            let diskStartedAt = Self.now()
            if let cachedData = try? Data(contentsOf: cachedURL), !cachedData.isEmpty {
                Self.touchItem(at: cachedURL)
                Self.log(
                    "disk raw hit",
                    source: source,
                    purpose: purpose,
                    detail: "bytes=\(cachedData.count) file=\(cachedURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: diskStartedAt)))"
                )
                return cachedData
            }

            // 3. Fallback for inline metadata tag data
            if let inline = source.inlineArtworkData, !inline.isEmpty {
                guard !Task.isCancelled else { return nil }
                let startedAt = Self.now()
                try? FileManager.default.createDirectory(
                    at: cachedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? inline.write(to: cachedURL, options: .atomic)
                Self.log(
                    "write raw cache",
                    source: source,
                    purpose: purpose,
                    detail: "source=inline bytes=\(inline.count) file=\(cachedURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
                )
                guard !Task.isCancelled else { return nil }
                return inline
            }

            Self.log(
                "disk miss",
                source: source,
                purpose: purpose,
                detail: "kind=raw file=\(cachedURL.lastPathComponent)"
            )
            return nil
        }

        sourceDataTasks[source.sourceKey] = task
        sourceDataTaskIDs[source.sourceKey] = taskID
        let data = await task.value
        if sourceDataTaskIDs[source.sourceKey] == taskID {
            sourceDataTasks[source.sourceKey] = nil
            sourceDataTaskIDs[source.sourceKey] = nil
        }
        guard !Task.isCancelled else { return nil }
        if memoryGeneration == requestGeneration {
            cacheSourceData(data, for: source)
        }
        if data != nil, source.inlineArtworkData != nil {
            recordDiskWriteAndTrimIfNeeded()
        }
        return data
    }

    private func image(
        for source: TrackArtworkSource,
        variant: String,
        maxPixelSize: Int,
        purpose: String
    ) async -> NSImage? {
        scheduleInitialDiskTrimIfNeeded()
        let requestGeneration = memoryGeneration

        let imageKey = Self.imageKey(for: source, variant: variant, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: imageKey as NSString)?.image {
            Self.log(
                "memory hit",
                source: source,
                imageKey: imageKey,
                purpose: purpose,
                detail: "kind=derivative variant=\(variant) px=\(max(1, maxPixelSize))"
            )
            return cached
        }

        let diskURL = derivativeFileURL(for: imageKey)
        let diskStartedAt = Self.now()
        if let diskImage = await Self.readImage(at: diskURL, maxPixelSize: maxPixelSize) {
            guard !Task.isCancelled else { return nil }
            if memoryGeneration == requestGeneration {
                setMemoryImage(diskImage, key: imageKey)
            }
            Self.touchItem(at: diskURL)
            Self.log(
                "disk derivative hit",
                source: source,
                imageKey: imageKey,
                purpose: purpose,
                detail: "variant=\(variant) px=\(max(1, maxPixelSize)) file=\(diskURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: diskStartedAt)))"
            )
            return diskImage
        }
        Self.log(
            "disk miss",
            source: source,
            imageKey: imageKey,
            purpose: purpose,
            detail: "kind=derivative variant=\(variant) px=\(max(1, maxPixelSize)) file=\(diskURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: diskStartedAt)))"
        )

        if let task = imageTasks[imageKey] {
            Self.log(
                "in-flight coalesced",
                source: source,
                imageKey: imageKey,
                purpose: purpose,
                detail: "kind=derivative variant=\(variant) px=\(max(1, maxPixelSize))"
            )
            return await task.value
        }

        let taskID = UUID()
        let taskGeneration = memoryGeneration
        let task = Task { [weak self] () -> NSImage? in
            guard let self else { return nil }
            guard let data = await self.sourceData(for: source, purpose: purpose) else { return nil }
            guard !Task.isCancelled else { return nil }
            let generateStartedAt = Self.now()
            let decodeTask = Task.detached(priority: .utility) { () -> NSImage? in
                guard !Task.isCancelled else { return nil }
                return autoreleasepool {
                    let image = Self.downsampledImage(data: data, maxPixelSize: maxPixelSize)
                    return Task.isCancelled ? nil : image
                }
            }
            let image = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            Self.log(
                "derivative generate",
                source: source,
                imageKey: imageKey,
                purpose: purpose,
                detail: "variant=\(variant) px=\(max(1, maxPixelSize)) result=\(image == nil ? "miss" : "hit") elapsedMs=\(Self.formatMs(Self.elapsedMs(since: generateStartedAt)))"
            )
            guard !Task.isCancelled, let image else { return nil }
            await self.persistImage(
                image,
                key: imageKey,
                diskURL: diskURL,
                generation: taskGeneration
            )
            return image
        }

        imageTasks[imageKey] = task
        imageTaskIDs[imageKey] = taskID
        let image = await task.value
        if imageTaskIDs[imageKey] == taskID {
            imageTasks[imageKey] = nil
            imageTaskIDs[imageKey] = nil
        }
        return image
    }

    private func preloadPlaybackArtwork(for source: TrackArtworkSource, reason: String) async {
        let warmupKey = "\(source.sourceKey)|playback-warmup-v1|thumb:160|full:1400"
        if completedWarmupKeySet.contains(warmupKey) {
            Self.log(
                "preload / warmup hit",
                source: source,
                purpose: "warmup",
                detail: "reason=\(reason) state=already-warmed"
            )
            return
        }
        if warmupInProgressKeys.contains(warmupKey) {
            Self.log(
                "in-flight coalesced",
                source: source,
                purpose: "warmup",
                detail: "kind=preload reason=\(reason)"
            )
            return
        }

        warmupInProgressKeys.insert(warmupKey)
        let startedAt = Self.now()
        let warmupGeneration = memoryGeneration
        defer {
            if memoryGeneration == warmupGeneration {
                warmupInProgressKeys.remove(warmupKey)
            }
        }

        guard await sourceData(for: source, purpose: "warmup") != nil else {
            Self.log(
                "preload / warmup miss",
                source: source,
                purpose: "warmup",
                detail: "reason=\(reason) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
            )
            return
        }

        guard !Task.isCancelled, memoryGeneration == warmupGeneration else { return }
        _ = await thumbnail(for: source, maxPixelSize: 160, purpose: "warmup")
        guard !Task.isCancelled, memoryGeneration == warmupGeneration else { return }
        _ = await snapshot(for: source, fullImageMaxPixelSize: 1_024, purpose: "warmup")
        guard !Task.isCancelled, memoryGeneration == warmupGeneration else { return }
        rememberCompletedWarmupKey(warmupKey)
        Self.log(
            "preload / warmup hit",
            source: source,
            purpose: "warmup",
            detail: "reason=\(reason) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
        )
    }

    private func persistImage(
        _ image: NSImage,
        key: String,
        diskURL: URL,
        generation: UInt64
    ) {
        guard memoryGeneration == generation, !Task.isCancelled else { return }
        setMemoryImage(image, key: key)
        guard let encoded = Self.encodedImageData(for: image) else { return }
        let startedAt = Self.now()
        try? fileManager.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? encoded.write(to: diskURL, options: .atomic)
        recordDiskWriteAndTrimIfNeeded()
        Self.log(
            "write derivative cache",
            source: nil,
            imageKey: key,
            purpose: "cache",
            detail: "bytes=\(encoded.count) file=\(diskURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
        )
    }

    private func scheduleInitialDiskTrimIfNeeded() {
        guard !didScheduleInitialDiskTrim else { return }
        didScheduleInitialDiskTrim = true
        Task { [weak self] in
            await self?.trimDiskCaches()
        }
    }

    private func recordDiskWriteAndTrimIfNeeded() {
        diskWriteCounter += 1
        guard diskWriteCounter.isMultiple(of: 16) else { return }
        trimDiskCaches()
    }

    private func trimDiskCaches() {
        let originalResult = DiskCacheRetention.trim(
            at: originalsRootURL,
            maxBytes: Self.maxOriginalDiskBytes,
            targetFraction: DiskCacheBudget.trackOriginals.targetFraction,
            maxAge: DiskCacheBudget.trackOriginals.maxAge
        )
        let derivativeResult = DiskCacheRetention.trim(
            at: derivativesRootURL,
            maxBytes: Self.maxDerivativeDiskBytes,
            targetFraction: DiskCacheBudget.trackDerivatives.targetFraction,
            maxAge: DiskCacheBudget.trackDerivatives.maxAge
        )
        let removedFileCount = originalResult.removedFileCount + derivativeResult.removedFileCount
        let removedBytes = originalResult.removedBytes + derivativeResult.removedBytes
        guard removedFileCount > 0 else { return }
        Log.debug(
            "[TrackArtworkCache] disk trim removedFiles=\(removedFileCount) removedBytes=\(removedBytes)",
            category: .perf
        )
    }

    private func cacheSourceData(_ data: Data?, for source: TrackArtworkSource) {
        guard let data,
              !data.isEmpty,
              data.count <= Self.maxCachedSourceDataBytes
        else { return }
        sourceDataCache.setObject(
            data as NSData,
            forKey: source.sourceKey as NSString,
            cost: data.count
        )
    }

    private func rememberCompletedWarmupKey(_ key: String) {
        guard completedWarmupKeySet.insert(key).inserted else { return }
        completedWarmupKeys.append(key)
        let limit = 128
        if completedWarmupKeys.count > limit {
            let overflow = completedWarmupKeys.count - limit
            for removed in completedWarmupKeys.prefix(overflow) {
                completedWarmupKeySet.remove(removed)
            }
            completedWarmupKeys.removeFirst(overflow)
        }
    }

    private func setMemoryImage(_ image: NSImage, key: String) {
        imageCache.setObject(
            CachedArtworkImage(image),
            forKey: key as NSString,
            cost: Self.estimatedCost(for: image)
        )
    }

    private nonisolated static func imageKey(
        for source: TrackArtworkSource,
        variant: String,
        maxPixelSize: Int
    ) -> String {
        "\(source.sourceKey)|\(variant)|px:\(max(1, maxPixelSize))"
    }

    private nonisolated func originalFileURL(for source: TrackArtworkSource) -> URL {
        originalsRootURL.appendingPathComponent("\(Self.stableDigest(source.sourceKey)).img")
    }

    private nonisolated func derivativeFileURL(for imageKey: String) -> URL {
        derivativesRootURL.appendingPathComponent("\(Self.stableDigest(imageKey)).png")
    }

    private nonisolated static func readData(at url: URL) async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            return try? Data(contentsOf: url)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func readImage(at url: URL, maxPixelSize: Int) async -> NSImage? {
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                guard FileManager.default.fileExists(atPath: url.path),
                      let source = CGImageSourceCreateWithURL(
                        url as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary
                      )
                else {
                    return nil
                }
                let image = downsampledImage(source: source, maxPixelSize: maxPixelSize)
                return Task.isCancelled ? nil : image
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func touchItem(at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private nonisolated static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
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

    private nonisolated static func encodedImageData(for image: NSImage) -> Data? {
        ArtworkDataNormalizer.encodedDerivativeData(for: image, lossyCompressionQuality: 0.85)
    }

    private nonisolated static func pngData(for image: NSImage) -> Data? {
        encodedImageData(for: image)
    }

    private nonisolated static func estimatedCost(for image: NSImage) -> Int {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private nonisolated static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private nonisolated static func elapsedMs(since start: TimeInterval) -> Double {
        (now() - start) * 1000
    }

    private nonisolated static func formatMs(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private nonisolated static func log(
        _ event: String,
        source: TrackArtworkSource?,
        imageKey: String? = nil,
        purpose: String,
        detail: String
    ) {
        guard LogConfig.trackArtworkCacheVerbose else { return }
        let sourceToken = source.map { stableDigest($0.sourceKey) } ?? "none"
        let imageToken = imageKey.map { stableDigest($0) } ?? "none"
        let trackToken = source?.trackID.uuidString.prefix(8) ?? "none"
        Log.info(
            "[TrackArtworkCache] event=\(event) purpose=\(purpose) track=\(trackToken) sourceKey=\(sourceToken) imageKey=\(imageToken) \(detail)",
            category: .perf
        )
    }

    private nonisolated static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
