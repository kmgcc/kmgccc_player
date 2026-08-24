//
//  PerAudioFileImportTask.swift
//  kmgccc_player
//
//  §16 extraction: the per-file import worker moved verbatim out of
//  FileImportService, together with its payload/output value types and the
//  shared concurrency calculators. Pure statics — no service state.
//

import AVFoundation
import Foundation

/// One file's copy/decode/normalize work executed inside the batch TaskGroup.
/// Produces the payload later turned into a `Track` by the committer.
nonisolated enum PerAudioFileImportTask {
    nonisolated static func performImportTask(
        index: Int,
        candidate: ImportCandidate,
        stagingDirectoryURL: URL,
        cancellationToken: ImportCancellationToken
    ) async -> ImportTaskOutput {
        guard let trackId = candidate.trackID, let placement = candidate.placement else {
            return ImportTaskOutput(
                index: index,
                trackID: UUID(),
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: "Import placement was not prepared"
            )
        }
        let importedAt = Date()
        await LibraryImportCoordinator.shared.beginTrack(trackId)
        defer {
            Task {
                await LibraryImportCoordinator.shared.endTrack(trackId)
            }
        }

        async let extractedArtworkTask: Data? = {
            if let preloadedArtworkData = candidate.metadata.artworkData {
                return ArtworkDataNormalizer.normalizedJPEGData(
                    from: preloadedArtworkData,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
            }
            return await ImportMetadataExtractor.extractArtwork(from: candidate.fileURL)
        }()
        async let embeddedLyricsTask = Self.prepareEmbeddedTTMLLyrics(candidate.metadata.lyrics)

        do {
            try await cancellationToken.checkCancellation()
            try Self.ensureAudioIsDecodable(
                candidate.fileURL,
                knownDuration: candidate.metadata.duration
            )
            try await cancellationToken.checkCancellation()

            let artworkData = await extractedArtworkTask
            let ttmlLyricText = await embeddedLyricsTask
            try await cancellationToken.checkCancellation()

            // §9.2: technical properties of the physical file. NCM outputs
            // already carry bitrate/format from the decrypted header; plain
            // files are probed here while they are open for decode checks.
            let audioProperties = candidate.audioPropertiesOverride
                ?? Self.readAudioProperties(
                    for: candidate.fileURL,
                    durationSeconds: candidate.metadata.duration
                )
            let mediaLocator: TrackMediaLocator
            switch placement {
            case .managed(_, let relativePath):
                mediaLocator = .managed(libraryRelativePath: relativePath)
            case .referenced(var locator):
                locator.primaryAudioProperties = audioProperties
                mediaLocator = .referenced(locator)
            }

            return ImportTaskOutput(
                index: index,
                trackID: trackId,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: ImportedTrackPayload(
                    id: trackId,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    artistCredits: candidate.metadata.artistCredits,
                    album: candidate.metadata.album,
                    albumArtist: candidate.metadata.albumArtist,
                    duration: candidate.metadata.duration,
                    importedAt: importedAt,
                    originalFilePath: candidate.fileURL.path,
                    mediaLocator: mediaLocator,
                    stagedAudioURL: {
                        if case .managed(let stagedURL, _) = placement { return stagedURL }
                        return nil
                    }(),
                    artworkData: artworkData,
                    ttmlLyricText: ttmlLyricText,
                    lyricsText: nil,
                    ncmConversionAssociation: candidate.ncmAssociation,
                    importProvenance: {
                        // Managed copies carry no per-location fingerprint, so
                        // the scanned source fingerprint is captured here for
                        // later rename/move re-import resolution. The digest is
                        // deliberately nil: it is computed on demand only when
                        // a future import cannot be resolved otherwise.
                        guard placement.storageKind == .managed else { return nil }
                        return ImportProvenance(
                            originalFingerprint: candidate.discoveredFile.fingerprint,
                            contentDigest: nil
                        )
                    }(),
                    embeddedSnapshot: candidate.embeddedSnapshot,
                    audioProperties: audioProperties,
                    enrichmentSuggestions: candidate.enrichmentSuggestions
                ),
                needsLyricsEnrichment: ttmlLyricText == nil,
                needsCoverEnrichment: artworkData == nil,
                needsTrackMetadataEnrichment: true,
                needsArtistMetadataEnrichment: true,
                needsAlbumMetadataEnrichment: true,
                needsArtistArtworkEnrichment: true,
                needsAlbumArtworkEnrichment: true,
                errorDescription: nil
            )
        } catch is CancellationError {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                trackID: trackId,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: "已取消"
            )
        } catch {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                trackID: trackId,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func prepareEmbeddedTTMLLyrics(_ embeddedLyrics: String?) async -> String? {
        guard let embeddedLyrics, !embeddedLyrics.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }
        if let ttml = LyricsFormatSupport.normalizedTTMLText(embeddedLyrics) {
            return ttml
        }
        guard LyricsFormatSupport.looksLikeLRC(embeddedLyrics) else {
            Log.warning("[Import] embedded lyrics skipped: unsupported non-TTML/non-LRC format", category: .lyrics)
            return nil
        }
        do {
            let converted = try await TTMLConverter.shared.convertToTTML(
                rawLyrics: embeddedLyrics,
                stripMetadata: true
            )
            guard let ttml = LyricsFormatSupport.normalizedTTMLText(converted) else {
                Log.warning("[Import] embedded lyrics conversion produced invalid TTML", category: .lyrics)
                return nil
            }
            return ttml
        } catch {
            Log.warning("[Import] embedded lyrics conversion failed: \(error.localizedDescription)", category: .lyrics)
            return nil
        }
    }

    /// Final safety net before copying a file into the library: if we never
    /// determined a positive duration, confirm Core Audio can at least open the
    /// file. This turns "silently imported a 0-second broken track" into a
    /// clear, per-file import failure. Files with a known duration short-circuit
    /// (the common case), so valid audio is never rejected here.
    nonisolated static func ensureAudioIsDecodable(
        _ url: URL,
        knownDuration: Double
    ) throws {
        if knownDuration > 0, knownDuration.isFinite { return }
        do {
            _ = try AVAudioFile(forReading: url)
        } catch {
            Log.warning(
                "[Import] rejected undecodable file '\(url.lastPathComponent)': \(error.localizedDescription)",
                category: .import
            )
            throw AudioImportError.undecodable(fileName: url.lastPathComponent)
        }
    }

    /// §9.2 per-location technical properties. Bit depth is only exposed for
    /// PCM streams (compressed containers report 0) and is skipped then;
    /// bitrate is estimated from file size and duration when both are known.
    nonisolated static func readAudioProperties(
        for url: URL,
        durationSeconds: Double
    ) -> TrackAudioProperties? {
        let format = url.pathExtension.uppercased()
        var sampleRateHz: Int?
        var channelCount: Int?
        var bitDepth: Int?

        if let audioFile = try? AVAudioFile(forReading: url) {
            let processingFormat = audioFile.processingFormat
            if processingFormat.sampleRate > 0 {
                sampleRateHz = Int(processingFormat.sampleRate)
            }
            if processingFormat.channelCount > 0 {
                channelCount = Int(processingFormat.channelCount)
            }
            let bitsPerChannel = processingFormat.streamDescription.pointee.mBitsPerChannel
            if bitsPerChannel > 0 {
                bitDepth = Int(bitsPerChannel)
            }
        }

        let bitrateKbps: Int?
        if durationSeconds > 0, durationSeconds.isFinite,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 0 {
            bitrateKbps = Int((Double(fileSize) * 8 / durationSeconds / 1000).rounded())
        } else {
            bitrateKbps = nil
        }

        guard format.isEmpty == false || sampleRateHz != nil || bitrateKbps != nil else {
            return nil
        }
        return TrackAudioProperties(
            format: format.isEmpty ? nil : format,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            bitDepth: bitDepth,
            channelCount: channelCount
        )
    }

    // MARK: - Concurrency calculators

    nonisolated static func metadataConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.metadataReadConcurrency(for: count)
    }

    nonisolated static func ncmConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.ncmConversionConcurrency(for: count)
    }

    nonisolated static func importConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.audioPreparationConcurrency(for: count)
    }

    nonisolated static func enrichmentConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.networkEnrichmentConcurrency(for: count)
    }
}

