//
//  LocalLibraryPaths.swift
//  myPlayer2
//
//  kmgccc_player - Local Library Paths
//  Fixed library root under ~/Music/kmgccc_player Library
//

import Foundation

nonisolated enum LocalLibraryPaths {

    static let libraryRootName = "kmgccc_player Library"

    static var libraryRootURL: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(libraryRootName, isDirectory: true)
    }

    static var tracksRootURL: URL {
        libraryRootURL.appendingPathComponent("Tracks", isDirectory: true)
    }

    static var playlistsRootURL: URL {
        libraryRootURL.appendingPathComponent("Playlists", isDirectory: true)
    }

    static func trackFolderURL(for id: UUID) -> URL {
        tracksRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func trackMetaURL(for id: UUID) -> URL {
        trackFolderURL(for: id).appendingPathComponent("meta.json")
    }

    static func trackArtworkURL(for id: UUID) -> URL {
        trackFolderURL(for: id).appendingPathComponent("artwork.jpg")
    }

    static func trackLyricsURL(for id: UUID, ext: String) -> URL {
        trackFolderURL(for: id).appendingPathComponent("lyrics.\(ext)")
    }

    static func trackTTMLLyricsURL(for id: UUID) -> URL {
        trackFolderURL(for: id).appendingPathComponent("lyrics.ttml")
    }

    static func playlistURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    static func libraryURL(from relativePath: String) -> URL {
        libraryRootURL.appendingPathComponent(relativePath)
    }

    static var artistsRootURL: URL {
        libraryRootURL.appendingPathComponent("Artists", isDirectory: true)
    }

    static var albumsRootURL: URL {
        libraryRootURL.appendingPathComponent("Albums", isDirectory: true)
    }

    static func artistFolderURL(for id: UUID) -> URL {
        artistsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func albumFolderURL(for id: UUID) -> URL {
        albumsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func artistMetaURL(for id: UUID) -> URL {
        artistFolderURL(for: id).appendingPathComponent("meta.json")
    }

    static func albumMetaURL(for id: UUID) -> URL {
        albumFolderURL(for: id).appendingPathComponent("meta.json")
    }
}
