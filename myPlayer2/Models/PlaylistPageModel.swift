//
//  PlaylistPageModel.swift
//  myPlayer2
//
//  Single-source playlist detail page state.
//

import AppKit
import Foundation

struct PlaylistPageRowRecord: Sendable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let durationText: String
    let artworkIdentity: String
    let artworkFileURL: URL?
    let isMissing: Bool
}

struct PlaylistPageRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let durationText: String
    let artworkData: Data?
    let artworkFileURL: URL?
    let artworkIdentity: String
    let isMissing: Bool

    init(
        id: UUID,
        title: String,
        artist: String,
        durationText: String,
        artworkData: Data?,
        artworkFileURL: URL? = nil,
        artworkIdentity: String,
        isMissing: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationText = durationText
        self.artworkData = artworkData
        self.artworkFileURL = artworkFileURL
        self.artworkIdentity = artworkIdentity
        self.isMissing = isMissing
    }

    init(record: PlaylistPageRowRecord, artworkData: Data?) {
        self.init(
            id: record.id,
            title: record.title,
            artist: record.artist,
            durationText: record.durationText,
            artworkData: artworkData,
            artworkFileURL: record.artworkFileURL,
            artworkIdentity: record.artworkIdentity,
            isMissing: record.isMissing
        )
    }

    var trackRowModel: TrackRowModel {
        TrackRowModel(
            id: id,
            title: title,
            artist: artist,
            durationText: durationText,
            artworkData: artworkData,
            artworkFileURL: artworkFileURL,
            artworkIdentity: artworkIdentity,
            isMissing: isMissing
        )
    }
}

struct PlaylistPageHeaderModel {
    let config: DetailHeaderConfig
    let artworkIdentity: String
    var artwork: NSImage?
}

struct PlaylistPageModel {
    let selection: LibrarySelection
    let selectionIdentity: String
    let sourceFingerprint: String
    let displayedTrackCount: Int
    let filteredTrackCount: Int
    let displayedTotalDuration: Double
    let rows: [PlaylistPageRowModel]
    let queueTracks: [Track]
    let queueIndexMap: [UUID: Int]
    var header: PlaylistPageHeaderModel?

    var isEmpty: Bool {
        rows.isEmpty
    }
}

enum PlaylistPagePhase: Equatable {
    case idle
    case transitioning
    case firstPaint
    case ready
}
