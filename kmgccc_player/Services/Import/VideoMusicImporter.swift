import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum VideoMusicImportError: LocalizedError {
    case noAudio, invalidVideo, exportFailed, parentAuthorizationDenied

    var errorDescription: String? {
        switch self {
        case .noAudio: "视频中没有可导入的音轨"
        case .invalidVideo: "无法读取视频画面"
        case .exportFailed: "无法提取视频中的音乐与画面"
        case .parentAuthorizationDenied: "需要原视频所在文件夹的写入权限"
        }
    }
}

nonisolated struct ImportedVideoMusic: Sendable {
    let audioURL: URL
    let duration: Double
    let artworkData: Data?
    let motionURL: URL?
    let motionDuration: Double?
    let width: Int?
    let height: Int?

    func motionArtwork(trackID: UUID) -> TrackMotionArtwork? {
        guard let motionURL else { return nil }
        let assets = ["square", "tall"].map { kind in
            StoredMotionArtwork(
                kind: kind,
                relativePath: "Tracks/\(trackID.uuidString)/motion-imported.\(motionURL.pathExtension)",
                sourceURL: "importedVideo:\(trackID.uuidString)",
                startTime: 0, duration: motionDuration ?? duration, width: width, height: height
            )
        }
        return TrackMotionArtwork(importedAssets: assets)
    }
}