/// Fully resolved per-file import product handed from the worker to the
/// committer, which turns it into a `Track`.
internal struct ImportedTrackPayload: Sendable {
    let id: UUID
    let title: String
    let artist: String
    let artistCredits: [TrackCredit]?
    let album: String
    let albumArtist: String?
    let duration: Double
    let importedAt: Date
    let originalFilePath: String
    let mediaLocator: TrackMediaLocator
    let stagedAudioURL: URL?
    let artworkData: Data?
    let ttmlLyricText: String?
    let lyricsText: String?
    let ncmConversionAssociation: NCMConversionAssociation?
    let importProvenance: ImportProvenance?
    let embeddedSnapshot: EmbeddedMetadataSnapshot?
    let audioProperties: TrackAudioProperties?
    let enrichmentSuggestions: [EnrichmentSuggestion]?

    nonisolated init(
        id: UUID,
        title: String,
        artist: String,
        artistCredits: [TrackCredit]?,
        album: String,
        albumArtist: String?,
        duration: Double,
        importedAt: Date,
        originalFilePath: String,
        mediaLocator: TrackMediaLocator,
        stagedAudioURL: URL?,
        artworkData: Data?,
        ttmlLyricText: String?,
        lyricsText: String?,
        ncmConversionAssociation: NCMConversionAssociation?,
        importProvenance: ImportProvenance?,
        embeddedSnapshot: EmbeddedMetadataSnapshot? = nil,
        audioProperties: TrackAudioProperties? = nil,
        enrichmentSuggestions: [EnrichmentSuggestion]? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistCredits = artistCredits
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.importedAt = importedAt
        self.originalFilePath = originalFilePath
        self.mediaLocator = mediaLocator
        self.stagedAudioURL = stagedAudioURL
        self.artworkData = artworkData
        self.ttmlLyricText = ttmlLyricText
        self.lyricsText = lyricsText
        self.ncmConversionAssociation = ncmConversionAssociation
        self.importProvenance = importProvenance
        self.embeddedSnapshot = embeddedSnapshot
        self.audioProperties = audioProperties
        self.enrichmentSuggestions = enrichmentSuggestions
    }
}

internal struct ImportTaskOutput: Sendable {
    let index: Int
    let trackID: UUID
    let progressID: String
    let displayName: String
    let metadata: ImportPreview
    let payload: ImportedTrackPayload?
    let needsLyricsEnrichment: Bool
    let needsCoverEnrichment: Bool
    let needsTrackMetadataEnrichment: Bool
    let needsArtistMetadataEnrichment: Bool
    let needsAlbumMetadataEnrichment: Bool
    let needsArtistArtworkEnrichment: Bool
    let needsAlbumArtworkEnrichment: Bool
    let errorDescription: String?
}
