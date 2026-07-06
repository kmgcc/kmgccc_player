//
//  ArtworkLoader.swift
//  myPlayer2
//
//  Playlist artwork decode/caching utilities.
//

import AppKit
import ImageIO
import OSLog
import SwiftUI

final class CachedArtworkImage: @unchecked Sendable {
    let image: NSImage
    nonisolated init(_ image: NSImage) {
        self.image = image
    }
}

actor ArtworkImageCache {
    private let cache = NSCache<NSString, CachedArtworkImage>()

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func setImage(_ image: NSImage, for key: String, cost: Int) {
        cache.setObject(CachedArtworkImage(image), forKey: key as NSString, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
    }
}

enum PlaylistPerfDiagnostics {
    private static let lock = NSLock()
    private static var rowBodyRecomputeCount = 0
    private static var decodeCount = 0
    private static var decodeMainThreadWarnings = 0
    private static var accumulatedDecodeMs: Double = 0
    private static var listRebuildCount = 0
    private static var accumulatedListRebuildMs: Double = 0
    private static var lastRebuildReason = ""
    private static var lastDumpUptime = ProcessInfo.processInfo.systemUptime
    private static let signposter = OSSignposter(
        subsystem: "kmg.myplayer2",
        category: "playlist_scroll_perf"
    )

    static func markRowBodyRecompute() {
        #if DEBUG
            lock.lock()
            rowBodyRecomputeCount += 1
            dumpIfNeededLocked()
            lock.unlock()
        #endif
    }

    static func beginDecodeSignpost() -> OSSignpostIntervalState {
        signposter.beginInterval("ArtworkDecode")
    }

    static func endDecodeSignpost(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ArtworkDecode", state)
    }

    static func markDecode(durationMs: Double, wasOnMainThread: Bool) {
        #if DEBUG
            lock.lock()
            decodeCount += 1
            accumulatedDecodeMs += durationMs
            if wasOnMainThread {
                decodeMainThreadWarnings += 1
            }
            dumpIfNeededLocked()
            lock.unlock()
        #endif
    }

    static func markListRebuild(reason: String, trackCount: Int, durationMs: Double) {
        #if DEBUG
            lock.lock()
            listRebuildCount += 1
            accumulatedListRebuildMs += durationMs
            lastRebuildReason = "\(reason):\(trackCount)"
            dumpIfNeededLocked()
            lock.unlock()
        #endif
    }

    private static func dumpIfNeededLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDumpUptime >= 1.2 else { return }
        let avgDecode = decodeCount > 0 ? (accumulatedDecodeMs / Double(decodeCount)) : 0
        let avgRebuild =
            listRebuildCount > 0 ? (accumulatedListRebuildMs / Double(listRebuildCount)) : 0
        Log.debug(
            "rowBody/s=\(rowBodyRecomputeCount), decode/s=\(decodeCount), decodeAvgMs=\(String(format: "%.2f", avgDecode)), decodeOnMain=\(decodeMainThreadWarnings), listRebuild/s=\(listRebuildCount), listRebuildAvgMs=\(String(format: "%.2f", avgRebuild)), last=\(lastRebuildReason)",
            category: .perf
        )
        rowBodyRecomputeCount = 0
        decodeCount = 0
        decodeMainThreadWarnings = 0
        accumulatedDecodeMs = 0
        listRebuildCount = 0
        accumulatedListRebuildMs = 0
        lastRebuildReason = ""
        lastDumpUptime = now
    }
}

enum ArtworkLoader {
    static let cache = ArtworkImageCache()

    nonisolated static func checksum(for data: Data?) -> UInt64 {
        guard let data else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }

    nonisolated static func cacheKey(trackID: UUID, checksum: UInt64, targetPixelSize: CGSize)
        -> String
    {
        "\(trackID.uuidString)-\(checksum)-\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"
    }

    static func cachedImage(for cacheKey: String) async -> NSImage? {
        await cache.image(for: cacheKey)
    }

    static func clearMemoryCache() async {
        await cache.clear()
    }

    static func loadImage(
        artworkData: Data?,
        cacheKey: String,
        targetPixelSize: CGSize
    ) async -> NSImage? {
        guard let artworkData, !artworkData.isEmpty else { return nil }

        if let cached = await cache.image(for: cacheKey) {
            return cached
        }

        let signpost = PlaylistPerfDiagnostics.beginDecodeSignpost()
        let startUptime = ProcessInfo.processInfo.systemUptime

        let image = await ArtworkDerivativeCacheStore.shared.image(
            for: cacheKey,
            artworkData: artworkData,
            targetPixelSize: targetPixelSize
        )

        let endUptime = ProcessInfo.processInfo.systemUptime
        PlaylistPerfDiagnostics.endDecodeSignpost(signpost)
        PlaylistPerfDiagnostics.markDecode(
            durationMs: (endUptime - startUptime) * 1000,
            wasOnMainThread: false
        )

        guard !Task.isCancelled else { return nil }

        if let image {
            let cost = Int(targetPixelSize.width * targetPixelSize.height * 4)
            await cache.setImage(image, for: cacheKey, cost: max(1, cost))
        }
        return image
    }

