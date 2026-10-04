import Foundation
import PlayerAutomationProtocol

nonisolated enum AutomationTrackPreferenceQuery {
    static let filterFields: Set<String> = [
        "likeState",
        "playCountMin",
        "playCountMax",
        "completePlayCountMin",
        "skipCountMin",
        "lastPlayedAfter",
        "lastPlayedBefore",
        "totalPlayedSecondsMin",
        "preferenceScoreMin"
    ]

    static let sortFields: Set<String> = [
        "likeState",
        "playCount",
        "completePlayCount",
        "skipCount",
        "lastPlayedAt",
        "totalPlayedSeconds",
        "preferenceScore"
    ]

    static func requiresHistoryRead(in filter: AutomationJSONValue) -> Bool {
        guard case .object(let values) = filter else { return false }
        if !filterFields.isDisjoint(with: values.keys) { return true }

        for key in ["all", "any"] {
            guard case .array(let children) = values[key] else { continue }
            if children.contains(where: requiresHistoryRead(in:)) { return true }
        }
        if let child = values["not"], requiresHistoryRead(in: child) { return true }
        return false
    }

    static func requiresHistoryRead(sort: [AutomationJSONValue]) -> Bool {
        sort.contains { value in
            guard case .object(let values) = value,
                  case .string(let field) = values["field"] else { return false }
            return sortFields.contains(field)
        }
    }

    static func matches(
        _ key: String,
        value: AutomationJSONValue,
        stats: TrackPreferenceStats
    ) -> Bool {
        switch (key, value) {
        case ("likeState", .string(let rawValue)):
            return stats.manualLikeState.rawValue == rawValue
        case ("playCountMin", .number(let value)):
            return Double(stats.playCount) >= value
        case ("playCountMax", .number(let value)):
            return Double(stats.playCount) <= value
        case ("completePlayCountMin", .number(let value)):
            return Double(stats.completePlayCount) >= value
        case ("skipCountMin", .number(let value)):
            return Double(stats.skipCount) >= value
        case ("lastPlayedAfter", .string(let rawValue)):
            guard let date = parseDate(rawValue), let lastPlayedAt = stats.lastPlayedAt else {
                return false
            }
            return lastPlayedAt > date
        case ("lastPlayedBefore", .string(let rawValue)):
            guard let date = parseDate(rawValue), let lastPlayedAt = stats.lastPlayedAt else {
                return false
            }
            return lastPlayedAt < date
        case ("totalPlayedSecondsMin", .number(let value)):
            return stats.totalPlayedSeconds >= value
        case ("preferenceScoreMin", .number(let value)):
            return stats.preferenceScoreCache >= value
        default:
            return false
        }
    }

    static func compare(
        _ lhs: TrackPreferenceStats,
        _ rhs: TrackPreferenceStats,
        field: String
    ) -> ComparisonResult? {
        switch field {
        case "likeState":
            return lhs.manualLikeState.rawValue.localizedStandardCompare(rhs.manualLikeState.rawValue)
        case "playCount":
            return compare(lhs.playCount, rhs.playCount)
        case "completePlayCount":
            return compare(lhs.completePlayCount, rhs.completePlayCount)
        case "skipCount":
            return compare(lhs.skipCount, rhs.skipCount)
        case "lastPlayedAt":
            return compare(lhs.lastPlayedAt ?? .distantPast, rhs.lastPlayedAt ?? .distantPast)
        case "totalPlayedSeconds":
            return compare(lhs.totalPlayedSeconds, rhs.totalPlayedSeconds)
        case "preferenceScore":
            return compare(lhs.preferenceScoreCache, rhs.preferenceScoreCache)
        default:
            return nil
        }
    }

    static func summary(_ stats: TrackPreferenceStats) -> AutomationTrackPreferenceSummary {
        AutomationTrackPreferenceSummary(
            playCount: stats.playCount,
            completePlayCount: stats.completePlayCount,
            skipCount: stats.skipCount,
            quickSkipCount: stats.quickSkipCount,
            totalPlayedSeconds: stats.totalPlayedSeconds,
            lastPlayedAt: stats.lastPlayedAt,
            lastCompletedAt: stats.lastCompletedAt,
            lastSkippedAt: stats.lastSkippedAt,
            likeState: stats.manualLikeState.rawValue,
            preferenceScore: stats.preferenceScoreCache,
            effectiveWeight: stats.effectiveWeightCache
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}
