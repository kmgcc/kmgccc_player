//
//  ImportProgressTypes.swift
//  myPlayer2
//

import Foundation

nonisolated enum BatchImportItemStage: Sendable {
    case scanning
    case ncmConversion
    case metadata
    case duplicateCheck
    case importing
    case enrichingMetadata
    case completed

    var title: String {
        switch self {
        case .scanning:
            return "扫描文件"
        case .ncmConversion:
            return "NCM 转换"
        case .metadata:
            return "解析信息"
        case .duplicateCheck:
            return "重复检查"
        case .importing:
            return "导入歌曲"
        case .enrichingMetadata:
            return "补全信息"
        case .completed:
            return "导入完成"
        }
    }
}

nonisolated enum BatchImportItemStatus: Sendable {
    case waiting
    case active
    case success
    case warning
    case skipped
    case failed

    var title: String {
        switch self {
        case .waiting:
            return "等待中"
        case .active:
            return "进行中"
        case .success:
            return "已完成"
        case .warning:
            return "有提示"
        case .skipped:
            return "已跳过"
        case .failed:
            return "失败"
        }
    }
}

nonisolated enum BatchImportStage {
    case scanning
    case convertingNCM
    case readingMetadata
    case waitingForDuplicateChoice
    case importingFiles
    case enrichingMetadata
    case savingLibrary
    case completed

    var title: String {
        switch self {
        case .scanning:
            return "正在扫描文件"
        case .convertingNCM:
            return "正在转换 NCM"
        case .readingMetadata:
            return "正在解析元数据"
        case .waitingForDuplicateChoice:
            return "等待处理重复歌曲"
        case .importingFiles:
            return "正在导入歌曲"
        case .enrichingMetadata:
            return "正在补全导入信息"
        case .savingLibrary:
            return "正在保存到资料库"
        case .completed:
            return "导入完成"
        }
    }

    var progressRange: ClosedRange<Double> {
        switch self {
        case .scanning:
            return 0.0...0.08
        case .convertingNCM:
            return 0.08...0.28
        case .readingMetadata:
            return 0.28...0.48
        case .waitingForDuplicateChoice:
            return 0.48...0.48
        case .importingFiles:
            return 0.48...0.82
        case .enrichingMetadata:
            return 0.82...0.96
        case .savingLibrary:
            return 0.96...0.995
        case .completed:
            return 1.0...1.0
        }
    }

    nonisolated static func progress(
        for stage: BatchImportStage,
        completed: Int,
        total: Int
    ) -> Double {
        let range = stage.progressRange
        guard total > 0 else { return range.upperBound }
        let ratio = min(max(Double(completed) / Double(total), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * ratio
    }
}

struct BatchImportProgressItemSeed {
    let id: String
    let fileName: String
}
