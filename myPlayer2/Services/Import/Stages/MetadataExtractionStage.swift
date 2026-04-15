//
//  MetadataExtractionStage.swift
//  myPlayer2
//

import AVFoundation
import CoreServices
import Foundation

enum MetadataExtractionStage {
    nonisolated static func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, albumArtist: String?, duration: Double,
        lyrics: String?
    ) {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var lyrics: String?
        var duration: Double = 0

        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            Log.warning("Failed to load import duration for \(url.lastPathComponent): \(error)", category: .import)
        }

        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if title == nil { title = try? await item.load(.stringValue) }
                case "artist":
                    if artist == nil { artist = try? await item.load(.stringValue) }
                case "albumName":
                    if album == nil { album = try? await item.load(.stringValue) }
                case "albumArtist":
                    if albumArtist == nil { albumArtist = try? await item.load(.stringValue) }
                case "lyrics":
                    if lyrics == nil { lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            if let keyString = (item.key as? String)?.uppercased() {
                if title == nil && keyString == "TITLE" {
                    title = try? await item.load(.stringValue)
                }
                if artist == nil && keyString == "ARTIST" {
                    artist = try? await item.load(.stringValue)
                }
                if album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    album = try? await item.load(.stringValue)
                }
                if albumArtist == nil
                    && (keyString == "ALBUMARTIST" || keyString == "ALBUM ARTIST"
                        || keyString == "ALBUM_ARTIST")
                {
                    albumArtist = try? await item.load(.stringValue)
                }
                if lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    lyrics = try? await item.load(.stringValue)
                }
            }

            if lyrics == nil,
                let identifier = item.identifier?.rawValue,
                identifier == "id3/USLT"
            {
                lyrics = try? await item.load(.stringValue)
            }
        }

        if title == nil || artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                if title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        title = mdTitle
                    }
                }

                if artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        artist = firstAuthor
                    }
                }

                if album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        album = mdAlbum
                    }
                }
            }
        }

        let finalTitle = title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = album ?? NSLocalizedString("library.unknown_album", comment: "")
        let finalAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            finalTitle,
            finalArtist,
            finalAlbum,
            finalAlbumArtist?.isEmpty == true ? nil : finalAlbumArtist,
            duration,
            lyrics
        )
    }

    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            if let key = item.commonKey?.rawValue, key == "artwork" {
                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        }

        return nil
    }

    nonisolated static func prepareEmbeddedTTMLLyrics(
        _ embeddedLyrics: String?,
        converter: any EmbeddedLyricsTTMLConverting
    ) async -> String? {
        guard let embeddedLyrics, !embeddedLyrics.isEmpty else { return nil }
        if embeddedLyrics.lowercased().contains("<tt") {
            return embeddedLyrics
        }
        return try? await converter.convertToTTML(
            rawLyrics: embeddedLyrics,
            stripMetadata: true
        )
    }
}
