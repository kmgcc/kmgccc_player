//
//  TrackArtworkCache.swift
//  myPlayer2
//
//  Unified local-track artwork cache for playback surfaces.
//

import AppKit
import Foundation
import ImageIO

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
        let version = "track-artwork-v1"
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
        TrackArtworkSource(
            trackID: id,
            artworkFileName: artworkFileName,
            artworkFileURL: resolvedArtworkURL(),
            inlineArtworkData: fallbackData ?? artworkData
        )
    }
}

actor TrackArtworkCache {
    static let shared = TrackArtworkCache(
        storage: StorageLocations.scoped(to: LocalLibraryPaths.capturedPaths())
    )

    private nonisolated let originalsRootURL: URL
    private nonisolated let derivativesRootURL: URL
    private let imageCache = NSCache<NSString, CachedArtworkImage>()
    private let sourceDataCache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    private var sourceDataTasks: [String: Task<Data?, Never>] = [:]
    private var imageTasks: [String: Task<NSImage?, Never>] = [:]
    private var warmupInProgressKeys: Set<String> = []
    private var completedWarmupKeys: [String] = []
    private var completedWarmupKeySet: Set<String> = []

    init(storage: LibraryStorageLocations) {
        self.originalsRootURL = storage.trackArtworkOriginalsURL
        self.derivativesRootURL = storage.trackArtworkDerivativesURL
        imageCache.countLimit = 256
        imageCache.totalCostLimit = 96 * 1024 * 1024
        sourceDataCache.countLimit = 192
        sourceDataCache.totalCostLimit = 64 * 1024 * 1024
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
        maxPixelSize: Int = 1_400,
        purpose: String = "ui"
    ) async -> NSImage? {
        await image(for: source, variant: "full", maxPixelSize: maxPixelSize, purpose: purpose)
    }

    func snapshot(
        for source: TrackArtworkSource,
        fullImageMaxPixelSize: Int = 1_400,
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
        imageCache.removeAllObjects()
        sourceDataCache.removeAllObjects()
        sourceDataTasks.removeAll()
        imageTasks.removeAll()
        warmupInProgressKeys.removeAll()
        completedWarmupKeys.removeAll()
        completedWarmupKeySet.removeAll()
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
            cacheSourceData(data, for: source)
            return data
        }

        let cachedURL = originalFileURL(for: source)
        let diskStartedAt = Self.now()
        if let cachedData = await Self.readData(at: cachedURL), !cachedData.isEmpty {
            cacheSourceData(cachedData, for: source)
            touchItem(at: cachedURL)
            Self.log(
                "disk raw hit",
                source: source,
                purpose: purpose,
                detail: "bytes=\(cachedData.count) file=\(cachedURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: diskStartedAt)))"
            )
            return cachedData
        }
        Self.log(
            "disk miss",
            source: source,
            purpose: purpose,
            detail: "kind=raw file=\(cachedURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: diskStartedAt)))"
        )

        let task = Task.detached(priority: .utility) { [cachedURL] () -> Data? in
            if let inline = source.inlineArtworkData, !inline.isEmpty {
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
                return inline
            }

            let fallbackStartedAt = Self.now()
            guard let sourceURL = source.artworkFileURL,
                  let data = try? Data(contentsOf: sourceURL),
                  !data.isEmpty
            else {
                Self.log(
                    "sidecar / audio file fallback",
                    source: source,
                    purpose: purpose,
                    detail: "result=miss elapsedMs=\(Self.formatMs(Self.elapsedMs(since: fallbackStartedAt)))"
                )
                return nil
            }
            Self.log(
                "sidecar / audio file fallback",
                source: source,
                purpose: purpose,
                detail: "result=hit bytes=\(data.count) name=\(sourceURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: fallbackStartedAt)))"
            )

            let writeStartedAt = Self.now()
            try? FileManager.default.createDirectory(
                at: cachedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cachedURL, options: .atomic)
            Self.log(
                "write raw cache",
                source: source,
                purpose: purpose,
                detail: "source=file bytes=\(data.count) file=\(cachedURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: writeStartedAt)))"
            )
            return data
        }

        sourceDataTasks[source.sourceKey] = task
        let data = await task.value
        sourceDataTasks[source.sourceKey] = nil
        cacheSourceData(data, for: source)
        return data
    }

    private func image(
        for source: TrackArtworkSource,
        variant: String,
        maxPixelSize: Int,
        purpose: String
    ) async -> NSImage? {
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
            setMemoryImage(diskImage, key: imageKey)
            touchItem(at: diskURL)
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

        let task = Task { [weak self] () -> NSImage? in
            guard let self else { return nil }
            guard let data = await self.sourceData(for: source, purpose: purpose) else { return nil }
            let generateStartedAt = Self.now()
            let image = await Task.detached(priority: .utility) {
                Self.downsampledImage(data: data, maxPixelSize: maxPixelSize)
            }.value
            Self.log(
                "derivative generate",
                source: source,
                imageKey: imageKey,
                purpose: purpose,
                detail: "variant=\(variant) px=\(max(1, maxPixelSize)) result=\(image == nil ? "miss" : "hit") elapsedMs=\(Self.formatMs(Self.elapsedMs(since: generateStartedAt)))"
            )
            guard let image else { return nil }
            await self.persistImage(image, key: imageKey, diskURL: diskURL)
            return image
        }

        imageTasks[imageKey] = task
        let image = await task.value
        imageTasks[imageKey] = nil
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
        defer {
            warmupInProgressKeys.remove(warmupKey)
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

        _ = await thumbnail(for: source, maxPixelSize: 160, purpose: "warmup")
        _ = await snapshot(for: source, fullImageMaxPixelSize: 1_400, purpose: "warmup")
        rememberCompletedWarmupKey(warmupKey)
        Self.log(
            "preload / warmup hit",
            source: source,
            purpose: "warmup",
            detail: "reason=\(reason) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
        )
    }

    private func persistImage(_ image: NSImage, key: String, diskURL: URL) {
        setMemoryImage(image, key: key)
        guard let png = Self.pngData(for: image) else { return }
        let startedAt = Self.now()
        try? fileManager.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? png.write(to: diskURL, options: .atomic)
        Self.log(
            "write derivative cache",
            source: nil,
            imageKey: key,
            purpose: "cache",
            detail: "bytes=\(png.count) file=\(diskURL.lastPathComponent) elapsedMs=\(Self.formatMs(Self.elapsedMs(since: startedAt)))"
        )
    }

    private func cacheSourceData(_ data: Data?, for source: TrackArtworkSource) {
        guard let data, !data.isEmpty else { return }
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
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    private nonisolated static func readImage(at url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  )
            else {
                return nil
            }
            return downsampledImage(source: source, maxPixelSize: maxPixelSize)
        }.value
    }

    private func touchItem(at url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
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

    private nonisolated static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
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
