//
//  HomeDisplayModels.swift
//  myPlayer2
//
//  Value-typed, Equatable display models for Home sections.
//  Sections receive these instead of raw reference types so that
//  EquatableView can short-circuit diff when data hasn't changed.
//
//  Builder methods live on HomeViewModel; this file only defines
//  the struct shapes and their equality.
//

import Foundation

// MARK: - Hero

struct HomeHeroDisplayModel: Equatable {
    /// The track reference is retained for playback coordination.
    /// Equality ignores identity — it uses (id, trackRevision) instead.
    let track: Track
    let trackID: UUID
    let trackRevision: UInt64
    let containerWidthBucket: Int   // 16pt step
    let mode: HomeLayoutMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.trackRevision == rhs.trackRevision
            && lhs.containerWidthBucket == rhs.containerWidthBucket
            && lhs.mode == rhs.mode
    }
}

// MARK: - Playlists

struct HomePlaylistsDisplayModel: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let name: String
        let trackCount: Int
        let userDescription: String
        let artworkRevisionTag: String
        let previewTrackIDs: [UUID]
    }

    let items: [Item]
    let mode: HomeLayoutMode
    let centerLeftPadBucket: Int    // 16pt step
    let centerRightPadBucket: Int   // 16pt step
}

// MARK: - Artists

struct HomeArtistsDisplayModel: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let displayName: String
        let canonicalName: String
        let trackCount: Int
        let albumCount: Int
        let artworkChecksum: UInt64
        let hasArtworkData: Bool
    }

    let items: [Item]
    let mode: HomeLayoutMode
    let centerLeftPadBucket: Int
    let centerRightPadBucket: Int
}

// MARK: - Albums

struct HomeAlbumsDisplayModel: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let displayTitle: String
        let primaryArtistDisplayName: String
        let canonicalKey: String
        let trackCount: Int
        let artworkChecksum: UInt64
        let hasArtworkData: Bool
    }

    let items: [Item]
    let mode: HomeLayoutMode
    let centerLeftPadBucket: Int
    let centerRightPadBucket: Int
}

// MARK: - Insights

struct HomeInsightsDisplayModel: Equatable {
    struct StatCard: Equatable, Identifiable {
        let id: String      // label as ID
        let label: String
        let value: String
        let unit: String
    }

    struct RankRow: Equatable, Identifiable {
        let id: UUID
        let trackID: UUID
        let title: String
        let artist: String
        let playCount: Int
        let score: Double
    }

    let statCards: [StatCard]
    let rankRows: [RankRow]
    let dailyListeningSignature: Int
    let containerWidthBucket: Int
    let centerLeftPadBucket: Int
    let centerRightPadBucket: Int
    let mode: HomeLayoutMode
}

// MARK: - Geometry helpers

extension HomeDisplayModels {
    /// Bucket a pixel value into 16pt steps for stable equality.
    static func bucket16(_ value: CGFloat) -> Int {
        Int((value / 16).rounded())
    }
}

enum HomeDisplayModels {
    /// Placeholder — builders are methods on HomeViewModel.
}