/// Converts containers before they reach the ordinary audio import/decoder.
/// Only one audio track and one video track are selected; no source is edited.
nonisolated enum VideoMusicImporter {
    static func prepare(
        sourceURL: URL,
        outputDirectory: URL,
        cancellationToken: ImportCancellationToken
    ) async throws -> ImportedVideoMusic {
        try await cancellationToken.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoMusicImportError.noAudio
        }
        let directory = outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }

        let audioComposition = AVMutableComposition()
        guard let audio = audioComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoMusicImportError.exportFailed
        }
        let audioRange = try await audioTrack.load(.timeRange)
        try audio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        // Preserve AAC/ALAC packets when possible. Other movie audio codecs
        // use the system M4A encoder so the result stays a compact music file.
        do {
            try await export(audioComposition, preset: AVAssetExportPresetPassthrough, to: audioURL, type: .m4a, token: cancellationToken)
            try PerAudioFileImportTask.ensureAudioIsDecodable(audioURL, knownDuration: 0)
        } catch {
            try await cancellationToken.checkCancellation()
            try? FileManager.default.removeItem(at: audioURL)
            try await export(audioComposition, preset: AVAssetExportPresetAppleM4A, to: audioURL, type: .m4a, token: cancellationToken)
        }
        try PerAudioFileImportTask.ensureAudioIsDecodable(audioURL, knownDuration: 0)
        let decodedAudio = try AVAudioFile(forReading: audioURL)
        let duration = Double(decodedAudio.length) / decodedAudio.processingFormat.sampleRate

        var artworkData: Data?
        var motionURL: URL?
        var motionDuration: Double?
        var width: Int?
        var height: Int?
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            try await cancellationToken.checkCancellation()
            let videoRange = try await videoTrack.load(.timeRange)
            let transform = try await videoTrack.load(.preferredTransform)
            let size = try await videoTrack.load(.naturalSize).applying(transform)
            guard size.width.isFinite, size.height.isFinite, abs(size.width) > 0, abs(size.height) > 0 else {
                throw VideoMusicImportError.invalidVideo
            }
            width = Int(abs(size.width).rounded())
            height = Int(abs(size.height).rounded())
            let composition = AVMutableComposition()
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoMusicImportError.exportFailed
            }
            // Keep the complete picture, including its orientation, while
            // excluding every audio track from the dynamic artwork file.
            try video.insertTimeRange(videoRange, of: videoTrack, at: .zero)
            video.preferredTransform = transform
            let destination = directory.appendingPathComponent("motion.mov")
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: destination, type: .mov, token: cancellationToken)
            motionURL = destination
            motionDuration = videoRange.duration.seconds
            let generator = AVAssetImageGenerator(asset: composition)
            generator.appliesPreferredTrackTransform = true
            let edge = ArtworkDataNormalizer.importMaxPixelSize
            generator.maximumSize = CGSize(width: CGFloat(edge), height: CGFloat(edge))
            // Choose a frame near the beginning, beyond a common black lead-in.
            let posterTime = CMTime(seconds: min(1, videoRange.duration.seconds / 2), preferredTimescale: 600)
            let frame = try await firstFrame(of: generator, at: posterTime)
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw VideoMusicImportError.invalidVideo
            }
            CGImageDestinationAddImage(encoder, frame, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw VideoMusicImportError.invalidVideo }
            artworkData = data as Data
        }
        try await cancellationToken.checkCancellation()
        succeeded = true
        return ImportedVideoMusic(audioURL: audioURL, duration: duration, artworkData: artworkData, motionURL: motionURL, motionDuration: motionDuration, width: width, height: height)
    }

    /// The imported asynchronous image API makes the region-based isolation
    /// checker reject this module, so the completion-handler form supplies the
    /// same frame through a continuation.
    private static func firstFrame(
        of generator: AVAssetImageGenerator, at time: CMTime
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? VideoMusicImportError.invalidVideo)
                }
            }
        }
    }

    private static func export(
        _ asset: AVAsset, preset: String, to url: URL, type: AVFileType,
        token: ImportCancellationToken
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoMusicImportError.exportFailed
        }
        // AVAssetExportSession is not Sendable. As in the SDK's own async
        // export implementation, only cancellation may cross executors.
        nonisolated(unsafe) let sessionForCancellation = session
        let handlerID = try await token.registerCancellationHandler { sessionForCancellation.cancelExport() }
        do {
            try await session.export(to: url, as: type)
            await token.removeCancellationHandler(handlerID)
            try await token.checkCancellation()
        } catch {
            await token.removeCancellationHandler(handlerID)
            try await token.checkCancellation()
            throw error
        }
    }

    /// Publish on the source volume with an exclusive rename. The marker
    /// travels with the file, letting source scans hide this generated copy.
    static func publishReferencedAudio(
        from stagedURL: URL, beside sourceURL: URL, in directory: URL,
        source: ReferencedVideoSource
    ) throws -> URL {
        let pending = directory.appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: pending) }
        try FileManager.default.copyItem(at: stagedURL, to: pending)
        try markGeneratedAudio(pending, source: source)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            let name = suffix == 1 ? "\(base).m4a" : "\(base) \(suffix).m4a"
            let destination = directory.appendingPathComponent(name)
            if renamex_np(pending.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
            // Re-importing a movie replaces the audio this app extracted for
            // it earlier instead of accumulating numbered copies. A file the
            // listener put there is never touched: only a copy carrying this
            // movie's own marker is taken over.
            if isGeneratedAudio(destination) {
                try? FileManager.default.removeItem(at: destination)
                if renamex_np(pending.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            }
            suffix += 1
        }
    }

    private static let generatedAudioAttribute = "com.kmgccc.player.video-source"

    static func markGeneratedAudio(_ url: URL, source: ReferencedVideoSource) throws {
        let marker = try JSONEncoder().encode(source)
        let marked = marker.withUnsafeBytes { bytes in
            setxattr(url.path, generatedAudioAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard marked == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func isGeneratedAudio(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "m4a" else { return false }
        let size = getxattr(url.path, generatedAudioAttribute, nil, 0, 0, 0)
        guard size > 0, size < 65_536 else { return false }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, generatedAudioAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard count == size,
              let source = try? JSONDecoder().decode(ReferencedVideoSource.self, from: data) else { return false }
        var candidates = [URL(fileURLWithPath: source.path)]
        if let bookmark = source.bookmarkData,
           let resolved = try? SystemBookmarkResolver().resolve(bookmark) {
            candidates.append(resolved.url)
        }
        candidates.append(url.deletingLastPathComponent().appendingPathComponent(candidates[0].lastPathComponent))
        return candidates.contains { candidate in
            guard let current = try? ReferencedFileIdentityProvider().fingerprint(for: candidate) else { return false }
            // Replacing the movie at its recorded path does not turn its
            // already extracted audio into a second, unrelated import.
            return candidate.standardizedFileURL.path == URL(fileURLWithPath: source.path).standardizedFileURL.path
                || TrackIdentityResolver.samePhysicalIdentity(source.fingerprint, current)
        }
    }
}
