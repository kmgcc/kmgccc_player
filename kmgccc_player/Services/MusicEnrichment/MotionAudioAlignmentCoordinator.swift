import Foundation
import AVFoundation

/// Each result belongs to one local song and one imported video, even when the
/// artwork itself is shared by an album.
@MainActor
final class MotionAudioAlignmentCoordinator {
    nonisolated private struct FileStamp: Codable, Equatable, Sendable {
        let size: UInt64
        let modified: Date
        nonisolated static func read(_ url: URL) -> FileStamp? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return FileStamp(size: size.uint64Value, modified: modified)
        }
    }
    nonisolated private struct Entry: Codable, Sendable {
        let videoPath: String
        let song: FileStamp
        let video: FileStamp
        let offset: Double
    }
    private var offsets: [String: Double] = [:]
    private var checked = Set<String>()
    private var generations: [String: UInt64] = [:]
    nonisolated enum Result: Sendable { case matched, unmatched, failed, cancelled }

    private func key(track: Track, video: URL) -> String {
        "\(track.libraryRootSnapshot)|\(track.id.uuidString)|\(track.originalFilePath)|\(video.path)"
    }
    private func file(root: String, trackID: UUID) -> URL {
        URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Enrichment/MotionAlignment/\(trackID.uuidString).json")
    }

    func offset(track: Track, video: URL) -> Double? {
        let cacheKey = key(track: track, video: video)
        if checked.contains(cacheKey) { return offsets[cacheKey] }
        checked.insert(cacheKey)
        let generation = generations[cacheKey, default: 0]
        guard !track.libraryRootSnapshot.isEmpty else { return nil }
        let resolution = track.resolveFileURL()
        guard let song = resolution.url else { resolution.lease.release(); return nil }
        let lease = resolution.lease
        let file = file(root: track.libraryRootSnapshot, trackID: track.id)
        Task { [weak self] in
            let value = await Task.detached(priority: .utility) { () -> Double? in
                defer { lease.release() }
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      entry.videoPath == video.path,
                      FileStamp.read(song) == entry.song, FileStamp.read(video) == entry.video,
                      entry.offset.isFinite else { return nil }
                return entry.offset
            }.value
            if let self, self.generations[cacheKey, default: 0] == generation, let value {
                self.offsets[cacheKey] = value
            }
        }
        return nil
    }

    func invalidate(trackID: UUID) {
        let marker = "|\(trackID.uuidString)|"
        for key in Set(checked).union(generations.keys) where key.contains(marker) {
            generations[key, default: 0] &+= 1
        }
        checked = checked.filter { !$0.contains(marker) }
        offsets = offsets.filter { !$0.key.contains(marker) }
    }

    /// Called only by the library's idle work source. The scheduler owns the
    /// worker's lifetime and controls pauses between analysis segments.
    func analyze(track: Track, video: URL, context: BackgroundWorkContext) async -> Result {
        guard !track.libraryRootSnapshot.isEmpty else { return .failed }
        let resolution = track.resolveFileURL()
        guard let song = resolution.url else { resolution.lease.release(); return .failed }
        let lease = resolution.lease
        defer { lease.release() }
        let duration = track.duration
        let destination = file(root: track.libraryRootSnapshot, trackID: track.id)
        let cacheKey = key(track: track, video: video)
        invalidate(trackID: track.id)
        let generation = generations[cacheKey, default: 0]
        generations[cacheKey] = generation
        let worker = Task.detached(priority: context.taskPriority) { () -> (Result, Double?) in
            do {
                try await context.checkpoint()
                guard let songStamp = FileStamp.read(song), let videoStamp = FileStamp.read(video) else { return (.failed, nil) }
                let videoTracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .audio)
                guard !videoTracks.isEmpty else {
                    try await context.checkpoint()
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    return (.unmatched, nil)
                }
                let value = try await MotionAudioAligner.alignment(song: song, video: video, songDuration: duration) {
                    try await context.checkpoint()
                }
                try await context.checkpoint()
                guard FileStamp.read(song) == songStamp, FileStamp.read(video) == videoStamp else { return (.failed, nil) }
                guard let value else {
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    return (.unmatched, nil)
                }
                let entry = Entry(videoPath: video.path, song: songStamp, video: videoStamp, offset: value)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entry).write(to: destination, options: .atomic)
                return (.matched, value)
            } catch is CancellationError { return (.cancelled, nil) }
            catch { return (.failed, nil) }
        }
        let (result, value) = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, !context.isCancelled else { return .cancelled }
        if case .matched = result, generations[cacheKey, default: 0] == generation {
            checked.insert(cacheKey)
            offsets[cacheKey] = value
        }
        return result
    }
}
