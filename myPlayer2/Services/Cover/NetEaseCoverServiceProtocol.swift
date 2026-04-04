//
//  NetEaseCoverServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - NetEase Cover Service Protocol
//

import AppKit
import Foundation

@MainActor
protocol NetEaseCoverServiceProtocol: AnyObject {
    func searchAndDownloadCover(artist: String, album: String) async throws -> Data
    func searchCoverCandidates(artist: String, album: String, limit: Int) async throws -> [CoverCandidate]
}
