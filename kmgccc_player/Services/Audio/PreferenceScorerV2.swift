//
//  PreferenceScorerV2.swift
//  myPlayer2
//
//  Smart Shuffle - Preference Scorer V2
//  温和、可恢复、抗误判的本地偏好随机播放算法
//
//  核心原则：
//  1. 以比例特征为主，绝对次数为辅
//  2. 低样本必须保守（confidence 保护）
//  3. 偏好有上限，不允许无限膨胀
//  4. 负反馈柔和且可恢复
//  5. 运行时惩罚解决连播问题，不依赖极端基础权重
//

import Foundation
import SwiftData

// MARK: - Algorithm Constants

enum PreferenceAlgorithmV2 {
    /// 基础权重范围：0.65 ~ 1.35（温和区间）
    static let minBaseWeight: Double = 0.65
    static let maxBaseWeight: Double = 1.35
    static let neutralWeight: Double = 1.0
    static let weightRange: Double = 0.35  // 偏离中性的最大幅度

    /// 低样本保护参数
    /// confidence = min(log2(plays + 1) / 3.0, 1.0)
    /// - 1 play:  log2(2)/3 = 0.33
    /// - 3 plays: log2(4)/3 = 0.67
    /// - 7 plays: log2(8)/3 = 1.0 (满置信)
    static let confidenceDenominator: Double = 3.0

    /// 原始偏好分系数
    static let completionRateCoeff: Double = 0.8
    static let listenRatioCoeff: Double = 0.6
    /// 快速跳过/跳过系数。
    /// 注意：负向项会再经过 `negativeDamping` 衰减，所以这里相比早期 (-0.9 / -0.3)
    /// 已经调温和，避免快速切歌一次就把歌压死。
    static let quickSkipRateCoeff: Double = -0.65
    static let skipRateCoeff: Double = -0.25

    /// 手动偏好修正
    static let manualLikedBias: Double = 0.18
    static let manualDislikedBias: Double = -0.18

    // MARK: - Negative-signal Damping（跳过伤害保护）
    //
    // 设计原则：快速切歌不能覆盖长期正面信号。负向项（skip / quickSkip）会乘上一个
    // 0~1 的衰减系数，由三部分组成，彼此相乘：
    //   1. 完成度护盾：完成率高且置信度高的歌，跳过伤害更小
    //   2. 手动喜欢护盾：liked 的歌跳过伤害减半
    //   3. 时间恢复：距离上次跳过越久，旧跳过的伤害越低（可恢复）

    /// 完成度护盾最大削减比例（最多削减 60% 的跳过伤害）。
    static let maxCompletionShield: Double = 0.6

    /// 手动喜欢的歌跳过伤害缩放（liked → 伤害 ×0.5）。
    static let likedDamageScale: Double = 0.5

    /// 时间恢复下限：再久的跳过也至少保留 35% 伤害（防止刷时间洗白）。
    static let skipRecoveryFloor: Double = 0.35

    /// 时间恢复时间常数（天）：约 3 周后旧跳过伤害衰减到接近下限。
    static let skipRecoveryDays: Double = 21.0

    // MARK: - Exploration / Rediscovery（探索 / 再曝光）
    //
    // 让随机播放不至于固化到只放高偏好歌。两层机制：
    //   - freshnessMultiplier：温和、常驻，长期未播放的歌获得小幅加权
    //   - rediscoveryEligibility：低曝光 / 长期未播放歌的"再曝光"资格，
    //     由 ShuffleSession 小概率放大。两者都排除 disliked / 高快速跳过歌。

    /// 长期未播放的最大新鲜度加成（+45%）。
    static let freshnessWeight: Double = 0.45

    /// 新鲜度时间常数（天）。
    static let freshnessTauDays: Double = 30.0

    /// 从未播放歌的新鲜度上限。
    static let neverPlayedFreshness: Double = 1.45

    /// 再曝光放大上限（被选中时最多 ×1.6）。
    static let rediscoveryMaxBoost: Double = 1.6

    /// 快速跳过率高于此值的歌，不参与任何探索加权（避免反复推用户明显不喜欢的歌）。
    static let explorationQuickSkipGuard: Double = 0.4

    /// 偏好压缩参数
    /// boundedPreference = tanh(finalPreference * compressionFactor)
    static let compressionFactor: Double = 1.4

    /// 运行时惩罚参数
    enum RuntimePenalty {
        /// 最近同曲惩罚
        static let sameTrackRecent5: Double = 0.2   // 最近5首内
        static let sameTrackRecent10: Double = 0.6  // 最近6-10首内

