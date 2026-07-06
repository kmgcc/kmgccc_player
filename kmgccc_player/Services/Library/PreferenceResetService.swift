//
//  PreferenceResetService.swift
//  myPlayer2
//
//  Batch reset of track preference-related metadata without rescanning the library.
//

import Foundation

struct ResetMusicPreferenceOptions: Equatable, Sendable {
    /// 重置自动记录的播放统计与歌曲偏好（合并选项）
    var resetPlaybackStatsAndPreference: Bool = false
    /// 清理旧版残留与废弃缓存
    var cleanupLegacyResiduals: Bool = false

    var hasSelection: Bool {
        resetPlaybackStatsAndPreference || cleanupLegacyResiduals
    }

    var selectedItemTitles: [String] {
        var titles: [String] = []
        if resetPlaybackStatsAndPreference {
            titles.append("重置自动记录的播放统计与歌曲偏好")
        }
        if cleanupLegacyResiduals {
            titles.append("清理旧版残留与废弃缓存")
        }
        return titles
    }
}

struct MusicPreferenceResetProgress: Sendable {
    let processedCount: Int
    let totalCount: Int
    let currentTrackTitle: String?
    let detail: String

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }
}

struct MusicPreferenceResetFailure: Identifiable, Sendable {
    let id = UUID()
    let trackID: UUID
    let title: String
    let reason: String
}

struct MusicPreferenceResetResult: Sendable {
    let totalCount: Int
    let successCount: Int
    let failureCount: Int
    let failures: [MusicPreferenceResetFailure]
    let updatedTrackIDs: [UUID]
}

private struct PreferenceResetTrackSnapshot: Sendable {
    let trackID: UUID
    let title: String
    let duration: Double
    let metaURL: URL

    init(track: Track) {
        self.trackID = track.id
        self.title = track.title
        self.duration = track.duration
        self.metaURL = LocalLibraryPaths.trackMetaURL(for: track.id)
    }
}

private struct PreferenceResetProcessedTrack: Sendable {
    let trackID: UUID
    let title: String
    let duration: Double
    let updatedStats: PreferenceResetStatsSnapshot
}

private struct PreferenceResetStatsSnapshot: Sendable {
    let playCount: Int
    let completePlayCount: Int
    let skipCount: Int
    let quickSkipCount: Int
    let totalPlayedSeconds: Double
    let manualLikeStateRawValue: String
    let preferenceScoreCache: Double
    let effectiveWeightCache: Double

    @MainActor
    func asTrackPreferenceStats() -> TrackPreferenceStats {
        var stats = TrackPreferenceStats()
        stats.playCount = playCount
        stats.completePlayCount = completePlayCount
        stats.skipCount = skipCount
        stats.quickSkipCount = quickSkipCount
        stats.totalPlayedSeconds = totalPlayedSeconds
        stats.manualLikeState = ManualLikeState(rawValue: manualLikeStateRawValue) ?? .none
        stats.preferenceScoreCache = preferenceScoreCache
        stats.effectiveWeightCache = effectiveWeightCache
        return stats
    }
}

private struct PreferenceResetWorkerResult: Sendable {
    let updatedTracks: [PreferenceResetProcessedTrack]
    let failures: [MusicPreferenceResetFailure]
}

