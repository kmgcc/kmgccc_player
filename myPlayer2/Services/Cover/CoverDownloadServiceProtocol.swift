//
//  CoverDownloadServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - Cover Download Service Protocol
//

import Foundation

@MainActor
protocol CoverDownloadServiceProtocol: AnyObject {
    func downloadCover(artist: String, album: String, size: Int) async throws -> Data
}