    static func loadHeaderImage(
        artworkData: Data?,
        cacheKey: String,
        maxPixelSize: Int = 640
    ) async -> NSImage? {
        guard let artworkData, !artworkData.isEmpty else { return nil }
        if let cached = await cache.image(for: cacheKey) {
            LyricsRuntimeProfile.increment("header.loadHeaderImage.cacheHit")
            return cached
        }
        let startUptime = ProcessInfo.processInfo.systemUptime
        let image = await ArtworkDerivativeCacheStore.shared.image(
            for: cacheKey,
            artworkData: artworkData,
            maxPixelSize: maxPixelSize
        )
        LyricsRuntimeProfile.increment("header.loadHeaderImage.count")
        LyricsRuntimeProfile.addDuration(
            "header.loadHeaderImage",
            ms: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
        if let image {
            let side = max(1, maxPixelSize)
            await cache.setImage(image, for: cacheKey, cost: side * side * 4)
        }
        return image
    }

    @discardableResult
    static func prefetch(
        _ requests: [ArtworkPrefetchRequest]
    ) -> Task<Void, Never>? {
        guard !requests.isEmpty else { return nil }
        return Task.detached(priority: .background) {
            for request in requests {
                if Task.isCancelled { return }
                _ = await loadImage(
                    artworkData: request.artworkData,
                    cacheKey: request.cacheKey,
                    targetPixelSize: request.targetPixelSize
                )
            }
        }
    }

    nonisolated static func headerPreviewImage(
        data: Data?,
        maxPixelSize: Int = 640
    ) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let startUptime = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image = downsampledImage(source: source, maxPixelSize: max(1, maxPixelSize))
        LyricsRuntimeProfile.increment("header.headerPreviewImage.data.count")
        LyricsRuntimeProfile.addDuration(
            "header.headerPreviewImage.data",
            ms: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
        return image
    }

    nonisolated static func squareHeaderPreviewImage(
        data: Data?,
        maxPixelSize: Int = 640
    ) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let startUptime = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image = squareDownsampledImage(source: source, maxPixelSize: max(1, maxPixelSize))
        LyricsRuntimeProfile.increment("header.squareHeaderPreviewImage.data.count")
        LyricsRuntimeProfile.addDuration(
            "header.squareHeaderPreviewImage.data",
            ms: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
        return image
    }

    nonisolated static func headerPreviewImage(
        fileURL: URL,
        maxPixelSize: Int = 640
    ) -> NSImage? {
        let startUptime = ProcessInfo.processInfo.systemUptime
        guard
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }
        let image = downsampledImage(source: source, maxPixelSize: max(1, maxPixelSize))
        LyricsRuntimeProfile.increment("header.headerPreviewImage.file.count")
        LyricsRuntimeProfile.addDuration(
            "header.headerPreviewImage.file",
            ms: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
        return image
    }

    nonisolated static func squareHeaderPreviewImage(
        fileURL: URL,
        maxPixelSize: Int = 640
    ) -> NSImage? {
        let startUptime = ProcessInfo.processInfo.systemUptime
        guard
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }
        let image = squareDownsampledImage(source: source, maxPixelSize: max(1, maxPixelSize))
        LyricsRuntimeProfile.increment("header.squareHeaderPreviewImage.file.count")
        LyricsRuntimeProfile.addDuration(
            "header.squareHeaderPreviewImage.file",
            ms: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        )
        return image
    }

    private nonisolated static func downsampledImage(data: Data, targetPixelSize: CGSize)
        -> NSImage?
    {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: .init(width: targetPixelSize.width, height: targetPixelSize.height))
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

    private nonisolated static func squareDownsampledImage(
        source: CGImageSource,
        maxPixelSize: Int
    ) -> NSImage? {
        guard let image = downsampledImage(source: source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return squareCroppedImage(image, pixelSize: maxPixelSize)
    }

    private nonisolated static func squareCroppedImage(
        _ image: NSImage,
        pixelSize: Int
    ) -> NSImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        else { return nil }

        let squareSide = min(cgImage.width, cgImage.height)
        let cropRect = CGRect(
            x: (cgImage.width - squareSide) / 2,
            y: (cgImage.height - squareSide) / 2,
            width: squareSide,
            height: squareSide
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return image }

        let destinationSide = max(1, pixelSize)
        let destRect = CGRect(x: 0, y: 0, width: destinationSide, height: destinationSide)
        guard
            let context = CGContext(
                data: nil,
                width: destinationSide,
                height: destinationSide,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return NSImage(cgImage: cropped, size: CGSize(width: squareSide, height: squareSide)) }

        context.interpolationQuality = .high
        context.draw(cropped, in: destRect)

        guard let resized = context.makeImage() else {
            return NSImage(cgImage: cropped, size: CGSize(width: squareSide, height: squareSide))
        }

        return NSImage(
            cgImage: resized,
            size: CGSize(width: destinationSide, height: destinationSide)
        )
    }
}

struct ArtworkPrefetchRequest: Sendable {
    let cacheKey: String
    let artworkData: Data?
    let targetPixelSize: CGSize
}