        /// 同 artist 近邻惩罚
        static let sameArtistRecent2: Double = 0.7

        /// 同 album 近邻惩罚
        static let sameAlbumRecent2: Double = 0.8

        /// 最低运行时权重（防止曲库小时彻底封杀）
        static let minimumRuntimeWeight: Double = 0.1
    }
}

// MARK: - Preference Features

/// 从原始统计计算出的比例特征
struct PreferenceFeatures {
    let plays: Double                    // max(playCount, 1.0)
    let completionRate: Double           // completePlayCount / plays
    let skipRate: Double                 // skipCount / plays
    let quickSkipRate: Double            // quickSkipCount / plays
    let avgListenRatio: Double           // totalPlayedSeconds / (duration * plays)
    let confidence: Double               // 低样本保护系数

    init(from stats: TrackPreferenceStats, duration: Double) {
        // 防零保护
        let rawPlayCount = max(stats.playCount, 0)
        self.plays = max(Double(rawPlayCount), 1.0)

        // 完成率
        self.completionRate = Double(stats.completePlayCount) / plays

        // 跳过率
        self.skipRate = Double(stats.skipCount) / plays

        // 快速跳过率
        self.quickSkipRate = Double(stats.quickSkipCount) / plays

        // 平均收听比例
        let estimatedTotalDuration = max(duration * plays, 1.0)
        let rawRatio = stats.totalPlayedSeconds / estimatedTotalDuration
        // Clamp 到合理范围（允许轻微溢出，但不超过 1.05）
        self.avgListenRatio = max(0.0, min(1.05, rawRatio))

        // 低样本保护置信度
        // log2(plays + 1) / 3.0, capped at 1.0
        let logValue = log2(plays + 1.0)
        self.confidence = min(logValue / PreferenceAlgorithmV2.confidenceDenominator, 1.0)
    }
}

// MARK: - Scoring Result

/// 完整的评分结果，用于调试和缓存
struct PreferenceScoreResult {
    // 输入特征
    let features: PreferenceFeatures

    // 中间计算值
    let completionCentered: Double
    let listenCentered: Double
    let rawPreference: Double
    let conservativePreference: Double
    let manualBias: Double
    let finalPreference: Double

    // 最终输出
    let boundedPreference: Double  // -1.0 ~ 1.0
    let baseWeight: Double         // 0.65 ~ 1.35

    /// 人类可读的偏好描述
    var preferenceDescription: String {
        switch boundedPreference {
        case ...(-0.5): return "明显不喜欢"
        case -0.5..<(-0.2): return "轻微不喜欢"
        case -0.2..<0.2: return "中性"
        case 0.2..<0.5: return "轻微喜欢"
        case 0.5...: return "明显喜欢"
        default: return "未知"
        }
    }
}

// MARK: - Preference Scorer V2

/// 温和、可恢复、抗误判的偏好评分器
@MainActor
final class PreferenceScorerV2 {

    // MARK: - Core Scoring

    /// 计算完整的偏好评分
    /// - Parameter now: 用于"跳过随时间恢复"的参考时刻，默认当前时间。
    static func calculateScore(
        stats: TrackPreferenceStats,
        duration: Double,
        manualLikeState: ManualLikeState = .none,
        now: Date = Date()
    ) -> PreferenceScoreResult {

        // 1. 提取特征
        let features = PreferenceFeatures(from: stats, duration: duration)

        // 2. 计算原始偏好分（基于比例，而非绝对次数）
        let completionCentered = features.completionRate - 0.5
        let listenCentered = features.avgListenRatio - 0.5

        // 负向信号（skip / quickSkip）经过衰减保护：完成度护盾 × 喜欢护盾 × 时间恢复。
        // 正向信号（完成率 / 收听比例）不衰减，因此正面播放天然能抵消少量跳过。
        let damping = negativeDamping(
            completionRate: features.completionRate,
            confidence: features.confidence,
            manualLikeState: manualLikeState,
            lastSkippedAt: stats.lastSkippedAt,
            now: now
        )

        let dampedNegative =
            (PreferenceAlgorithmV2.quickSkipRateCoeff * features.quickSkipRate +
             PreferenceAlgorithmV2.skipRateCoeff * features.skipRate) * damping

        let rawPreference =
            PreferenceAlgorithmV2.completionRateCoeff * completionCentered +
            PreferenceAlgorithmV2.listenRatioCoeff * listenCentered +
            dampedNegative

        // 3. 低样本保护
        let conservativePreference = rawPreference * features.confidence

        // 4. 手动偏好修正
        let manualBias: Double
        switch manualLikeState {
        case .liked: manualBias = PreferenceAlgorithmV2.manualLikedBias
        case .disliked: manualBias = PreferenceAlgorithmV2.manualDislikedBias
        case .none: manualBias = 0.0
        }

        let finalPreference = conservativePreference + manualBias

        // 5. 偏好压缩（饱和函数）
        let boundedPreference = tanh(finalPreference * PreferenceAlgorithmV2.compressionFactor)

        // 6. 映射到基础权重（温和范围）
        let baseWeight = PreferenceAlgorithmV2.neutralWeight +
            PreferenceAlgorithmV2.weightRange * boundedPreference

        return PreferenceScoreResult(
            features: features,
            completionCentered: completionCentered,
            listenCentered: listenCentered,
            rawPreference: rawPreference,
            conservativePreference: conservativePreference,
            manualBias: manualBias,
            finalPreference: finalPreference,
            boundedPreference: boundedPreference,
            baseWeight: baseWeight
        )
    }

