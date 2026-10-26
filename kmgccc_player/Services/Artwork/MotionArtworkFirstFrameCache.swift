import AVFoundation
import CoreGraphics
import Foundation

/// Raw, oriented video frames only. Skin-specific processing stays on the
/// visible surface, so prefetch never creates players or renders hidden skins.
nonisolated struct MotionArtworkFirstFrame: @unchecked Sendable {
    let image: CGImage
    let byteCost: Int

    init(image: CGImage, byteCost: Int? = nil) {
        self.image = image
        self.byteCost = byteCost ?? image.bytesPerRow * image.height
    }
}

nonisolated final class MotionArtworkFirstFrameCache: @unchecked Sendable {
    typealias Loader = @Sendable (MotionArtworkResource) async -> MotionArtworkFirstFrame?

    private struct Key: Hashable {
        let url: URL
        let start: Double
        let duration: Double

        init(_ resource: MotionArtworkResource) {
            url = resource.url
            start = resource.startTime
            duration = resource.duration
        }
    }

    private struct Entry {
        let frame: MotionArtworkFirstFrame
        let cost: Int
        var access: UInt64
    }

    private struct Job {
        let id: UUID
        let generation: UUID
        let context: BackgroundWorkContext
        let task: Task<MotionArtworkFirstFrame?, Never>
    }

    /// AVFoundation permits cancelling asynchronous generation from another
    /// thread; all other generator access stays in the decoding operation.
    private struct GeneratorHandle: @unchecked Sendable {
        let value: AVAssetImageGenerator
    }

    private let lock = NSLock()
    private let maxCount: Int
    private let maxBytes: Int
    private let loader: Loader
    private var entries: [Key: Entry] = [:]
    private var jobs: [Key: Job] = [:]
    private var generation = UUID()
    private var access: UInt64 = 0
    private var totalBytes = 0

    init(maxCount: Int = 3, maxBytes: Int = 24 * 1024 * 1024,
         loader: Loader? = nil) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.loader = loader ?? { resource in
            await MotionArtworkFirstFrameCache.decode(resource, maxBytes: maxBytes)
        }
    }

    /// A memory-only lookup; no file stat, decoding or waiting on the UI path.
    func cachedFrame(for resource: MotionArtworkResource) -> CGImage? {
        lock.withLock {
            let key = Key(resource)
            guard var entry = entries[key] else { return nil }
            access &+= 1
            entry.access = access
            entries[key] = entry
            return entry.frame.image
        }
    }

    func prepare(_ resource: MotionArtworkResource, context: BackgroundWorkContext) async {
        guard resource.url.isFileURL, (try? await context.checkpoint()) != nil else { return }
        let key = Key(resource)
        let job: Job? = lock.withLock {
            guard entries[key] == nil else { return nil }
            if let existing = jobs[key] {
                guard existing.context.isCancelled || existing.task.isCancelled else { return nil }
                existing.task.cancel()
            }
            let loader = loader
            let job = Job(id: UUID(), generation: generation, context: context,
                          task: Task.detached(priority: context.taskPriority) { await loader(resource) })
            jobs[key] = job
            return job
        }
        guard let job else { return }
        let result = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            job.task.cancel()
        }
        // Decoding is finished. Commit or discard without suspending with a
        // decoded frame held across a memory-pressure pause of the scheduler.
        lock.withLock {
            guard jobs[key]?.id == job.id else { return }
            jobs[key] = nil
            guard !context.isCancelled, !Task.isCancelled,
                  generation == job.generation, let result else { return }
            let cost = result.byteCost
            guard maxCount > 0, cost <= maxBytes else { return }
            while entries.count >= maxCount || totalBytes + cost > maxBytes {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                totalBytes -= oldest.value.cost
                entries[oldest.key] = nil
            }
            access &+= 1
            entries[key] = Entry(frame: result, cost: cost, access: access)
            totalBytes += cost
        }
    }

    func clearMemory() {
        let tasks = lock.withLock {
            generation = UUID()
            entries.removeAll()
            totalBytes = 0
            let tasks = jobs.values.map(\.task)
            jobs.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    private static func decode(_ resource: MotionArtworkResource, maxBytes: Int) async -> MotionArtworkFirstFrame? {
        let asset = AVURLAsset(url: resource.url)
        // Skip oversized originals instead of downscaling them or decoding a
        // frame that cannot fit the cache. Playback keeps its original quality.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
              let size = try? await track.load(.naturalSize),
              size.width > 0, size.height > 0,
              size.width * size.height * 4 <= CGFloat(maxBytes), !Task.isCancelled else { return nil }
        let fallback = CMTimeRange(
            start: CMTime(seconds: resource.startTime.isFinite ? resource.startTime : -1, preferredTimescale: 600),
            duration: CMTime(seconds: resource.duration.isFinite ? resource.duration : 0, preferredTimescale: 600)
        )
        guard let range = await MotionArtworkLoopRange.load(asset: asset, fallback: fallback),
              !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .encodedPixels
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let handle = GeneratorHandle(value: generator)
        // Use AVFoundation's callback API inside the sendable handle. Its
        // async convenience method sends the non-Sendable generator to a
        // concurrent executor while cancellation still needs that generator.
        let result: MotionArtworkFirstFrame? = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                handle.value.generateCGImagesAsynchronously(forTimes: [NSValue(time: range.start)]) { _, image, _, status, _ in
                    guard status == .succeeded, let image else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: MotionArtworkFirstFrame(
                        image: MotionArtworkFrameGeometry.centerSquareCrop(image),
                        byteCost: image.bytesPerRow * image.height
                    ))
                }
            }
        } onCancel: {
            handle.value.cancelAllCGImageGeneration()
        }
        return Task.isCancelled ? nil : result
    }
}
