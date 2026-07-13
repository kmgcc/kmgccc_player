//
//  PlaybackHistoryRecord.swift
//  myPlayer2
//
//  Durable event model for the playback history timeline.
//

import Foundation
import SwiftData

/// One effective playback session. This is deliberately separate from the
/// per-track preference statistics stored in `meta.json`: a timeline needs one
/// row per session and must not make library sidecars grow without bound.
@Model
final class PlaybackHistoryRecord {
    @Attribute(.unique) var id: UUID
    var trackID: UUID
    var playedAt: Date
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var playedSeconds: Double

    init(
        id: UUID = UUID(),
        trackID: UUID,
        playedAt: Date,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        playedSeconds: Double
    ) {
        self.id = id
        self.trackID = trackID
        self.playedAt = playedAt
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.playedSeconds = playedSeconds
    }
}
