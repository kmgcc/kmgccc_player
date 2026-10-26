//
//  AppleMusicArtworkResolver.swift
//  myPlayer2
//
//  Background network fallback for Apple Music artwork.
//

import Foundation
import ImageIO

actor AppleMusicArtworkResolver {
    private struct NetEaseSearchResponse: Decodable {
        let result: ResultPayload?

        struct ResultPayload: Decodable {
            let albums: [Album]?
        }

        struct Album: Decodable {
            let id: Int
            let name: String?
            let artists: [Artist]?
            struct Artist: Decodable { let name: String? }
            let picURL: String

            enum CodingKeys: String, CodingKey {
                case id, name, artists
                case picURL = "picUrl"
            }
        }
    }

    private let session: URLSession
    private var cache = CostBoundedCache<String, Data?>(
        countLimit: 32,
        totalCostLimit: 8 * 1024 * 1024
    )
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(session: URLSession = AppleMusicArtworkResolver.makeDefaultSession()) {
        self.session = session
    }

    func cachedArtwork(for identity: String) -> Data?? {
        cache.value(forKey: identity)
    }

    func removeCachedArtwork(for identity: String) {
        cache.removeValue(forKey: identity)
    }

    func clearCache() {
        cache.removeAll()
        inFlight.removeAll()
    }

    func resolveNetworkArtwork(
        identity: String,
        title: String,
        artist: String?,
        album: String?
    ) async -> Data? {
        if let cached = cache.value(forKey: identity) {
            return cached
        }

        if let task = inFlight[identity] {
            return await task.value
        }

        let task = Task<Data?, Never> {
            let result = await self.fetchNetworkArtwork(title: title, artist: artist, album: album)
            return result
        }
        inFlight[identity] = task
        let result = await task.value
        cache.insert(result, forKey: identity, cost: result?.count ?? 1)
        inFlight[identity] = nil
        return result
    }

    private func fetchNetworkArtwork(title: String, artist: String?, album: String?) async -> Data? {
        let queries = makeQueries(title: title, artist: artist, album: album)
        for query in queries {
            guard !Task.isCancelled else { return nil }
            if let data = await fetchFirstNetEaseCover(query: query, expectedArtist: artist, expectedAlbum: album) {
                return data
            }
        }
        return nil
    }

    private func fetchFirstNetEaseCover(query: String, expectedArtist: String?, expectedAlbum: String?) async -> Data? {
        let artistKey = ExternalPlaybackTextNormalizer.normalizedKey(expectedArtist ?? "")
        let albumKey = ExternalPlaybackTextNormalizer.normalizedKey(expectedAlbum ?? "")
        guard !artistKey.isEmpty, !albumKey.isEmpty else { return nil }
        Log.info("[AMArtwork] provider=netease event=attempt artist=\(expectedArtist ?? "") album=\(expectedAlbum ?? "")", category: .playback)
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(
                string: "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=1"
              ) else {
            return nil
        }

        do {
            let (searchData, response) = try await session.data(from: searchURL)
            guard Self.isSuccessfulHTTP(response) else { return nil }
            let decoded = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
            guard let album = decoded.result?.albums?.first,
                  ExternalPlaybackTextNormalizer.normalizedKey(album.name ?? "") == albumKey,
                  album.artists?.contains(where: { ExternalPlaybackTextNormalizer.normalizedKey($0.name ?? "") == artistKey }) == true,
                  let coverURL = URL(string: Self.largeCoverURLString(from: album.picURL)) else {
                return nil
            }

            let (imageData, imageResponse) = try await session.data(from: coverURL)
            guard Self.isSuccessfulHTTP(imageResponse),
                  Self.isValidImageData(imageData) else {
                return nil
            }
            Log.info("[AMArtwork] provider=netease event=result matchedAlbumID=\(album.id)", category: .playback)
            return imageData
        } catch {
            return nil
        }
    }

    private func makeQueries(title: String, artist: String?, album: String?) -> [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var queries: [String] = []
        if !trimmedArtist.isEmpty && !trimmedAlbum.isEmpty {
            queries.append("\(trimmedArtist) \(trimmedAlbum)")
        }
        if !trimmedAlbum.isEmpty {
            queries.append(trimmedAlbum)
        }
        if !trimmedArtist.isEmpty && !trimmedTitle.isEmpty {
            queries.append("\(trimmedArtist) \(trimmedTitle)")
        }
        if !trimmedTitle.isEmpty {
            queries.append(trimmedTitle)
        }

        var seen = Set<String>()
        return queries.filter { query in
            let key = query.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func largeCoverURLString(from picURLString: String) -> String {
        if picURLString.contains("?") {
            return "\(picURLString)&param=1200y1200"
        }
        return "\(picURLString)?param=1200y1200"
    }

    private static func isSuccessfulHTTP(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private static func isValidImageData(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return true
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }
}
