//
//  SettingsCategory.swift
//  myPlayer2
//
//  kmgccc_player - Settings Sidebar Category Definition
//

import SwiftUI

/// Settings sidebar navigation categories.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case nowPlaying
    case fullscreen
    case externalPlayback
    case data
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: return "外观"
        case .nowPlaying: return "settings.section.now_playing"
        case .fullscreen: return "全屏播放"
        case .externalPlayback: return "外部播放"
        case .data: return "数据"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .nowPlaying: return "sparkles"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .externalPlayback: return "music.note.tv"
        case .data: return "arrow.counterclockwise.circle"
        case .about: return "info.circle"
        }
    }
}
