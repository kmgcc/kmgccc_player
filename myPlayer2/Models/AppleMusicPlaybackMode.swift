//
//  AppleMusicPlaybackMode.swift
//  myPlayer2
//
//  Source-native playback order model for Music.app.
//

import Foundation

enum AppleMusicPlaybackMode: String, CaseIterable, Identifiable, Sendable {
    case sequence
    case shuffle
    case repeatAll
    case repeatOne

    nonisolated var id: String { rawValue }

    nonisolated init(shuffleEnabled: Bool, repeatMode: AppleMusicBridge.RepeatMode) {
        switch repeatMode {
        case .one:
            self = .repeatOne
        case .all:
            self = .repeatAll
        case .off, .unknown:
            self = shuffleEnabled ? .shuffle : .sequence
        }
    }

    nonisolated var shuffleEnabled: Bool {
        self == .shuffle
    }

    nonisolated var repeatMode: AppleMusicBridge.RepeatMode {
        switch self {
        case .sequence, .shuffle:
            return .off
        case .repeatAll:
            return .all
        case .repeatOne:
            return .one
        }
    }

    nonisolated var semanticallyEquivalentLocalMode: PlaybackOrderMode {
        switch self {
        case .sequence, .repeatAll:
            return .sequence
        case .shuffle:
            return .shuffle
        case .repeatOne:
            return .repeatOne
        }
    }

    nonisolated init(localMode: PlaybackOrderMode) {
        switch localMode {
        case .sequence, .stopAfterTrack:
            self = .sequence
        case .shuffle:
            self = .shuffle
        case .repeatOne:
            self = .repeatOne
        }
    }
}
