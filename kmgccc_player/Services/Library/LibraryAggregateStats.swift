//
//  LibraryAggregateStats.swift
//  myPlayer2
//
//  Aggregated playback/preference totals for album and artist surfaces.
//

import Foundation

@MainActor
struct LibraryAggregateStats {
    struct Metric {
        var value: Double = 0
        var hasData = false
    }

    private var albumPlayCounts: [String: Metric] = [:]
    private var albumPreferenceScores: [String: Metric] = [:]
    private var artistPlayCounts: [String: Metric] = [:]
    private var artistPreferenceScores: [String: Metric] = [:]

    init(tracks: [Track]) {
        let statsService = PreferenceStatsService.shared

        for track in tracks {
            let stats = statsService.getStats(for: track.id)
            let hasPreferenceData = stats.playCount > 0
                || stats.preferenceScoreCache != 0
                || stats.manualLikeState != .none

            albumPlayCounts[track.albumGroupKey] = adding(
                Double(max(stats.playCount, 0)),
                hasData: stats.playCount > 0,
                to: albumPlayCounts[track.albumGroupKey] ?? Metric()
            )
            albumPreferenceScores[track.albumGroupKey] = adding(
                stats.preferenceScoreCache.isFinite ? stats.preferenceScoreCache : 0,
                hasData: hasPreferenceData,
                to: albumPreferenceScores[track.albumGroupKey] ?? Metric()
            )

            for artistKey in LibraryNormalization.artistCanonicalNames(track.artist) {
                artistPlayCounts[artistKey] = adding(
                    Double(max(stats.playCount, 0)),
                    hasData: stats.playCount > 0,
                    to: artistPlayCounts[artistKey] ?? Metric()
                )
                artistPreferenceScores[artistKey] = adding(
                    stats.preferenceScoreCache.isFinite ? stats.preferenceScoreCache : 0,
                    hasData: hasPreferenceData,
                    to: artistPreferenceScores[artistKey] ?? Metric()
                )
            }
        }
    }

    func albumPlayCount(for entry: AlbumEntry) -> Metric {
        albumPlayCounts[entry.canonicalKey] ?? Metric()
    }

    func albumPreferenceScore(for entry: AlbumEntry) -> Metric {
        albumPreferenceScores[entry.canonicalKey] ?? Metric()
    }

    func artistPlayCount(for entry: ArtistEntry) -> Metric {
        artistPlayCounts[entry.canonicalName] ?? Metric()
    }

    func artistPreferenceScore(for entry: ArtistEntry) -> Metric {
        artistPreferenceScores[entry.canonicalName] ?? Metric()
    }

    private func adding(_ value: Double, hasData: Bool, to metric: Metric) -> Metric {
        var metric = metric
        metric.value += value
        metric.hasData = metric.hasData || hasData
        return metric
    }
}