private actor PreferenceResetFileWorker {
    private let cleanupTopLevelKeys: Set<String> = [
        "playCount",
        "completePlayCount",
        "skipCount",
        "quickSkipCount",
        "totalPlayedSeconds",
        "preferenceScoreCache",
        "effectiveWeightCache",
    ]

    private let defaultStatsDictionary: [String: Any] = [
        "playCount": 0,
        "completePlayCount": 0,
        "skipCount": 0,
        "quickSkipCount": 0,
        "totalPlayedSeconds": 0,
        "manualLikeState": ManualLikeState.none.rawValue,
        "preferenceScoreCache": 0,
        "effectiveWeightCache": 1.0,
    ]

    func resetTracks(
        _ snapshots: [PreferenceResetTrackSnapshot],
        options: ResetMusicPreferenceOptions,
        progress: @escaping @MainActor (MusicPreferenceResetProgress) -> Void
    ) async -> PreferenceResetWorkerResult {
        var updatedTracks: [PreferenceResetProcessedTrack] = []
        var failures: [MusicPreferenceResetFailure] = []
        let totalCount = snapshots.count

        await progress(
            MusicPreferenceResetProgress(
                processedCount: 0,
                totalCount: totalCount,
                currentTrackTitle: nil,
                detail: "准备修改整个音乐资料库中的 meta.json"
            )
        )

        for (index, snapshot) in snapshots.enumerated() {
            await progress(
                MusicPreferenceResetProgress(
                    processedCount: index,
                    totalCount: totalCount,
                    currentTrackTitle: snapshot.title,
                    detail: "正在更新 \(snapshot.title)"
                )
            )

            do {
                let updated = try processTrack(snapshot, options: options)
                updatedTracks.append(updated)
            } catch {
                let failure = MusicPreferenceResetFailure(
                    trackID: snapshot.trackID,
                    title: snapshot.title,
                    reason: error.localizedDescription
                )
                failures.append(failure)
                Log.error(
                    "[PreferenceReset] failed trackID=\(snapshot.trackID.uuidString) title=\(snapshot.title) error=\(error.localizedDescription)",
                    category: .library
                )
            }

            await progress(
                MusicPreferenceResetProgress(
                    processedCount: index + 1,
                    totalCount: totalCount,
                    currentTrackTitle: snapshot.title,
                    detail: "已处理 \(index + 1) / \(totalCount)"
                )
            )
        }

        return PreferenceResetWorkerResult(updatedTracks: updatedTracks, failures: failures)
    }

    private func processTrack(
        _ snapshot: PreferenceResetTrackSnapshot,
        options: ResetMusicPreferenceOptions
    ) throws -> PreferenceResetProcessedTrack {
        let data = try Data(contentsOf: snapshot.metaURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "PreferenceResetService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "meta.json 不是可写的对象字典"]
            )
        }

        var stats = mergedStatsDictionary(from: json["preferenceStats"])
        applySelectedResets(to: &stats, options: options)

        if options.cleanupLegacyResiduals || options.resetPlaybackStatsAndPreference {
            for key in cleanupTopLevelKeys {
                json.removeValue(forKey: key)
            }
        }

        json["preferenceStats"] = stats

        guard JSONSerialization.isValidJSONObject(json) else {
            throw NSError(
                domain: "PreferenceResetService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "更新后的 meta.json 结构无效"]
            )
        }

        let updatedData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: snapshot.metaURL, options: .atomic)

        return PreferenceResetProcessedTrack(
            trackID: snapshot.trackID,
            title: snapshot.title,
            duration: snapshot.duration,
            updatedStats: statsSnapshot(from: stats)
        )
    }

    private func mergedStatsDictionary(from rawValue: Any?) -> [String: Any] {
        var merged = defaultStatsDictionary
        if let rawStats = rawValue as? [String: Any] {
            for (key, value) in rawStats {
                merged[key] = value
            }
        }
        return merged
    }

    private func applySelectedResets(
        to stats: inout [String: Any],
        options: ResetMusicPreferenceOptions
    ) {
        if options.resetPlaybackStatsAndPreference {
            stats["playCount"] = 0
            stats["totalPlayedSeconds"] = 0
            stats["completePlayCount"] = 0
            stats["skipCount"] = 0
            stats["quickSkipCount"] = 0
            stats["preferenceScoreCache"] = 0
            stats["effectiveWeightCache"] = 1.0
        }
    }

    private func statsSnapshot(from dictionary: [String: Any]) -> PreferenceResetStatsSnapshot {
        PreferenceResetStatsSnapshot(
            playCount: intValue(dictionary["playCount"]),
            completePlayCount: intValue(dictionary["completePlayCount"]),
            skipCount: intValue(dictionary["skipCount"]),
            quickSkipCount: intValue(dictionary["quickSkipCount"]),
            totalPlayedSeconds: doubleValue(dictionary["totalPlayedSeconds"]),
            manualLikeStateRawValue: manualLikeStateValue(dictionary["manualLikeState"]).rawValue,
            preferenceScoreCache: doubleValue(dictionary["preferenceScoreCache"]),
            effectiveWeightCache: doubleValue(dictionary["effectiveWeightCache"], defaultValue: 1.0)
        )
    }

    private func intValue(_ rawValue: Any?) -> Int {
        switch rawValue {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value) ?? 0
        default:
            return 0
        }
    }

    private func doubleValue(_ rawValue: Any?, defaultValue: Double = 0) -> Double {
        switch rawValue {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value) ?? defaultValue
        default:
            return defaultValue
        }
    }

    private func manualLikeStateValue(_ rawValue: Any?) -> ManualLikeState {
        guard let rawString = rawValue as? String,
              let state = ManualLikeState(rawValue: rawString)
        else {
            return .none
        }
        return state
    }
}

final class PreferenceResetService {
    static let shared = PreferenceResetService()

    private let worker = PreferenceResetFileWorker()

    private init() {}

    @MainActor
    func resetLibraryTracks(
        _ tracks: [Track],
        options: ResetMusicPreferenceOptions,
        progress: @escaping @MainActor (MusicPreferenceResetProgress) -> Void
    ) async -> MusicPreferenceResetResult {
        let snapshots = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, PreferenceResetTrackSnapshot(track: $0)) })
            .values
            .sorted { $0.trackID.uuidString < $1.trackID.uuidString }

        let workerResult = await worker.resetTracks(snapshots, options: options, progress: progress)

        for updated in workerResult.updatedTracks {
            PreferenceStatsService.shared.replaceStats(
                for: updated.trackID,
                with: updated.updatedStats.asTrackPreferenceStats(),
                markDirty: false
            )
        }

        return MusicPreferenceResetResult(
            totalCount: snapshots.count,
            successCount: workerResult.updatedTracks.count,
            failureCount: workerResult.failures.count,
            failures: workerResult.failures,
            updatedTrackIDs: workerResult.updatedTracks.map(\.trackID)
        )
    }
}