    // MARK: - Cache Update

    /// 更新 TrackPreferenceStats 的缓存字段
    /// 注意：只更新缓存，不修改实际统计值
    static func updateCachedScores(
        stats: inout TrackPreferenceStats,
        duration: Double
    ) -> PreferenceScoreResult {
        let result = calculateScore(
            stats: stats,
            duration: duration,
            manualLikeState: stats.manualLikeState
        )

        // 缓存可解释的最终偏好值（非 bounded）
        // 这样人类可以读懂，bounded 后的值压缩太厉害不好读
        stats.preferenceScoreCache = result.finalPreference

        // 缓存基础权重（不含运行时惩罚）
        stats.effectiveWeightCache = result.baseWeight

        return result
    }

    // MARK: - Runtime Weight Adjustment

    /// 应用运行时惩罚（临时调整，不写回缓存）
    static func applyRuntimePenalties(
        baseWeight: Double,
        track: Track,
        recentHistory: [UUID],
        tracks: [UUID: Track]
    ) -> Double {
        var weight = baseWeight

        // 1. 最近同曲惩罚
        if let recentIndex = recentHistory.lastIndex(of: track.id) {
            let distanceFromEnd = recentHistory.count - recentIndex
            if distanceFromEnd <= 5 {
                weight *= PreferenceAlgorithmV2.RuntimePenalty.sameTrackRecent5
            } else if distanceFromEnd <= 10 {
                weight *= PreferenceAlgorithmV2.RuntimePenalty.sameTrackRecent10
            }
        }

        // 2. 同 artist 近邻惩罚
        let recentArtists = recentHistory
            .suffix(2)
            .compactMap { tracks[$0]?.artist }
        if !track.artist.isEmpty && recentArtists.contains(track.artist) {
            weight *= PreferenceAlgorithmV2.RuntimePenalty.sameArtistRecent2
        }

        // 3. 同 album 近邻惩罚
        let recentAlbums = recentHistory
            .suffix(2)
            .compactMap { tracks[$0]?.album }
        if !track.album.isEmpty && recentAlbums.contains(track.album) {
            weight *= PreferenceAlgorithmV2.RuntimePenalty.sameAlbumRecent2
        }

        // 确保最小运行时权重（防止曲库小时彻底封杀）
        return max(PreferenceAlgorithmV2.RuntimePenalty.minimumRuntimeWeight, weight)
    }

    // MARK: - Negative-signal Damping

    /// 计算负向信号的衰减系数（0~1），只作用于 skip / quickSkip 项。
    /// = 完成度护盾 × 手动喜欢护盾 × 时间恢复。
    static func negativeDamping(
        completionRate: Double,
        confidence: Double,
        manualLikeState: ManualLikeState,
        lastSkippedAt: Date?,
        now: Date
    ) -> Double {
        // 1. 完成度护盾：完成率高且数据可靠（confidence 高）的歌，跳过伤害更小。
        let shield = min(1.0, max(0.0, completionRate)) * confidence
        let completionDamping = 1.0 - shield * PreferenceAlgorithmV2.maxCompletionShield

        // 2. 手动喜欢护盾：liked 的歌跳过只作为轻微信号。
        let likedDamping = (manualLikeState == .liked)
            ? PreferenceAlgorithmV2.likedDamageScale
            : 1.0

        // 3. 时间恢复：距离上次跳过越久，旧跳过的影响越小（最低不低于 floor）。
        let recencyDamping: Double
        if let lastSkippedAt {
            let days = max(0.0, now.timeIntervalSince(lastSkippedAt) / 86_400.0)
            let floor = PreferenceAlgorithmV2.skipRecoveryFloor
            recencyDamping = floor + (1.0 - floor) * exp(-days / PreferenceAlgorithmV2.skipRecoveryDays)
        } else {
            recencyDamping = 1.0
        }

        return completionDamping * likedDamping * recencyDamping
    }

