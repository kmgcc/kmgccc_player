//
//  LibraryNormalization.swift
//  myPlayer2
//
//  Normalization rules for runtime grouping and dedup keys.
//

import Foundation

enum LibraryNormalization {
    static let unknownTitle = "未知歌曲"
    static let unknownArtist = "未知歌手"
    static let unknownAlbum = "未知专辑"

    static func normalizeTitle(_ value: String?) -> String {
        normalize(value, fallback: unknownTitle)
    }

    static func normalizeArtist(_ value: String?) -> String {
        normalize(value, fallback: unknownArtist)
    }

    static func normalizeAlbum(_ value: String?) -> String {
        normalize(value, fallback: unknownAlbum)
    }

    static func normalizedDedupKey(title: String?, artist: String?) -> String {
        "\(normalizeTitle(title))•\(normalizeArtist(artist))"
    }

    static func normalizedAlbumKey(album: String?, artist: String?) -> String {
        "\(normalizeAlbum(album))•\(normalizeArtist(artist))"
    }

    static func displayTitle(_ value: String?) -> String {
        display(value, fallback: unknownTitle)
    }

    static func displayArtist(_ value: String?) -> String {
        display(value, fallback: unknownArtist)
    }

    static func displayAlbum(_ value: String?) -> String {
        display(value, fallback: unknownAlbum)
    }

    private static func normalize(_ value: String?, fallback: String) -> String {
        display(value, fallback: fallback).lowercased()
    }

    private static func display(_ value: String?, fallback: String) -> String {
        let collapsed =
            (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? fallback : collapsed
    }
}
