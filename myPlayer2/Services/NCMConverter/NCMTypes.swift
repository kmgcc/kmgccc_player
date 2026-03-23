//
//  NCMTypes.swift
//  myPlayer2
//
//  kmgccc_player - NCM 共享类型定义
//

import Foundation

// MARK: - Conversion Step

enum NCMConversionStep {
    case waiting
    case decrypting
    case downloadingCover
    case completed
    case failed
    
    var description: String {
        switch self {
        case .waiting: return "准备中..."
        case .decrypting: return "正在解密..."
        case .downloadingCover: return "获取封面..."
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
    
    var progressRange: ClosedRange<Double> {
        switch self {
        case .waiting: return 0.0...0.0
        case .decrypting: return 0.0...0.7
        case .downloadingCover: return 0.7...0.95
        case .completed: return 0.95...1.0
        case .failed: return 0.0...0.0
        }
    }
}

// MARK: - Conversion Result

struct NCMConversionResult {
    let audioFileURL: URL
    let format: NCMFormat
    let metadata: NCMMetadata
    let coverData: Data?
}

enum NCMFormat: String {
    case mp3 = "mp3"
    case flac = "flac"
}

// MARK: - Metadata

struct NCMMetadata: Codable {
    let musicName: String
    let artist: [[String]]
    let album: String
    let albumPic: String
    let format: String
    let bitrate: Int
    let duration: Int
    
    var title: String { musicName }
    var artistName: String {
        artist.map { $0.first ?? "" }.joined(separator: ", ")
    }
    var durationSeconds: Double { Double(duration) / 1000.0 }
    var albumPicURL: URL? {
        guard !albumPic.isEmpty else { return nil }
        return URL(string: albumPic)
    }
}

// MARK: - Errors

enum NCMConverterError: Error, LocalizedError {
    case invalidFile
    case invalidMagic
    case decryptionFailed
    case keyDecryptionFailed
    case metadataDecryptionFailed
    case unsupportedFormat
    case fileReadError
    case fileWriteError
    case networkError
    case invalidMetadata
    
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无效的文件"
        case .invalidMagic: return "不是有效的 NCM 文件"
        case .decryptionFailed: return "音频解密失败"
        case .keyDecryptionFailed: return "密钥解密失败"
        case .metadataDecryptionFailed: return "元数据解密失败"
        case .unsupportedFormat: return "不支持的音频格式"
        case .fileReadError: return "文件读取错误"
        case .fileWriteError: return "文件写入错误"
        case .networkError: return "网络错误"
        case .invalidMetadata: return "无效的元数据"
        }
    }
}
