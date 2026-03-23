//
//  CoverServiceModels.swift
//  myPlayer2
//
//  kmgccc_player - Shared Cover Service Models
//

import Foundation

enum CoverDownloadError: Error {
    case executableMissing(path: String)
    case processFailed(exitCode: Int32, message: String)
    case outputMissing
    case invalidImageData
    case cancelled
}

enum NetEaseCoverError: Error {
    case badURL
    case requestFailed(underlying: Error)
    case decodingFailed(underlying: Error)
    case noResults
    case imageDownloadFailed(underlying: Error)
}

enum CoverSource {
    case sacad
    case netease
}
