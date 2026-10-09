import AVFoundation
import CryptoKit
import Foundation
import PlayerAutomationProtocol

private actor LoudnessDerivedCache {
    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func loadRecent(limit: Int) throws -> [LoudnessTrackRecord] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let mostRecentURLs = try urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(max(0, limit))
        let recentURLs = Array(mostRecentURLs).reversed()
        let decoder = JSONDecoder()
        return recentURLs.compactMap { entry in
            let url = entry.0
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(LoudnessTrackRecord.self, from: data),
                  record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion else {
                return nil
            }
            return record
        }
    }

    func load(id: UUID) -> LoudnessTrackRecord? {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LoudnessTrackRecord.self, from: data),
              record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion else { return nil }
        return record
    }

    func store(_ record: LoudnessTrackRecord) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let url = rootURL.appendingPathComponent("\(record.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
    }
}

private nonisolated struct LoudnessWorkerOutcome: Sendable {
    let record: LoudnessTrackRecord
    let failure: String?
}

/// Library-scoped offline loudness scanner and derived-cache owner.
/// All file decoding runs on one utility worker at a time; playback lookups
/// only inspect the in-memory snapshot and current file identity.
@MainActor
final class LibraryLoudnessService {
    private static let maximumInMemoryRecords = 256

    private let cache: LoudnessDerivedCache
    private var records: [UUID: LoudnessTrackRecord] = [:]
    private var recordLRU: [UUID] = []
    private var pendingCacheLoads: Set<UUID> = []
    private var hasLoadedSnapshot = false
    private var activeTrackID: UUID?
    private var activeWorker: Task<LoudnessWorkerOutcome, Error>?
    private var isScanning = false
    private var isClosed = false
    private var playbackAACGaplessTrimEnabled = false

    var onMissingMeasurement: (@MainActor (UUID) -> Void)?

    init(libraryPaths: LibraryPaths) {
        cache = LoudnessDerivedCache(
            rootURL: libraryPaths.cacheRootURL.appendingPathComponent("Loudness", isDirectory: true)
        )
    }

    func loadSnapshot() async {
        guard !isClosed else { return }
        do {
            let loaded = try await cache.loadRecent(limit: Self.maximumInMemoryRecords)
            guard !isClosed else { return }
            for record in loaded { insert(record) }
            hasLoadedSnapshot = true
        } catch {
            if !isClosed { hasLoadedSnapshot = true }
        }
    }

