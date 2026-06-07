//
//  ExternalPlaybackSource.swift
//  myPlayer2
//
//  User preference and runtime presentation model for System Now Playing sources.
//

import Foundation

struct ExternalPlaybackSourcePreference: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var bundleIdentifier: String
    var displayName: String
    var isDisabled: Bool
}

enum ExternalPlaybackSourcePlaybackState: String, Codable, Equatable, Sendable {
    case playing
    case paused
    case idle
    case unknown

    var title: String {
        switch self {
        case .playing: return "播放中"
        case .paused: return "暂停"
        case .idle: return "空闲"
        case .unknown: return "未知"
        }
    }
}

struct ExternalPlaybackSourceSnapshot: Equatable, Identifiable, Sendable {
    var id: String
    var bundleIdentifier: String
    var displayName: String
    var isDisabled: Bool
    var playbackState: ExternalPlaybackSourcePlaybackState
    var isCurrent: Bool
    var lastDetectedAt: Date?
    var lastActiveAt: Date?
}

extension Notification.Name {
    static let externalPlaybackSourcePreferencesDidChange =
        Notification.Name("externalPlaybackSourcePreferencesDidChange")
}
