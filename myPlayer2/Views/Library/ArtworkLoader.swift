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
}

actor ArtworkDecodeGate {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
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
        print(
            "[PlaylistPerf] rowBody/s=\(rowBodyRecomputeCount), decode/s=\(decodeCount), decodeAvgMs=\(String(format: "%.2f", avgDecode)), decodeOnMain=\(decodeMainThreadWarnings), listRebuild/s=\(listRebuildCount), listRebuildAvgMs=\(String(format: "%.2f", avgRebuild)), last=\(lastRebuildReason)"
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
    private static let decodeGate = ArtworkDecodeGate(maxConcurrent: 3)

    static func checksum(for data: Data?) -> UInt64 {
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

    static func cacheKey(trackID: UUID, checksum: UInt64, targetPixelSize: CGSize) -> String {
        "\(trackID.uuidString)-\(checksum)-\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"
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

        await decodeGate.acquire()
        let signpost = PlaylistPerfDiagnostics.beginDecodeSignpost()
        let startUptime = ProcessInfo.processInfo.systemUptime

        let image = await Task.detached(priority: .utility) {
            return downsampledImage(data: artworkData, targetPixelSize: targetPixelSize)
        }.value

        let endUptime = ProcessInfo.processInfo.systemUptime
        PlaylistPerfDiagnostics.endDecodeSignpost(signpost)
        PlaylistPerfDiagnostics.markDecode(
            durationMs: (endUptime - startUptime) * 1000,
            wasOnMainThread: false
        )
        await decodeGate.release()

        guard !Task.isCancelled else { return nil }

        if let image {
            let cost = Int(targetPixelSize.width * targetPixelSize.height * 4)
            await cache.setImage(image, for: cacheKey, cost: max(1, cost))
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
}

struct ArtworkPrefetchRequest: Sendable {
    let cacheKey: String
    let artworkData: Data?
    let targetPixelSize: CGSize
}
