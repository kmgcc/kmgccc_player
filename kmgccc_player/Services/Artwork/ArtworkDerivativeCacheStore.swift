//
//  ArtworkDerivativeCacheStore.swift
//  myPlayer2
//
//  Multi-size artwork derivative cache (memory + disk cache directory).
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class ArtworkDerivativeImageBox: NSObject {
    let image: NSImage

    nonisolated init(image: NSImage) {
        self.image = image
    }
}

actor ArtworkDerivativeCacheStore {
    private static let touchInterval: TimeInterval = 6 * 3600

    private let memoryCache = NSCache<NSString, ArtworkDerivativeImageBox>()
    private let fileManager = FileManager.default
    private let maxDiskBytes: Int64 = DiskCacheBudget.playlistDerivatives.maxBytes
    /// Covers decode in parallel here. A fling asks for a screenful per second
    /// and the sources are large JPEGs, so a narrow gate turned every scroll
    /// into a queue the rows were recycled before.
    private let decodeGate = ArtworkDecodeGate(maxConcurrent: 8)
    private var writeCounter = 0
    private var didScheduleInitialDiskTrim = false
    private var memoryGeneration: UInt64 = 0
    private nonisolated let diskRootURL: URL

    init(diskRootURL: URL) {
        self.diskRootURL = diskRootURL
        memoryCache.countLimit = 32
        memoryCache.totalCostLimit = 4 * 1024 * 1024

        try? fileManager.createDirectory(at: diskRootURL, withIntermediateDirectories: true)
    }

    func image(
        for cacheKey: String,
        artworkData: Data,
        targetPixelSize: CGSize
    ) async -> NSImage? {
        scheduleInitialDiskTrimIfNeeded()
        let requestGeneration = memoryGeneration

        if let memImage = memoryCache.object(forKey: cacheKey as NSString)?.image {
            return memImage
        }

        let diskURL = fileURL(for: cacheKey)
        let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
        if let diskImage = await readCachedImage(at: diskURL, maxPixelSize: maxPixel) {
            guard !Task.isCancelled, memoryGeneration == requestGeneration else { return nil }
            setMemoryImage(diskImage, cacheKey: cacheKey)
            touchItem(at: diskURL)
            return diskImage
        }

        let (acquired, _) = await decodeGate.acquire()
        guard acquired else { return nil }
        guard !Task.isCancelled, memoryGeneration == requestGeneration else {
            await decodeGate.release()
            return nil
        }
        let token = FirstUseHitchDiagnostics.begin(
            "ArtworkDerivative.decode",
            detail: "target=\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"
        )
        let decodeTask = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                let image = downsampledImage(data: artworkData, targetPixelSize: targetPixelSize)
                return Task.isCancelled ? nil : image
            }
        }
        let decoded = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await decodeGate.release()
        FirstUseHitchDiagnostics.end(token, detail: "success=\(decoded != nil)")
        guard !Task.isCancelled, memoryGeneration == requestGeneration, let decoded else { return nil }

        setMemoryImage(decoded, cacheKey: cacheKey)
        persist(image: decoded, to: diskURL)
        return decoded
    }

    func image(
        for cacheKey: String,
        sourceURL: URL,
        targetPixelSize: CGSize
    ) async -> NSImage? {
        scheduleInitialDiskTrimIfNeeded()
        let requestGeneration = memoryGeneration

        if let memImage = memoryCache.object(forKey: cacheKey as NSString)?.image {
            return memImage
        }

        let diskURL = fileURL(for: cacheKey)
        let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
        if let diskImage = await readCachedImage(at: diskURL, maxPixelSize: maxPixel) {
            guard !Task.isCancelled, memoryGeneration == requestGeneration else { return nil }
            setMemoryImage(diskImage, cacheKey: cacheKey)
            return diskImage
        }

        let (acquired, _) = await decodeGate.acquire()
        guard acquired else { return nil }
        guard !Task.isCancelled, memoryGeneration == requestGeneration else {
            await decodeGate.release()
            return nil
        }
        let token = FirstUseHitchDiagnostics.begin(
            "ArtworkDerivative.decode",
            detail: "target=\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"
        )
        let decodeTask = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                downsampledImage(fileURL: sourceURL, targetPixelSize: targetPixelSize)
                    .flatMap { Task.isCancelled ? nil : $0 }
            }
        }
        let decoded = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await decodeGate.release()
        FirstUseHitchDiagnostics.end(token, detail: "success=\(decoded != nil)")
        guard !Task.isCancelled, memoryGeneration == requestGeneration, let decoded else { return nil }

        setMemoryImage(decoded, cacheKey: cacheKey)
        persist(image: decoded, to: diskURL)
        return decoded
    }

    func image(
        for cacheKey: String,
        artworkData: Data,
        maxPixelSize: Int
    ) async -> NSImage? {
        scheduleInitialDiskTrimIfNeeded()
        let requestGeneration = memoryGeneration

        if let memImage = memoryCache.object(forKey: cacheKey as NSString)?.image {
            return memImage
        }

        let diskURL = fileURL(for: cacheKey)
        if let diskImage = await readCachedImage(at: diskURL, maxPixelSize: max(1, maxPixelSize)) {
            guard !Task.isCancelled, memoryGeneration == requestGeneration else { return nil }
            setMemoryImage(diskImage, cacheKey: cacheKey)
            touchItem(at: diskURL)
            return diskImage
        }

        let (acquired, _) = await decodeGate.acquire()
        guard acquired else { return nil }
        guard !Task.isCancelled, memoryGeneration == requestGeneration else {
            await decodeGate.release()
            return nil
        }
        let token = FirstUseHitchDiagnostics.begin(
            "ArtworkDerivative.decode",
            detail: "maxPixel=\(maxPixelSize)"
        )
        let decodeTask = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                let image = downsampledImage(data: artworkData, maxPixelSize: maxPixelSize)
                return Task.isCancelled ? nil : image
            }
        }
        let decoded = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await decodeGate.release()
        FirstUseHitchDiagnostics.end(token, detail: "success=\(decoded != nil)")
        guard !Task.isCancelled, memoryGeneration == requestGeneration, let decoded else { return nil }

        setMemoryImage(decoded, cacheKey: cacheKey)
        persist(image: decoded, to: diskURL)
        return decoded
    }

    /// Whether the derivative already sits on disk, checked without decoding it.
    func hasDiskDerivative(for cacheKey: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: cacheKey).path)
    }

    /// Whether the disk cache is below `fraction` of its budget. Preparation
    /// ahead of use stops above it, so it never pushes out derivatives the
    /// listener has seen recently.
    func hasDiskRoom(belowFraction fraction: Double = 0.8) -> Bool {
        let used = DiskCacheRetention.directorySize(at: diskRootURL, fileManager: fileManager).bytes
        return Double(used) < Double(maxDiskBytes) * fraction
    }

    func clearAll() {
        memoryGeneration &+= 1
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskRootURL)
        try? fileManager.createDirectory(at: diskRootURL, withIntermediateDirectories: true)
    }

    func clearMemory() {
        memoryGeneration &+= 1
        memoryCache.removeAllObjects()
    }

    private func setMemoryImage(_ image: NSImage, cacheKey: String) {
        memoryCache.setObject(
            ArtworkDerivativeImageBox(image: image),
            forKey: cacheKey as NSString,
            cost: estimatedCost(for: image)
        )
    }

    private func persist(image: NSImage, to url: URL) {
        guard let encoded = encodedImageData(for: image) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)

        writeCounter += 1
        if writeCounter.isMultiple(of: 64) {
            trimDiskIfNeeded()
        }
    }

    private func scheduleInitialDiskTrimIfNeeded() {
        guard !didScheduleInitialDiskTrim else { return }
        didScheduleInitialDiskTrim = true
        Task { [weak self] in
            await self?.trimDiskIfNeeded()
        }
    }

    private nonisolated func fileURL(for cacheKey: String) -> URL {
        // Isolate derivatives produced by the old embedded-preview policy.
        // Those files remain disposable cache and age out through normal trimming.
        let digest = stableDigest("source-thumbnail-v2|\(cacheKey)")
        return diskRootURL.appendingPathComponent("\(digest).png")
    }

    /// Decodes a derivative already on disk, on the caller's thread and without
    /// entering the actor. Bulk warmups read hundreds of row covers this way in
    /// a fraction of a second; the actor path costs a queue hop per cover.
    nonisolated func cachedDiskImage(for cacheKey: String, maxPixelSize: Int) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let image = Self.decodeCachedImage(at: fileURL(for: cacheKey), maxPixelSize: maxPixelSize)
        return Task.isCancelled ? nil : image
    }

    private nonisolated static func decodeCachedImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        autoreleasepool {
            guard
                FileManager.default.fileExists(atPath: url.path),
                let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                )
            else { return nil }
            return downsampledImage(source: source, maxPixelSize: maxPixelSize)
        }
    }

    /// Reads a cached derivative off the actor. Reading it here made every
    /// cache hit wait for the one before it, so a fling through a long list
    /// spent close to a second queueing on lookups that each take a millisecond.
    private func readCachedImage(at url: URL, maxPixelSize: Int) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as NSImage? }
            let image = Self.decodeCachedImage(at: url, maxPixelSize: maxPixelSize)
            return Task.isCancelled ? nil : image
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func touchItem(at url: URL) {
        // Every hit used to rewrite the modification date, which put one
        // filesystem write behind each thumbnail during scrolling. Refreshing at
        // most every few hours keeps the retention order without that cost.
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = values?.contentModificationDate,
           Date().timeIntervalSince(modified) < Self.touchInterval {
            return
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimDiskIfNeeded() {
        let result = DiskCacheRetention.trim(
            at: diskRootURL,
            maxBytes: maxDiskBytes,
            targetFraction: DiskCacheBudget.playlistDerivatives.targetFraction,
            maxAge: DiskCacheBudget.playlistDerivatives.maxAge,
            fileManager: fileManager
        )
        guard result.removedFileCount > 0 else { return }
        Log.debug(
            "[ArtworkDerivativeCache] disk trim removedFiles=\(result.removedFileCount) removedBytes=\(result.removedBytes)",
            category: .perf
        )
    }

    private func encodedImageData(for image: NSImage) -> Data? {
        ArtworkDataNormalizer.encodedDerivativeData(for: image, lossyCompressionQuality: 0.85)
    }

    private func pngData(for image: NSImage) -> Data? {
        encodedImageData(for: image)
    }

    private func estimatedCost(for image: NSImage) -> Int {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private nonisolated func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private nonisolated func downsampledImage(data: Data, targetPixelSize: CGSize) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ) else { return nil }
    let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
    return downsampledImage(source: source, maxPixelSize: maxPixel)
}

private nonisolated func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ) else { return nil }
    return downsampledImage(source: source, maxPixelSize: maxPixelSize)
}

private nonisolated func downsampledImage(fileURL: URL, targetPixelSize: CGSize) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(
        fileURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ) else { return nil }
    return downsampledImage(
        source: source,
        maxPixelSize: max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
    )
}

private nonisolated func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
    let pixelSize = max(1, maxPixelSize)
    let options: [CFString: Any] = [
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    return NSImage(
        cgImage: cgImage,
        size: CGSize(width: cgImage.width, height: cgImage.height)
    )
}
