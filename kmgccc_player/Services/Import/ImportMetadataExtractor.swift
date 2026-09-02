//
//  ImportMetadataExtractor.swift
//  kmgccc_player
//
//  §16 extraction: metadata/artwork reading moved verbatim out of
//  FileImportService. Pure static surface so the planner (candidate
//  preparation) and the per-file import task can share one implementation.
//  Wave-4 will extend `metadataFields`; keep this API shape stable.
//

import AVFoundation
import CoreServices
import Foundation

/// Reads title/artist/album/duration/lyrics and embedded artwork from an
/// audio file. All methods are nonisolated statics so TaskGroup workers can
/// call them concurrently.
nonisolated enum ImportMetadataExtractor {
    /// Extract metadata from audio file using AVAsset.
    /// Nonisolated static to allow concurrent execution from TaskGroup.
    nonisolated static func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, albumArtist: String?, duration: Double,
        lyrics: String?, tagFields: ExtractedMetadataFields
    ) {
        let asset = AVURLAsset(url: url)

        var fields = ExtractedMetadataFields()
        var duration: Double = 0

        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            Log.warning("[Import] duration load via AVURLAsset failed: \(error.localizedDescription)", category: .import)
        }

        // Fallback: some containers (notably bare ADTS `.aac` streams) don't
        // report a usable duration through AVURLAsset. Ask Core Audio directly
        // before giving up, so we never persist a 0-second track for a file
        // that is actually decodable.
        if !(duration > 0) || !duration.isFinite {
            if let audioFile = try? AVAudioFile(forReading: url) {
                let sampleRate = audioFile.processingFormat.sampleRate
                if sampleRate > 0 {
                    duration = Double(audioFile.length) / sampleRate
                }
            }
        }

        do {
            let common = try await asset.load(.commonMetadata)
            fields = await metadataFields(byApplying: common, to: fields)
        } catch {
            Log.warning("[Import] common metadata load failed: \(error.localizedDescription)", category: .import)
        }
        do {
            let full = try await asset.load(.metadata)
            fields = await metadataFields(byApplying: full, to: fields)
        } catch {
            Log.warning("[Import] full metadata load failed: \(error.localizedDescription)", category: .import)
        }

        // 4. Fallback: Try Spotlight Metadata (MDItem) if AVAsset failed
        // This handles cases where file has atypical tags or is only recognized by system indexers
        if fields.title == nil || fields.artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                // Title
                if fields.title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        fields.title = mdTitle
                    }
                }

                // Artist (Authors)
                if fields.artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        fields.artist = firstAuthor
                    }
                }

                // Album
                if fields.album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        fields.album = mdAlbum
                    }
                }
            }
        }

        // Apply defaults
        let finalTitle = fields.title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = fields.artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = fields.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalAlbumArtist = fields.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            finalTitle,
            finalArtist,
            finalAlbum,
            finalAlbumArtist?.isEmpty == true ? nil : finalAlbumArtist,
            duration,
            fields.lyrics,
            fields
        )
    }

    /// Extract artwork from audio file.
    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        do {
            let common = try await asset.load(.commonMetadata)
            if let data = await normalizedArtworkData(in: common) {
                return data
            }
        } catch {
            Log.warning("[Import] common artwork metadata load failed: \(error.localizedDescription)", category: .import)
        }
        do {
            let full = try await asset.load(.metadata)
            if let data = await normalizedArtworkData(in: full) {
                return data
            }
        } catch {
            Log.warning("[Import] full artwork metadata load failed: \(error.localizedDescription)", category: .import)
        }

        return nil
    }

    nonisolated struct ExtractedMetadataFields: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var lyrics: String?
        var musicBrainzReleaseID: String?
        var compilation: Bool?
        var releaseYear: Int?
    }

    nonisolated private static func metadataFields(
        byApplying items: [AVMetadataItem],
        to existingFields: ExtractedMetadataFields
    ) async -> ExtractedMetadataFields {
        var fields = existingFields

        for item in items {
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if fields.title == nil { fields.title = try? await item.load(.stringValue) }
                case "artist":
                    if fields.artist == nil { fields.artist = try? await item.load(.stringValue) }
                case "albumName":
                    if fields.album == nil { fields.album = try? await item.load(.stringValue) }
                case "albumArtist":
                    if fields.albumArtist == nil { fields.albumArtist = try? await item.load(.stringValue) }
                case "lyrics":
                    if fields.lyrics == nil { fields.lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            if let keyString = (item.key as? String)?.uppercased() {
                if fields.title == nil && keyString == "TITLE" {
                    fields.title = try? await item.load(.stringValue)
                }
                if fields.artist == nil && keyString == "ARTIST" {
                    fields.artist = try? await item.load(.stringValue)
                }
                if fields.album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    fields.album = try? await item.load(.stringValue)
                }
                if fields.albumArtist == nil
                    && (keyString == "ALBUMARTIST" || keyString == "ALBUM ARTIST"
                        || keyString == "ALBUM_ARTIST")
                {
                    fields.albumArtist = try? await item.load(.stringValue)
                }
                if fields.lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    fields.lyrics = try? await item.load(.stringValue)
                }
            }

            if fields.lyrics == nil,
               let identifier = item.identifier?.rawValue,
               identifier == "id3/USLT" {
                fields.lyrics = try? await item.load(.stringValue)
            }
        }

        if fields.musicBrainzReleaseID == nil {
            fields.musicBrainzReleaseID = await musicBrainzReleaseID(in: items)
        }
        if fields.compilation == nil {
            fields.compilation = await compilationFlag(in: items)
        }
        if fields.releaseYear == nil {
            fields.releaseYear = await releaseYear(in: items)
        }

        return fields
    }

    // MARK: - §10.3/§10.4 evidence frames

    private static let musicBrainzUUIDPattern =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    /// MusicBrainz writes its release id into freeform comment frames, not
    /// into any standardized tag. ID3v2 carries it in TXXX frames whose
    /// description ("MusicBrainz Album Id"/"MusicBrainz Release Id") and UUID
    /// value AVFoundation collapses onto the same generic "TXXX" item, and
    /// iTunes-style files carry it in a ----:com.apple.iTunes:… freeform key.
    /// Neither channel has a dedicated commonKey, so the marker is matched
    /// case-insensitively across the combined key/description/value text and
    /// the trailing UUID-ish token is extracted.
    nonisolated static func musicBrainzReleaseID(in items: [AVMetadataItem]) async -> String? {
        for item in items {
            let keySpace = item.keySpace?.rawValue.lowercased()
            let rawKey = (item.key as? String) ?? ""
            let identifier = item.identifier?.rawValue ?? ""

            let isID3TXXX = keySpace == "id3"
                && (rawKey.uppercased().contains("TXXX") || identifier.uppercased().contains("TXXX"))
            let isITunesFreeform = (keySpace == "its" || keySpace == "----")
                && (rawKey.hasPrefix("----") || identifier.lowercased().hasPrefix("its/----"))
            guard isID3TXXX || isITunesFreeform else { continue }

            let value = (try? await item.load(.stringValue)) ?? ""
            let combinedText = "\(rawKey)\(identifier)\(item.commonKey?.rawValue ?? "")\(value)"
            guard combinedText.localizedCaseInsensitiveContains("musicbrainz") else { continue }

            if let range = value.range(of: musicBrainzUUIDPattern, options: .regularExpression) {
                return String(value[range])
            }
        }
        return nil
    }

    /// Compilation indicators: ID3 "TCMP" (text frame, "1"/"0") and the iTunes
    /// "CPIL" flag. Both spellings are trusted; the first one found wins.
    nonisolated static func compilationFlag(in items: [AVMetadataItem]) async -> Bool? {
        for item in items {
            let keySpace = item.keySpace?.rawValue.lowercased()
            let rawKey = ((item.key as? String) ?? "").uppercased()
            let isIndicatorFrame =
                (keySpace == "id3" && rawKey == "TCMP")
                || (keySpace == "its" && rawKey == "CPIL")
            guard isIndicatorFrame else { continue }

            if let number = try? await item.load(.numberValue) {
                return number != 0
            }
            guard let text = try? await item.load(.stringValue) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "1" { return true }
            if trimmed == "0" { return false }
        }
        return nil
    }

    /// Release year from ID3 "TYER"/"TDRC", the iTunes "©day"/"day" key, or
    /// the common creation-date key as a last resort. TDRC and ©day may carry
    /// a full ISO date, so the first 4-digit group wins.
    nonisolated static func releaseYear(in items: [AVMetadataItem]) async -> Int? {
        for item in items {
            let keySpace = item.keySpace?.rawValue.lowercased()
            let rawKey = ((item.key as? String) ?? "").uppercased()
            let commonKey = item.commonKey?.rawValue
            let isYearFrame =
                (keySpace == "id3" && (rawKey == "TYER" || rawKey == "TDRC"))
                || (keySpace == "its" && (rawKey == "©DAY" || rawKey == "DAY"))
                || commonKey == "creationDate"
            guard isYearFrame else { continue }

            guard let text = try? await item.load(.stringValue) else { continue }
            if let year = Self.firstFourDigitGroup(in: text) {
                return year
            }
        }
        return nil
    }

    nonisolated private static func firstFourDigitGroup(in value: String) -> Int? {
        guard let range = value.range(of: "\\d{4}", options: .regularExpression),
              let year = Int(value[range]),
              (1000...9999).contains(year) else {
            return nil
        }
        return year
    }

    nonisolated private static func normalizedArtworkData(in items: [AVMetadataItem]) async -> Data? {
        for item in items {
            guard let key = item.commonKey?.rawValue, key == "artwork" else { continue }
            guard let data = try? await item.load(.dataValue) else { continue }
            if let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                from: data,
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            ) {
                return normalizedData
            }
            Log.warning("[Import] embedded artwork decode failed", category: .import)
        }

        return nil
    }
}
