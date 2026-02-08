//
//  LocalLibraryPaths.swift
//  myPlayer2
//
//  TrueMusic - Local Library Paths
//  Fixed library root under ~/Music/TrueMusic Library
//

import Foundation

enum LocalLibraryPaths {

    static let libraryRootName = "TrueMusic Library"

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

    static func playlistURL(for id: UUID) -> URL {
        playlistsRootURL.appendingPathComponent("\(id.uuidString).json")
    }

    static func libraryURL(from relativePath: String) -> URL {
        libraryRootURL.appendingPathComponent(relativePath)
    }
}

