//
//  PlaybackSource.swift
//  myPlayer2
//
//  Identifies the active playback provider.
//

import Foundation

enum PlaybackSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case local
    case appleMusic
    case systemNowPlaying

    var id: String { rawValue }

    var isExternal: Bool {
        self != .local
    }

    var localizedTitleKey: String {
        switch self {
        case .local:
            return "playback.source.local"
        case .appleMusic:
            return "playback.source.apple_music"
        case .systemNowPlaying:
            return "playback.source.system_now_playing"
        }
    }

    var externalDisplayName: String {
        switch self {
        case .local:
            return NSLocalizedString("playback.source.local", comment: "")
        case .appleMusic:
            return NSLocalizedString("playback.source.apple_music", comment: "")
        case .systemNowPlaying:
            return NSLocalizedString("playback.source.system_now_playing", comment: "")
        }
    }

    var notPlayingTitleKey: String {
        switch self {
        case .local:
            return "mini.not_playing"
        case .appleMusic:
            return "apple_music.not_playing"
        case .systemNowPlaying:
            return "system_now_playing.not_playing"
        }
    }

    var unavailableTitleKey: String {
        switch self {
        case .local:
            return "mini.not_playing"
        case .appleMusic:
            return "apple_music.temporarily_unavailable"
        case .systemNowPlaying:
            return "system_now_playing.temporarily_unavailable"
        }
    }

    var disconnectedTitleKey: String {
        switch self {
        case .local:
            return "mini.not_playing"
        case .appleMusic:
            return "apple_music.not_running"
        case .systemNowPlaying:
            return "system_now_playing.disconnected"
        }
    }
}
