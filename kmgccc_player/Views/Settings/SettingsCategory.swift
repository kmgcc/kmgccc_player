//
//  SettingsCategory.swift
//  myPlayer2
//
//  kmgccc_player - Settings Sidebar Category Definition
//

import SwiftUI

/// Settings sidebar navigation categories.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case nowPlaying
    case fullscreen
    case audio
    case externalPlayback
    case library
    case data
    case automation
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .nowPlaying: return "settings.section.now_playing"
        case .fullscreen: return "全屏播放"
        case .audio: return "音频"
        case .externalPlayback: return "外部播放"
        case .library: return "资料库"
        case .data: return "存储与维护"
        case .automation: return "自动化与智能"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .nowPlaying: return "macwindow"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .audio: return "waveform"
        case .externalPlayback: return "music.note.tv"
        case .library: return "music.note.house"
        case .data: return "externaldrive"
        case .automation: return "sparkles.rectangle.stack"
        case .about: return "info.circle"
        }
    }
}
