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

    init(session: URLSession = NetEaseCoverService.makeDefaultSession()) {
        self.session = session
    }

    func searchAndDownloadCover(artist: String, album: String) async throws -> Data {
        let candidate = try await searchTopCoverCandidate(artist: artist, album: album)
        return candidate.imageData
    }

    func searchTopCoverCandidate(artist: String, album: String) async throws -> CoverCandidate {
        guard let albumResult = try await searchAlbumResults(
            artist: artist,
            album: album,
            limit: 1
        ).first else {
            throw NetEaseCoverError.noResults
        }

        return try await downloadCandidate(for: albumResult, artist: artist, album: album)
    }

    /// Searches NetEase for album covers and returns all candidates with metadata.
    /// Downloads covers for all matching albums (up to limit), sorted by resolution descending.
    func searchCoverCandidates(artist: String, album: String, limit: Int = 5) async throws -> [CoverCandidate] {
        try await searchCoverCandidates(artist: artist, album: album, limit: limit, stopAtTarget: false)
    }

    func searchCoverCandidates(artist: String, album: String, limit: Int = 5, stopAtTarget: Bool) async throws -> [CoverCandidate] {
        let albumResults = try await searchAlbumResults(artist: artist, album: album, limit: limit)

        // Download covers for all albums concurrently
        var candidates: [CoverCandidate] = []
        await withTaskGroup(of: CoverCandidate?.self) { group in
            for albumResult in albumResults {
                group.addTask {
                    do {
                        return try await self.downloadCandidate(for: albumResult, artist: artist, album: album)
                    } catch {
                        return nil
                    }
                }
            }
            for await candidate in group {
                if let candidate = candidate {
                    candidates.append(candidate)
                    if stopAtTarget,
                       CoverCandidateSorter.bestAutomaticCandidate(from: candidates.filter(\.meetsAutomaticTarget)) != nil {
                        group.cancelAll()
                        break
                    }
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
    struct AlbumSearchResult: Sendable {
        let id: Int
        let picURL: String
        let name: String?
        let artist: String?
    }

    func searchAlbumResults(artist: String, album: String, limit: Int) async throws -> [AlbumSearchResult] {
        let cleanArtist = LibraryNormalization.isUnknownArtist(artist) ? "" : artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = LibraryNormalization.isUnknownAlbum(album) ? "" : album.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = "\(cleanArtist) \(cleanAlbum)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString =
            "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=\(limit)"
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

        let albums = result.result.albums.map {
            AlbumSearchResult(id: $0.id, picURL: $0.picURL, name: $0.name, artist: $0.artist?.name ?? $0.artists?.first?.name)
        }
        guard !albums.isEmpty else {
            throw NetEaseCoverError.noResults
        }
        return albums
    }

    func downloadCandidate(for albumResult: AlbumSearchResult, artist: String, album: String) async throws -> CoverCandidate {
        guard let coverURL = URL(string: Self.makeLargeCoverURLString(from: albumResult.picURL)) else {
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
            return CoverCandidate(
                imageData: imageData,
                source: .netease,
                sourceItemId: String(albumResult.id),
                confidence: Self.matchConfidence(artist: artist, album: album, result: albumResult),
                matchedArtist: albumResult.artist,
                matchedAlbum: albumResult.name,
                imageURL: coverURL.absoluteString
            )
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.imageDownloadFailed(underlying: error)
        }
    }

    struct NetEaseSearchResponse: Decodable {
        let result: ResultPayload

        struct ResultPayload: Decodable {
            let albums: [Album]
        }

        struct Album: Decodable {
            let id: Int
            let picURL: String
            let name: String?
            let artist: Artist?
            let artists: [Artist]?

            struct Artist: Decodable { let name: String? }

            enum CodingKeys: String, CodingKey {
                case id
                case picURL = "picUrl"
                case name, artist, artists
            }
        }
    }

    nonisolated static func matchConfidence(artist: String, album: String, result: AlbumSearchResult) -> Double {
        let albumScore = ExternalPlaybackTextNormalizer.stringSimilarity(
            ExternalPlaybackTextNormalizer.normalize(album), ExternalPlaybackTextNormalizer.normalize(result.name))
        guard !artist.isEmpty, !LibraryNormalization.isUnknownArtist(artist) else { return albumScore }
        let artistScore = ExternalPlaybackTextNormalizer.artistSimilarity(
            ExternalPlaybackTextNormalizer.normalizeArtist(artist), ExternalPlaybackTextNormalizer.normalizeArtist(result.artist))
        guard artistScore >= 0.45 else { return 0 }
        return albumScore * 0.65 + artistScore * 0.35
    }

    nonisolated static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = CoverLookupConfiguration.netEasePreferredTimeout
        configuration.timeoutIntervalForResource = CoverLookupConfiguration.netEaseCandidatesTimeout
        return URLSession(configuration: configuration)
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

extension NetEaseCoverService {
    nonisolated static func makeLargeCoverURLString(from picURLString: String) -> String {
        guard var url = URLComponents(string: picURLString) else { return picURLString }
        // The catalog URL is the original; `param` asks the CDN to resize it.
        let query = url.queryItems?.filter { $0.name != "param" }
        url.queryItems = query?.isEmpty == false ? query : nil
        return url.string ?? picURLString
    }
}