    // MARK: - Exploration / Rediscovery

    /// 温和、常驻的新鲜度乘子（>= 1.0）。长期未播放的歌获得小幅加权，
    /// 让随机播放不至于固化。明确不喜欢 / 高快速跳过的歌不参与。
    static func freshnessMultiplier(
        stats: TrackPreferenceStats,
        duration: Double,
        now: Date
    ) -> Double {
        guard stats.manualLikeState != .disliked else { return 1.0 }
        let features = PreferenceFeatures(from: stats, duration: duration)
        guard features.quickSkipRate <= PreferenceAlgorithmV2.explorationQuickSkipGuard else { return 1.0 }

        guard let last = stats.lastPlayedAt else {
            // 从未播放过 → 给一个适度的发现加成。
            return PreferenceAlgorithmV2.neverPlayedFreshness
        }
        let days = max(0.0, now.timeIntervalSince(last) / 86_400.0)
        return 1.0 + PreferenceAlgorithmV2.freshnessWeight *
            (1.0 - exp(-days / PreferenceAlgorithmV2.freshnessTauDays))
    }

    /// 再曝光资格（0~1）。低曝光（播放次数少）或长期未播放的歌资格更高，
    /// 由 ShuffleSession 小概率放大。disliked / 高快速跳过的歌资格为 0。
    static func rediscoveryEligibility(
        stats: TrackPreferenceStats,
        duration: Double,
        now: Date
    ) -> Double {
        guard stats.manualLikeState != .disliked else { return 0.0 }
        let features = PreferenceFeatures(from: stats, duration: duration)
        guard features.quickSkipRate <= PreferenceAlgorithmV2.explorationQuickSkipGuard else { return 0.0 }

        // 低播放次数 → 更值得曝光。
        let exposureFactor = 1.0 / (1.0 + Double(max(0, stats.playCount)))

        // 长期未播放 → 更值得曝光。
        let staleFactor: Double
        if let last = stats.lastPlayedAt {
            let days = max(0.0, now.timeIntervalSince(last) / 86_400.0)
            staleFactor = 1.0 - exp(-days / PreferenceAlgorithmV2.freshnessTauDays)
        } else {
            staleFactor = 1.0
        }

        return max(exposureFactor, staleFactor)
    }
}

// MARK: - Sample Calculation Helpers

extension PreferenceScorerV2 {
    /// 计算并打印典型样本（用于调试和验证）
    static func calculateAndPrintSample(
        playCount: Int,
        completePlayCount: Int,
        skipCount: Int,
        quickSkipCount: Int,
        totalPlayedSeconds: Double,
        duration: Double,
        manualLikeState: ManualLikeState = .none,
        label: String
    ) {
        var stats = TrackPreferenceStats()
        stats.playCount = playCount
        stats.completePlayCount = completePlayCount
        stats.skipCount = skipCount
        stats.quickSkipCount = quickSkipCount
        stats.totalPlayedSeconds = totalPlayedSeconds
        stats.manualLikeState = manualLikeState

        let result = calculateScore(stats: stats, duration: duration, manualLikeState: manualLikeState)

        print("""
        [Sample: \(label)]
          plays: \(Int(result.features.plays)), complete: \(completePlayCount), skip: \(skipCount), quickSkip: \(quickSkipCount)
          avgListenRatio: \(String(format: "%.2f", result.features.avgListenRatio))
          confidence: \(String(format: "%.2f", result.features.confidence))
          rawPreference: \(String(format: "%.3f", result.rawPreference))
          conservativePref: \(String(format: "%.3f", result.conservativePreference))
          finalPreference: \(String(format: "%.3f", result.finalPreference))
          boundedPreference: \(String(format: "%.3f", result.boundedPreference))
          baseWeight: \(String(format: "%.3f", result.baseWeight))
          => \(result.preferenceDescription)
        """)
    }
}
