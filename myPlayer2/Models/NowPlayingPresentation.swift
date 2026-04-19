//
//  NowPlayingPresentation.swift
//  myPlayer2
//
//  Source-neutral playback state for UI presentation.
//

import Foundation

struct NowPlayingPresentation {
    var source: PlaybackSource
    var localTrack: Track?
    var title: String
    var artist: String
    var album: String?
    var artworkData: Data?
    var duration: Double
    var currentTime: Double
    var isPlaying: Bool
    var volume: Double
    var lyricsText: String?
    var lyricsIdentity: String?
    var isControlEnabled: Bool
    var isSeekEnabled: Bool
    var emptyTitleKey: String

    static let emptyLocal = NowPlayingPresentation(
        source: .local,
        localTrack: nil,
        title: "",
        artist: "",
        album: nil,
        artworkData: nil,
        duration: 0,
        currentTime: 0,
        isPlaying: false,
        volume: AppSettings.shared.volume,
        lyricsText: nil,
        lyricsIdentity: nil,
        isControlEnabled: false,
        isSeekEnabled: false,
        emptyTitleKey: "mini.not_playing"
    )

    var hasTrack: Bool {
        localTrack != nil || !title.isEmpty
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }
}
