//
//  NetEaseCoverService.swift
//  myPlayer2
//
//  kmgccc_player - NetEase Cover Service
//

import AppKit
import Observation
import Foundation

@Observable
@MainActor
final class NetEaseCoverService: NetEaseCoverServiceProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchAndDownloadCover(artist: String, album: String) async throws -> Data {
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString =
            "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=5"
        guard let searchURL = URL(string: searchURLString) else {
            throw NetEaseCoverError.badURL
        }

        let searchData: Data
        do {
            let (data, response) = try await session.data(from: searchURL)
            try Self.validateHTTP(response: response)
            searchData = data
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.requestFailed(underlying: error)
        }

        let result: NetEaseSearchResponse
        do {
            result = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        } catch {
            throw NetEaseCoverError.decodingFailed(underlying: error)
        }

        guard let picURLString = result.result.albums.first?.picURL else {
            throw NetEaseCoverError.noResults
        }

        let finalCoverURLString = Self.makeLargeCoverURLString(from: picURLString)
        guard let coverURL = URL(string: finalCoverURLString) else {
            throw NetEaseCoverError.badURL
        }

        do {
            let (imageData, response) = try await session.data(from: coverURL)
            try Self.validateHTTP(response: response)
            guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
                throw NetEaseCoverError.imageDownloadFailed(
                    underlying: CoverDownloadError.invalidImageData
                )
            }
            return imageData
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.imageDownloadFailed(underlying: error)
        }
    }

    /// Searches NetEase for album covers and returns all candidates with metadata.
    /// Downloads covers for all matching albums (up to limit), sorted by resolution descending.
    func searchCoverCandidates(artist: String, album: String, limit: Int = 5) async throws -> [CoverCandidate] {
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString = "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=\(limit)"
        guard let searchURL = URL(string: searchURLString) else {
            throw NetEaseCoverError.badURL
        }

        let searchData: Data
        do {
            let (data, response) = try await session.data(from: searchURL)
            try Self.validateHTTP(response: response)
            searchData = data
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.requestFailed(underlying: error)
        }

        let result: NetEaseSearchResponse
        do {
            result = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        } catch {
            throw NetEaseCoverError.decodingFailed(underlying: error)
        }

        guard !result.result.albums.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        // Download covers for all albums concurrently
        var candidates: [CoverCandidate] = []
        await withTaskGroup(of: CoverCandidate?.self) { group in
            for albumResult in result.result.albums {
                group.addTask {
                    let picURLString = albumResult.picURL
                    guard let coverURL = URL(string: Self.makeLargeCoverURLString(from: picURLString)) else {
                        return nil
                    }
                    do {
                        let (imageData, response) = try await self.session.data(from: coverURL)
                        try Self.validateHTTP(response: response)
                        guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
                            return nil
                        }
                        return await MainActor.run {
                            CoverCandidate(
                                imageData: imageData,
                                source: .netease,
                                sourceItemId: String(albumResult.id)
                            )
                        }
                    } catch {
                        return nil
                    }
                }
            }
            for await candidate in group {
                if let candidate = candidate {
                    candidates.append(candidate)
                }
            }
        }

        guard !candidates.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        // Sort by resolution descending (highest first)
        return candidates.sorted { $0.resolution > $1.resolution }
    }
}

private extension NetEaseCoverService {
    struct NetEaseSearchResponse: Decodable {
        let result: ResultPayload

        struct ResultPayload: Decodable {
            let albums: [Album]
        }

        struct Album: Decodable {
            let id: Int
            let picURL: String

            enum CodingKeys: String, CodingKey {
                case id
                case picURL = "picUrl"
            }
        }
    }

    nonisolated static func makeLargeCoverURLString(from picURLString: String) -> String {
        if picURLString.contains("?") {
            return "\(picURLString)&param=1200y1200"
        }
        return "\(picURLString)?param=1200y1200"
    }

    nonisolated static func validateHTTP(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let error = NSError(
                domain: "NetEaseCoverService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
            throw NetEaseCoverError.requestFailed(underlying: error)
        }
    }
}