    /// Returns the raw cache projection requested by callers. File identity
    /// validation is intentionally performed at playback use, not by this read.
    func recordsSnapshot(trackIDs: [UUID]) -> [UUID: LoudnessTrackRecord] {
        guard !trackIDs.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: Set(trackIDs).compactMap { id in
            records[id].map { (id, $0) }
        })
    }

    func loadRecordsSnapshot(trackIDs: [UUID]) async -> [UUID: LoudnessTrackRecord] {
        guard !isClosed else { return [:] }
        var seen = Set<UUID>()
        var result: [UUID: LoudnessTrackRecord] = [:]
        for id in trackIDs where seen.insert(id).inserted {
            guard !isClosed else { break }
            if let record = records[id] {
                touch(id)
                result[id] = record
            } else if let record = await cache.load(id: id) {
                guard !isClosed else { break }
                insert(record)
                if let current = records[id] { result[id] = current }
            }
        }
        return result
    }

    func updatePlaybackTrimPolicy(enabled: Bool) {
        playbackAACGaplessTrimEnabled = enabled
    }

    func gainDecision(
        track: Track,
        fileURL: URL,
        configuration: AudioLoudnessConfiguration,
        albumTracks: [Track]?,
        continuousAlbum: Bool
    ) -> LoudnessGainDecision {
        guard configuration.enabled else { return .unity(source: "disabled") }

        let wantsAlbum = configuration.mode == "album"
            || (configuration.mode == "auto" && continuousAlbum)
        if wantsAlbum {
            return albumGainDecision(
                track: track,
                fileURL: fileURL,
                configuration: configuration,
                albumTracks: albumTracks,
                shouldScheduleMissing: configuration.allowBackgroundScan
            )
        }

        let currentIdentity = try? Self.fileIdentity(for: fileURL)
        let trimSnapshot = playbackAACGaplessTrimEnabled
        let cachedRecord = records[track.id]
        let record: LoudnessTrackRecord?
        if let cachedRecord, let currentIdentity,
           Self.isCurrent(cachedRecord, for: currentIdentity, playbackAACGaplessTrimEnabled: trimSnapshot) {
            touch(track.id)
            record = cachedRecord
        } else {
            record = nil
            if let currentIdentity {
                if cachedRecord != nil {
                    if configuration.allowBackgroundScan { onMissingMeasurement?(track.id) }
                } else {
                    requestCacheRecordLoad(
                        trackID: track.id,
                        identity: currentIdentity,
                        trimSnapshot: trimSnapshot,
                        shouldScheduleMissing: configuration.allowBackgroundScan
                    )
                }
            }
        }

        var decision = LoudnessGainSelector.trackGain(
            configuration: configuration,
            measurement: record?.measurement,
            metadata: record?.metadata
        )
        if record == nil {
            let diagnostic = DSPDiagnostic(
                code: currentIdentity == nil ? "audio.loudnessFileIdentityUnavailable" : "audio.loudnessCacheMissingOrStale",
                message: currentIdentity == nil
                    ? "The current file identity could not be read, so cached loudness was not used."
                    : (cachedRecord != nil
                        ? "The cached loudness record does not match this file or analysis policy."
                        : (hasLoadedSnapshot
                            ? "No loudness record is loaded for this track yet."
                            : "The loudness cache snapshot is still loading.")),
                fieldPath: "loudness.cache",
                retryable: configuration.allowBackgroundScan
            )
            decision.diagnostics.append(diagnostic)
        }
        return decision
    }

    func scan(
        trackIDs: [UUID],
        reporter: LibraryAutomationJobReporter,
        trackProvider: @escaping @MainActor (UUID) -> Track?
    ) async {
        guard !isClosed else { return }
        var seen = Set<UUID>()
        let targets = trackIDs.filter { seen.insert($0).inserted }
        guard !targets.isEmpty else { return }
        guard !isScanning else {
            for id in targets {
                reporter.recordFailure("Another loudness scan is already active; this Job did not take ownership of its target.", itemID: id)
            }
            return
        }
        isScanning = true
        defer { isScanning = false }
        var completedCount = 0
        var availableMeasurementCount = 0
        var unavailableMeasurementCount = 0

        for (index, trackID) in targets.enumerated() {
            if Task.isCancelled || isClosed {
                for pendingID in targets[index...] {
                    reporter.recordFailure("The loudness scan was cancelled before this item started.", itemID: pendingID)
                }
                break
            }
            activeTrackID = trackID
            reporter.recordProgress(
                completedCount: completedCount,
                totalCount: targets.count,
                phase: "Analyzing"
            )

            guard let track = trackProvider(trackID) else {
                reporter.recordFailure("The requested track is no longer in this library.", itemID: trackID)
                completedCount += 1
                activeTrackID = nil
                continue
            }

            let resolution = track.resolveFileURL()
            guard let fileURL = resolution.url else {
                resolution.lease.release()
                reporter.recordFailure("The track source could not be opened with its current library locator.", itemID: trackID)
                completedCount += 1
                activeTrackID = nil
                continue
            }

            do {
                let beforeIdentity = try Self.fileIdentity(for: fileURL)
                let trimSnapshot = playbackAACGaplessTrimEnabled
                let worker = Task.detached(priority: .utility) {
                    try await Self.analyze(
                        trackID: trackID,
                        url: fileURL,
                        identity: beforeIdentity,
                        playbackAACGaplessTrimEnabled: trimSnapshot
                    )
                }
                activeWorker = worker
                let outcome = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                activeWorker = nil

                let afterIdentity = try Self.fileIdentity(for: fileURL)
                guard beforeIdentity == afterIdentity,
                      trimSnapshot == playbackAACGaplessTrimEnabled else {
                    reporter.recordFailure("The file or playback trim policy changed during loudness analysis; its result was discarded.", itemID: trackID)
                    completedCount += 1
                    activeTrackID = nil
                    resolution.lease.release()
                    continue
                }

                insert(outcome.record)
                if outcome.record.measurement?.status == .available {
                    availableMeasurementCount += 1
                } else {
                    unavailableMeasurementCount += 1
                }
                do {
                    try await cache.store(outcome.record)
                } catch {
                    reporter.recordFailure("The loudness result was measured but could not be saved to the library cache.", itemID: trackID)
                }
                if let failure = outcome.failure {
                    reporter.recordFailure(failure, itemID: trackID)
                }
                resolution.lease.release()
                completedCount += 1
                activeTrackID = nil
                reporter.recordCheckpoint("Analyzed \(completedCount) item(s)")
            } catch is CancellationError {
                activeWorker = nil
                resolution.lease.release()
                reporter.recordFailure("The loudness scan was cancelled before this item completed.", itemID: trackID)
                completedCount += 1
                activeTrackID = nil
                for pendingID in targets.dropFirst(completedCount) {
                    reporter.recordFailure("The loudness scan was cancelled before this item started.", itemID: pendingID)
                }
                break
            } catch {
                activeWorker = nil
                resolution.lease.release()
                reporter.recordFailure("The source could not be measured: \(error.localizedDescription)", itemID: trackID)
                completedCount += 1
                activeTrackID = nil
            }
        }

        reporter.recordResult(.object([
            "operationType": .string(AutomationMethod.audioLoudnessAnalyze),
            "trackIDs": .array(targets.map { .string($0.uuidString) }),
            "processedCount": .number(Double(completedCount)),
            "availableMeasurementCount": .number(Double(availableMeasurementCount)),
            "unavailableMeasurementCount": .number(Double(unavailableMeasurementCount)),
            "fixtureValidated": .boolean(false),
            "currentPlaybackUnchanged": .boolean(true)
        ]))
        reporter.recordProgress(
            completedCount: completedCount,
            totalCount: max(targets.count, 1),
            phase: "Finished"
        )
    }

    func cancel() {
        isClosed = true
        onMissingMeasurement = nil
        activeWorker?.cancel()
        activeWorker = nil
        activeTrackID = nil
        pendingCacheLoads.removeAll(keepingCapacity: false)
    }

    private func albumGainDecision(
        track: Track,
        fileURL: URL,
        configuration: AudioLoudnessConfiguration,
        albumTracks: [Track]?,
        shouldScheduleMissing: Bool
    ) -> LoudnessGainDecision {
        guard !track.albumGroupKey.isEmpty, var members = albumTracks, !members.isEmpty else {
            return .unity(source: "unity.albumIncomplete", diagnostic: DSPDiagnostic(
                code: "audio.loudnessAlbumUnavailable",
                message: "A complete album group is required for album normalization.",
                fieldPath: "loudness.album",
                retryable: shouldScheduleMissing
            ))
        }
        if !members.contains(where: { $0.id == track.id }) { members.append(track) }
        members = members.filter { $0.albumGroupKey == track.albumGroupKey }
        guard members.contains(where: { $0.id == track.id }) else {
            return .unity(source: "unity.albumIncomplete")
        }

        var resolvedRecords: [LoudnessTrackRecord] = []
        var missingOrStale: [UUID] = []
        var waitingForCache: Set<UUID> = []
        resolvedRecords.reserveCapacity(members.count)

        func inspectCachedRecord(for member: Track, identity: LoudnessFileIdentity) {
            if let candidate = records[member.id] {
                if Self.isCurrent(
                    candidate,
                    for: identity,
                    playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled
                ) {
                    touch(member.id)
                    resolvedRecords.append(candidate)
                } else {
                    missingOrStale.append(member.id)
                }
            } else {
                requestCacheRecordLoad(
                    trackID: member.id,
                    identity: identity,
                    trimSnapshot: playbackAACGaplessTrimEnabled,
                    shouldScheduleMissing: shouldScheduleMissing
                )
                waitingForCache.insert(member.id)
            }
        }

        for member in members {
            if member.id == track.id {
                guard let identity = try? Self.fileIdentity(for: fileURL) else {
                    missingOrStale.append(member.id)
                    continue
                }
                inspectCachedRecord(for: member, identity: identity)
            } else {
                let resolution = member.resolveFileURL()
                defer { resolution.lease.release() }
                guard let resolvedURL = resolution.url else {
                    missingOrStale.append(member.id)
                    continue
                }
                guard let identity = try? Self.fileIdentity(for: resolvedURL) else {
                    missingOrStale.append(member.id)
                    continue
                }
                inspectCachedRecord(for: member, identity: identity)
            }
        }

        if !missingOrStale.isEmpty || !waitingForCache.isEmpty {
            if shouldScheduleMissing {
                for id in missingOrStale { onMissingMeasurement?(id) }
            }
            return .unity(source: "unity.albumIncomplete", diagnostic: DSPDiagnostic(
                code: "audio.loudnessAlbumUnavailable",
                message: "Every member of the album needs a current loudness record before one shared gain can be applied.",
                fieldPath: "loudness.album",
                retryable: shouldScheduleMissing
            ))
        }

        guard resolvedRecords.count == members.count else { return .unity(source: "unity.albumIncomplete") }
        let measurements = resolvedRecords.compactMap(\.measurement)
        if measurements.count == resolvedRecords.count,
           measurements.allSatisfy({ $0.status == .available }) {
            return LoudnessGainSelector.albumGain(
                configuration: configuration,
                measurements: measurements,
                metadata: resolvedRecords.map(\.metadata)
            )
        }
        return LoudnessGainSelector.albumGain(
            configuration: configuration,
            measurements: [],
            metadata: resolvedRecords.map(\.metadata)
        )
    }

    private func insert(_ record: LoudnessTrackRecord) {
        if let current = records[record.id], current.analyzedAt >= record.analyzedAt {
            touch(record.id)
            return
        }
        records[record.id] = record
        touch(record.id)
        while recordLRU.count > Self.maximumInMemoryRecords {
            let evicted = recordLRU.removeFirst()
            records.removeValue(forKey: evicted)
        }
    }

    private func touch(_ id: UUID) {
        recordLRU.removeAll { $0 == id }
        recordLRU.append(id)
    }

    private func requestCacheRecordLoad(
        trackID: UUID,
        identity: LoudnessFileIdentity,
        trimSnapshot: Bool,
        shouldScheduleMissing: Bool
    ) {
        guard pendingCacheLoads.insert(trackID).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await cache.load(id: trackID)
            pendingCacheLoads.remove(trackID)
            guard !isClosed else { return }
            if let loaded { insert(loaded) }
            let currentRecordMatchesSnapshot = records[trackID].map {
                Self.isCurrent($0, for: identity, playbackAACGaplessTrimEnabled: trimSnapshot)
            } ?? false
            guard shouldScheduleMissing, !currentRecordMatchesSnapshot else { return }
            onMissingMeasurement?(trackID)
        }
    }

    private static func isCurrent(
        _ record: LoudnessTrackRecord,
        for identity: LoudnessFileIdentity,
        playbackAACGaplessTrimEnabled: Bool
    ) -> Bool {
        guard record.cacheRecordVersion == LoudnessTrackRecord.currentCacheRecordVersion,
              record.metadataParserVersion == LoudnessMetadata.currentParserVersion,
              record.playbackAACGaplessTrimEnabled == playbackAACGaplessTrimEnabled,
              record.fileIdentity == identity else { return false }
        guard let measurement = record.measurement else { return true }
        return measurement.analyzerVersion == LoudnessMeasurement.currentAnalyzerVersion
            && measurement.decoderRuleVersion == LoudnessMeasurement.currentDecoderRuleVersion
            && measurement.trimPolicyVersion == LoudnessMeasurement.currentTrimPolicyVersion
            && measurement.analysisFrameRange == "renderer-decoded-range-v2"
            && measurement.playbackAACGaplessTrimEnabled == playbackAACGaplessTrimEnabled
    }

    private nonisolated static func fileIdentity(for url: URL) throws -> LoudnessFileIdentity {
        let standardizedURL = url.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown)
        }
        let time = modificationDate.timeIntervalSince1970 * 1_000_000_000
        guard time.isFinite, time >= Double(Int64.min), time <= Double(Int64.max) else {
            throw CocoaError(.fileReadUnknown)
        }
        let digest = SHA256.hash(data: Data(standardizedURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LoudnessFileIdentity(
            pathDigest: digest,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            fileSize: Int64(fileSize),
            modificationTimeNanoseconds: Int64(time.rounded())
        )
    }

    private nonisolated static func analyze(
        trackID: UUID,
        url: URL,
        identity: LoudnessFileIdentity,
        playbackAACGaplessTrimEnabled: Bool
    ) async throws -> LoudnessWorkerOutcome {
        try Task.checkCancellation()
        var metadata = await readMetadata(from: url)
        try Task.checkCancellation()

        var measurement: LoudnessMeasurement?
        var failure: String?
        do {
            let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let dspFormat = Self.dspFormat(for: audioFile)
            guard dspFormat.channelCount > 0, dspFormat.channelCount <= 64 else {
                throw LoudnessScanError.unsupportedChannelCount
            }
            let range = AACDecodedFrameRange.resolve(metadata: AACGaplessMetadata.read(url: url),
                decodedFrames: audioFile.length, enabled: playbackAACGaplessTrimEnabled)
            audioFile.framePosition = range.startingFrame
            let endFrame = range.startingFrame + range.frameCount
            let analyzer = LoudnessAnalyzer(format: dspFormat)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: 8_192
            ) else {
                throw LoudnessScanError.bufferAllocationFailed
            }

            while audioFile.framePosition < endFrame {
                try Task.checkCancellation()
                let remaining = endFrame - audioFile.framePosition
                let requestedFrames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                guard requestedFrames > 0 else { break }
                try audioFile.read(into: buffer, frameCount: requestedFrames)
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { break }
                guard let channelData = buffer.floatChannelData else {
                    throw LoudnessScanError.floatPCMUnavailable
                }
                analyzer.append(channelData: UnsafePointer(channelData), frameCount: frameCount)
            }
            var result = analyzer.finish(playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled)
            let analyzedFrames = result.analyzedFrameCount
            guard analyzedFrames == range.frameCount else { throw LoudnessScanError.incompleteDecodedRange }
            result.validStartFrame = range.startingFrame
            result.validEndFrame = range.startingFrame + analyzedFrames
            result.analysisFrameRange = "renderer-decoded-range-v2"
            if range.reason != "fullFile" && !range.isTrimmed {
                result.diagnostics.append(DSPDiagnostic(code: "audio.loudnessTrimFallback",
                    message: "AAC crop metadata did not match the decoded range; playback and analysis use the complete decoded file.",
                    fieldPath: "loudness.analysisFrameRange"))
            }
            measurement = result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = "Audio decoding failed; the source metadata was retained without a PCM measurement."
            metadata.diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessDecodeFailed",
                message: "The file metadata was retained, but decoded PCM was unavailable for loudness measurement.",
                fieldPath: "loudness.measurement",
                retryable: true
            ))
        }

        return LoudnessWorkerOutcome(
            record: LoudnessTrackRecord(
                id: trackID,
                cacheRecordVersion: LoudnessTrackRecord.currentCacheRecordVersion,
                metadataParserVersion: LoudnessMetadata.currentParserVersion,
                playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled,
                fileIdentity: identity,
                measurement: measurement,
                metadata: metadata,
                analyzedAt: Date()
            ),
            failure: failure
        )
    }

    private nonisolated static func readMetadata(from url: URL) async -> LoudnessMetadata {
        let asset = AVURLAsset(url: url)
        var tags: [LoudnessMetadataTag] = []
        var readFailed = false
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                try Task.checkCancellation()
                let items = try await asset.loadMetadata(for: format)
                for item in items {
                    guard let key = item.identifier?.rawValue
                            ?? (item.key as? String)
                            ?? item.commonKey?.rawValue else { continue }
                    let stringValue = try? await item.load(.stringValue)
                    let value: String?
                    if let stringValue {
                        value = stringValue
                    } else {
                        value = (try? await item.load(.numberValue))?.stringValue
                    }
                    guard let value else { continue }
                    tags.append(LoudnessMetadataTag(key: key, value: value))
                }
            }
        } catch is CancellationError {
            return .empty
        } catch {
            readFailed = true
        }
        let metadata = LoudnessMetadataParser.parse(
            tags: tags,
            containerHint: containerHint(for: url)
        )
        guard readFailed else { return metadata }
        var result = metadata
        result.diagnostics.append(DSPDiagnostic(
            code: "audio.loudnessMetadataReadFailed",
            message: "Container normalization metadata could not be read; the PCM scan remains authoritative.",
            fieldPath: "loudness.metadata",
            retryable: true
        ))
        return result
    }

    private nonisolated static func containerHint(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "opus": return "opus"
        case "mp3", "flac", "wav", "wave", "aif", "aiff", "m4a", "mp4", "caf":
            return url.pathExtension.lowercased()
        default:
            return "unknown"
        }
    }

    private nonisolated static func dspFormat(for audioFile: AVAudioFile) -> DSPAudioFormat {
        let processingFormat = audioFile.processingFormat
        let processingDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: processingFormat)
        guard processingFormat.channelLayout == nil,
              audioFile.fileFormat.channelLayout != nil else { return processingDSPFormat }
        let fileDSPFormat = CMSampleBufferFactory.dspAudioFormat(from: audioFile.fileFormat)
        guard fileDSPFormat.channelCount == Int(processingFormat.channelCount),
              let sourceLayout = fileDSPFormat.rawLayoutData else { return processingDSPFormat }
        return DSPAudioFormat(
            sampleRate: processingFormat.sampleRate,
            channelCount: Int(processingFormat.channelCount),
            rawLayoutData: sourceLayout,
            channelLabels: fileDSPFormat.channelLabels,
            layoutIsKnown: fileDSPFormat.layoutIsKnown
        )
    }
}

private nonisolated enum LoudnessScanError: LocalizedError {
    case incompleteDecodedRange
    case unsupportedChannelCount
    case bufferAllocationFailed
    case floatPCMUnavailable

    var errorDescription: String? {
        switch self {
        case .incompleteDecodedRange:
            "The decoder ended before the complete playback frame range was measured."
        case .unsupportedChannelCount:
            "The decoded source channel count is outside the supported bounded range."
        case .bufferAllocationFailed:
            "A bounded PCM analysis buffer could not be allocated."
        case .floatPCMUnavailable:
            "The decoder did not provide planar Float32 PCM."
        }
    }
}
