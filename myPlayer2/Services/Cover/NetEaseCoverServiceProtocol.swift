//
//  NetEaseCoverServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - NetEase Cover Service Protocol
//

import Foundation

@MainActor
protocol NetEaseCoverServiceProtocol: AnyObject {
    func searchAndDownloadCover(artist: String, album: String) async throws -> Data
}
