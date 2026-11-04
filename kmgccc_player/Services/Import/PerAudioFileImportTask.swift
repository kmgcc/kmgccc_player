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
        // Managed NCM progress IDs retain the encrypted source path;
        // fileURL points to a temporary decrypted audio product.
        let originalSourceURL = placement.storageKind == .managed
            && URL(fileURLWithPath: candidate.progressID).pathExtension.lowercased() == "ncm"
            ? URL(fileURLWithPath: candidate.progressID) : candidate.fileURL
        async let localLyricsTask = LocalLyricsImporter.ttmlForImportedAudio(
            at: originalSourceURL,
            embeddedLyrics: candidate.metadata.lyrics
        )

        var videoMusic: ImportedVideoMusic?
        var generatedReferencedAudioURL: URL?
        var preparedSuccessfully = false
        defer {
            if !preparedSuccessfully {
                if let videoMusic {
                    try? FileManager.default.removeItem(at: videoMusic.audioURL.deletingLastPathComponent())
                }
                if let generatedReferencedAudioURL {
                    try? FileManager.default.removeItem(at: generatedReferencedAudioURL)
                }
            }
        }
        do {
            try await cancellationToken.checkCancellation()
            if AudioFormatSupport.isVideoContainer(candidate.fileURL) {
                videoMusic = try await VideoMusicImporter.prepare(
                    sourceURL: candidate.fileURL,
                    outputDirectory: stagingDirectoryURL,
                    cancellationToken: cancellationToken
                )
            }
            let audioURL = videoMusic?.audioURL ?? candidate.fileURL
            let duration = videoMusic?.duration ?? candidate.metadata.duration
            try Self.ensureAudioIsDecodable(
                audioURL,
                knownDuration: duration
            )
            try await cancellationToken.checkCancellation()

            let embeddedArtworkData = await extractedArtworkTask
            let artworkData = videoMusic?.artworkData ?? embeddedArtworkData
            let ttmlLyricText = await localLyricsTask
            try await cancellationToken.checkCancellation()

            // A cover that exists but cannot survive a large display is not a
            // usable local cover: ask providers for a better one. The embedded
            // image stays as a fallback until a higher-resolution result lands.
            let hasVideoPoster = videoMusic?.artworkData != nil
            let needsOnlineCover = !hasVideoPoster
                && (artworkData.map { ArtworkDataNormalizer.isBelowPreferredResolution($0) } ?? true)

            // §9.2: technical properties of the physical file. NCM outputs
            // already carry bitrate/format from the decrypted header; plain
            // files are probed here while they are open for decode checks.
            let audioProperties = candidate.audioPropertiesOverride
                ?? Self.readAudioProperties(
                    for: audioURL,
                    durationSeconds: duration
                )
            let mediaLocator: TrackMediaLocator
            var stagedAudioURL: URL?
            switch placement {
            case .managed(let stagedURL, let plannedRelativePath):
                let relativePath = videoMusic == nil ? plannedRelativePath : "Tracks/\(trackId.uuidString)/audio.m4a"
                stagedAudioURL = videoMusic?.audioURL ?? stagedURL
                mediaLocator = .managed(libraryRelativePath: relativePath)
            case .referenced(var locator):
                if let videoMusic {
                    guard let directory = candidate.videoOutputDirectoryURL else {
                        throw VideoMusicImportError.parentAuthorizationDenied
                    }
                    let fingerprint = try candidate.discoveredFile.fingerprint
                        ?? ReferencedFileIdentityProvider().fingerprint(for: candidate.fileURL)
                    let source = ReferencedVideoSource(
                        path: candidate.fileURL.path, fingerprint: fingerprint,
                        bookmarkData: locator.fileBookmarkData
                    )
                    let published = try VideoMusicImporter.publishReferencedAudio(
                        from: videoMusic.audioURL, beside: candidate.fileURL,
                        in: directory, source: source
                    )
                    generatedReferencedAudioURL = published
                    locator.fileBookmarkData = try SystemBookmarkResolver().refreshBookmark(for: published)
                    locator.lastKnownPath = published.path
                    locator.fingerprint = try ReferencedFileIdentityProvider().fingerprint(for: published)
                    locator.videoSource = source
                }
                locator.primaryAudioProperties = audioProperties
                mediaLocator = .referenced(locator)
            }
            try await cancellationToken.checkCancellation()
            let motionArtwork = videoMusic?.motionArtwork(trackID: trackId)
            let stagedAssets: [ImportStagedAssetFile]
            if let motionURL = videoMusic?.motionURL, let asset = motionArtwork?.assets.first {
                stagedAssets = [.init(stagedURL: motionURL, libraryRelativePath: asset.relativePath)]
            } else {
                stagedAssets = []
            }
            preparedSuccessfully = true

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
                    duration: duration,
                    importedAt: importedAt,
                    originalFilePath: originalSourceURL.path,
                    mediaLocator: mediaLocator,
                    stagedAudioURL: stagedAudioURL,
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
                            originalFingerprint: originalSourceURL == candidate.discoveredFile.url
                                ? candidate.discoveredFile.fingerprint
                                : try? ReferencedFileIdentityProvider().fingerprint(for: originalSourceURL),
                            contentDigest: nil
                        )
                    }(),
                    embeddedSnapshot: candidate.embeddedSnapshot,
                    audioProperties: audioProperties,
                    enrichmentSuggestions: candidate.enrichmentSuggestions,
                    motionArtwork: motionArtwork,
                    artworkIsUserSelected: hasVideoPoster,
                    stagedAssets: stagedAssets,
                    generatedReferencedAudioURL: generatedReferencedAudioURL
                ),
                needsLyricsEnrichment: ttmlLyricText == nil,
                needsCoverEnrichment: needsOnlineCover,
                needsTrackMetadataEnrichment: true,
                needsArtistMetadataEnrichment: true,
                needsAlbumMetadataEnrichment: true,
                needsArtistArtworkEnrichment: true,
                needsAlbumArtworkEnrichment: true,
                errorDescription: nil
            )
        } catch is CancellationError {
            let _ = await extractedArtworkTask
            let _ = await localLyricsTask
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
            let _ = await localLyricsTask
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

    /// Probe the same decoder used by playback, including a small PCM read.
    /// AVAsset reporting a duration is not evidence that Core Audio can decode
    /// the media; video containers previously slipped through that shortcut.
    nonisolated static func ensureAudioIsDecodable(
        _ url: URL,
        knownDuration: Double
    ) throws {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.processingFormat.sampleRate.isFinite,
                  file.processingFormat.sampleRate > 0,
                  file.processingFormat.channelCount > 0 else {
                throw AudioImportError.undecodable(fileName: url.lastPathComponent)
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(min(file.length, 1_024))
            ) else {
                throw AudioImportError.undecodable(fileName: url.lastPathComponent)
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw AudioImportError.undecodable(fileName: url.lastPathComponent)
            }
        } catch {
            Log.warning(
                "[Import] rejected undecodable file '\(url.lastPathComponent)': \(error.localizedDescription)",
                category: .import
            )
            if error is AudioImportError {
                throw error
            }
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
        var codec = Self.inferredCodec(forPathExtension: url.pathExtension)
        var sampleRateHz: Int?
        var channelCount: Int?
        var bitDepth: Int?

        if let audioFile = try? AVAudioFile(forReading: url) {
            codec = Self.codecName(
                for: audioFile.fileFormat.streamDescription.pointee.mFormatID
            ) ?? codec
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
            codec: codec,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            bitDepth: bitDepth,
            channelCount: channelCount
        )
    }

    /// AVAudioFile exposes the source stream's format id separately from the
    /// decoded processing format. Keep the user-facing names short and stable
    /// so diagnostics can distinguish, for example, M4A/AAC from M4A/ALAC.
    private nonisolated static func codecName(for formatID: AudioFormatID) -> String? {
        let bytes = [
            UInt8((formatID >> 24) & 0xff),
            UInt8((formatID >> 16) & 0xff),
            UInt8((formatID >> 8) & 0xff),
            UInt8(formatID & 0xff)
        ]
        guard let rawTag = String(bytes: bytes, encoding: .ascii) else { return nil }
        switch rawTag.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "aac": return "AAC"
        case ".mp3": return "MP3"
        case "alac": return "ALAC"
        case "lpcm": return "PCM"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorb": return "Vorbis"
        case "ima4": return "IMA4"
        case "ulaw": return "μ-law"
        case "alaw": return "A-law"
        default: return nil
        }
    }

    private nonisolated static func inferredCodec(forPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "mp3": return "MP3"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "wav", "wave", "aif", "aiff": return "PCM"
        default: return nil
        }
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
    let motionArtwork: TrackMotionArtwork?
    let artworkIsUserSelected: Bool
    let stagedAssets: [ImportStagedAssetFile]
    let generatedReferencedAudioURL: URL?

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
        enrichmentSuggestions: [EnrichmentSuggestion]? = nil,
        motionArtwork: TrackMotionArtwork? = nil,
        artworkIsUserSelected: Bool = false,
        stagedAssets: [ImportStagedAssetFile] = [],
        generatedReferencedAudioURL: URL? = nil
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
        self.motionArtwork = motionArtwork
        self.artworkIsUserSelected = artworkIsUserSelected
        self.stagedAssets = stagedAssets
        self.generatedReferencedAudioURL = generatedReferencedAudioURL
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
