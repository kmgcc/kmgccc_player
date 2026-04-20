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

    var id: String { rawValue }
}
