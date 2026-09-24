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
    private let memoryCache = NSCache<NSString, ArtworkDerivativeImageBox>()
    private let fileManager = FileManager.default
    private let maxDiskBytes: Int64 = 220 * 1024 * 1024
    private let decodeGate = ArtworkDecodeGate(maxConcurrent: 2)
    private var writeCounter = 0
    private var didScheduleInitialDiskTrim = false
    private var memoryGeneration: UInt64 = 0
    private nonisolated let diskRootURL: URL

    init(diskRootURL: URL) {
        self.diskRootURL = diskRootURL
        memoryCache.countLimit = 96
        memoryCache.totalCostLimit = 16 * 1024 * 1024

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
        if let diskImage = readImage(at: diskURL, maxPixelSize: maxPixel) {
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
        if let diskImage = readImage(at: diskURL, maxPixelSize: maxPixel) {
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
        if let diskImage = readImage(at: diskURL, maxPixelSize: max(1, maxPixelSize)) {
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
        guard let png = pngData(for: image) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)

        writeCounter += 1
        if writeCounter.isMultiple(of: 26) {
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

    private func fileURL(for cacheKey: String) -> URL {
        let digest = stableDigest(cacheKey)
        return diskRootURL.appendingPathComponent("\(digest).png")
    }

    private func readImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private func touchItem(at url: URL) {
        let now = Date()
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    private func trimDiskIfNeeded() {
        let result = DiskCacheRetention.trim(
            at: diskRootURL,
            maxBytes: maxDiskBytes,
            fileManager: fileManager
        )
        guard result.removedFileCount > 0 else { return }
        Log.debug(
            "[ArtworkDerivativeCache] disk trim removedFiles=\(result.removedFileCount) removedBytes=\(result.removedBytes)",
            category: .perf
        )
    }

    private func pngData(for image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
            else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private func estimatedCost(for image: NSImage) -> Int {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private nonisolated func downsampledImage(data: Data, targetPixelSize: CGSize) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
    return downsampledImage(source: source, maxPixelSize: maxPixel)
}

private nonisolated func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
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
