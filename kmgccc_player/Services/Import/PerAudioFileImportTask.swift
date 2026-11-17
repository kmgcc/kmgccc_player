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
            if let embedded = await ImportMetadataExtractor.extractArtwork(from: candidate.fileURL) { return embedded }
            guard candidate.discoveredFile.mediaSelection != nil else { return nil }
            return ImportMetadataExtractor.extractProgramFolderArtwork(beside: candidate.fileURL)
        }()
        // Managed NCM progress IDs retain the encrypted source path;
        // fileURL points to a temporary decrypted audio product.
        let originalSourceURL = placement.storageKind == .managed
            && URL(fileURLWithPath: candidate.progressID).pathExtension.lowercased() == "ncm"
            ? URL(fileURLWithPath: candidate.progressID) : candidate.fileURL
        async let localLyricsTask: String? = {
            if candidate.discoveredFile.mediaSelection != nil {
                let title = candidate.metadata.title.replacingOccurrences(of: "/", with: "_")
                let perTrackURL = originalSourceURL.deletingLastPathComponent()
                    .appendingPathComponent(title).appendingPathExtension(originalSourceURL.pathExtension)
                guard perTrackURL != originalSourceURL else { return nil }
                return await LocalLyricsImporter.sidecarTTML(forAudioAt: perTrackURL)
            }
            return await LocalLyricsImporter.ttmlForImportedAudio(at: originalSourceURL,
                embeddedLyrics: candidate.metadata.lyrics)
        }()

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
            let preparedURL: URL
            if case .managed(let stagedURL, _) = placement { preparedURL = stagedURL }
            else { preparedURL = candidate.fileURL }
            let audioURL = videoMusic?.audioURL ?? preparedURL
            let duration = videoMusic?.duration ?? candidate.metadata.duration
            do {
                try Self.ensureAudioIsDecodable(
                    audioURL,
                    knownDuration: duration,
                    selection: candidate.discoveredFile.mediaSelection
                )
            } catch {
                // A file that is still being copied into a monitored folder can
                // fail the decode probe and read cleanly a moment later. Wait
                // for the write to settle and probe once more, instead of
                // telling the user that a healthy song cannot be decoded.
                let before = Self.fileState(audioURL)
                guard await Self.waitForFileToSettle(audioURL),
                      Self.fileState(audioURL) != before else {
                    throw error
                }
                try Self.ensureAudioIsDecodable(
                    audioURL,
                    knownDuration: duration,
                    selection: candidate.discoveredFile.mediaSelection
                )
            }
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
            var audioProperties = candidate.audioPropertiesOverride
                ?? Self.readAudioProperties(
                    for: audioURL,
                    durationSeconds: duration
                )
            if let selection = candidate.discoveredFile.mediaSelection {
                var properties = audioProperties ?? TrackAudioProperties()
                properties.mediaSelection = selection
                audioProperties = properties
            }
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
            var stagedAssets: [ImportStagedAssetFile]
            if let motionURL = videoMusic?.motionURL, let asset = motionArtwork?.assets.first {
                stagedAssets = [.init(stagedURL: motionURL, libraryRelativePath: asset.relativePath)]
            } else {
                stagedAssets = []
            }
            if candidate.discoveredFile.mediaSelection != nil || candidate.fileURL.pathExtension.lowercased() == "wv",
               case .managed(let stagedURL, let relativePath) = placement {
                let folder = stagedURL.deletingLastPathComponent()
                let companions: [URL]
                if candidate.discoveredFile.mediaSelection != nil {
                    companions = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                } else {
                    let correction = stagedURL.deletingPathExtension().appendingPathExtension("wvc")
                    companions = FileManager.default.fileExists(atPath: correction.path) ? [correction] : []
                }
                let parent = (relativePath as NSString).deletingLastPathComponent
                for companion in companions where companion != stagedURL {
                    let destination = candidate.discoveredFile.mediaSelection == nil
                        ? (relativePath as NSString).deletingPathExtension + ".wvc"
                        : "\(parent)/\(companion.lastPathComponent)"
                    stagedAssets.append(.init(stagedURL: companion, libraryRelativePath: destination))
                }
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

    /// Size and modification date of a file. Two reads are compared to tell a
    /// finished copy from one that is still being written.
    nonisolated static func fileState(_ url: URL) -> FileState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileState(size: size, modifiedAt: modifiedAt)
    }

    nonisolated struct FileState: Equatable, Sendable {
        let size: Int64
        let modifiedAt: Date
    }

    /// Waits until two consecutive reads agree. Bounded, so a file that is
    /// genuinely unreadable is still reported instead of blocking the import.
    nonisolated static func waitForFileToSettle(
        _ url: URL,
        timeout: TimeInterval = 3,
        pollInterval: UInt64 = 150_000_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = fileState(url)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            let current = fileState(url)
            if let current, current == previous { return true }
            previous = current
        }
        return false
    }

    /// Probe the same decoder used by playback, including a small PCM read.
    /// AVAsset reporting a duration is not evidence that Core Audio can decode
    /// the media; video containers previously slipped through that shortcut.
    nonisolated static func ensureAudioIsDecodable(
        _ url: URL,
        knownDuration: Double,
        selection: AudioMediaSelection? = nil
    ) throws {
        do {
            _ = try AudioDecoderFactory.probe(url, selection: selection)
        } catch {
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
        guard let resource = try? AudioDecoderFactory.open(url),
              (try? resource.provider.nextChunk(maxFrames: 256)) != nil else { return nil }
        var properties = resource.info.audioProperties
        properties.format = url.pathExtension.uppercased()
        let duration = Double(resource.length) / resource.sampleRate
        if duration > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            properties.bitrateKbps = Int((Double(size) * 8 / duration / 1000).rounded())
        }
        return properties
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
