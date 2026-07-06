//
//  HomeSection.swift
//  myPlayer2
//
//  Stable identifiers for configurable Home page sections.
//

import Foundation

enum HomeSection: String, CaseIterable, Identifiable {
    case featured
    case artists
    case albums
    case playlists
    case listeningFootprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .featured: return "精选"
        case .artists: return "歌手"
        case .albums: return "专辑"
        case .playlists: return "播放列表"
        case .listeningFootprint: return "音乐足迹"
        }
    }

    var systemImage: String {
        switch self {
        case .featured: return "sparkles"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .playlists: return "music.note.list"
        case .listeningFootprint: return "chart.line.uptrend.xyaxis"
        }
    }

    var defaultOrder: Int {
        switch self {
        case .featured: return 0
        case .artists: return 1
        case .albums: return 2
        case .playlists: return 3
        case .listeningFootprint: return 4
        }
    }

    static var defaultOrder: [HomeSection] {
        allCases.sorted { $0.defaultOrder < $1.defaultOrder }
    }

    static func normalizedOrder(from rawIDs: [String]) -> [HomeSection] {
        var seen = Set<HomeSection>()
        var normalized: [HomeSection] = []

        for rawID in rawIDs {
            guard let section = HomeSection(rawValue: rawID), !seen.contains(section) else {
                continue
            }
            seen.insert(section)
            normalized.append(section)
        }

        for section in defaultOrder where !seen.contains(section) {
            normalized.append(section)
        }

        return normalized.isEmpty ? defaultOrder : normalized
    }
}
