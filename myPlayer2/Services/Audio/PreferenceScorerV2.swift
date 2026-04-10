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
    static let quickSkipRateCoeff: Double = -0.9
    static let skipRateCoeff: Double = -0.3

    /// 手动偏好修正
    static let manualLikedBias: Double = 0.18
    static let manualDislikedBias: Double = -0.18

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
    static func calculateScore(
        stats: TrackPreferenceStats,
        duration: Double,
        manualLikeState: ManualLikeState = .none
    ) -> PreferenceScoreResult {

        // 1. 提取特征
        let features = PreferenceFeatures(from: stats, duration: duration)

        // 2. 计算原始偏好分（基于比例，而非绝对次数）
        let completionCentered = features.completionRate - 0.5
        let listenCentered = features.avgListenRatio - 0.5

        let rawPreference =
            PreferenceAlgorithmV2.completionRateCoeff * completionCentered +
            PreferenceAlgorithmV2.listenRatioCoeff * listenCentered +
            PreferenceAlgorithmV2.quickSkipRateCoeff * features.quickSkipRate +
            PreferenceAlgorithmV2.skipRateCoeff * features.skipRate

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
