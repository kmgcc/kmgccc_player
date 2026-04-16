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
    let artworkVersion: Int
    let isMissing: Bool
}

struct PlaylistPageRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let durationText: String
    let artworkIdentity: String
    let artworkVersion: Int
    let isMissing: Bool

    init(
        id: UUID,
        title: String,
        artist: String,
        durationText: String,
        artworkIdentity: String,
        artworkVersion: Int,
        isMissing: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationText = durationText
        self.artworkIdentity = artworkIdentity
        self.artworkVersion = artworkVersion
        self.isMissing = isMissing
    }

    init(record: PlaylistPageRowRecord) {
        self.init(
            id: record.id,
            title: record.title,
            artist: record.artist,
            durationText: record.durationText,
            artworkIdentity: record.artworkIdentity,
            artworkVersion: record.artworkVersion,
            isMissing: record.isMissing
        )
    }

    var trackRowModel: TrackRowModel {
        TrackRowModel(
            id: id,
            title: title,
            artist: artist,
            durationText: durationText,
            artworkIdentity: artworkIdentity,
            artworkVersion: artworkVersion,
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
