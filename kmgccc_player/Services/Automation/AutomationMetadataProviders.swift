import Foundation
import PlayerAutomationProtocol

nonisolated struct MusicBrainzAutomationCandidate: Sendable, Equatable {
    let recordingID: String
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?
    let releaseID: String?
    let releaseDate: String?
    let genreTags: [String]
}

enum MusicBrainzAutomationProviderError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidRecordingID

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "MusicBrainz returned an invalid response."
        case .httpStatus(let status):
            "MusicBrainz returned HTTP \(status)."
        case .invalidRecordingID:
            "The MusicBrainz candidate ID is invalid."
        }
    }
}

/// The App-owned Metadata search adapter for MusicBrainz. Requests are
/// serialized at the service's documented one-request-per-second average.
actor MusicBrainzAutomationProvider {
    static let shared = MusicBrainzAutomationProvider()

    private struct SearchResponse: Decodable {
        let recordings: [Recording]
    }

    private struct Recording: Decodable {
        let id: String
        let title: String
        let length: Int?
        let artistCredit: [ArtistCredit]?
        let firstReleaseDate: String?
        let releases: [Release]?
        let genres: [Tag]?
        let tags: [Tag]?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case length
            case artistCredit = "artist-credit"
            case firstReleaseDate = "first-release-date"
            case releases
            case genres
            case tags
        }

        var artistName: String? {
            let names = artistCredit?.compactMap { credit in
                credit.name ?? credit.artist?.name
            }.filter { !$0.isEmpty } ?? []
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }

        var genreNames: [String] {
            Array(Set((genres ?? []).map(\.name) + (tags ?? []).map(\.name)))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted()
                .prefix(12)
                .map { $0 }
        }
    }

    private struct ArtistCredit: Decodable {
        let name: String?
        let artist: Artist?
    }

    private struct Artist: Decodable {
        let name: String?
    }

    private struct Release: Decodable {
        let id: String
        let title: String
        let date: String?
    }

    private struct Tag: Decodable {
        let name: String
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let clock = ContinuousClock()
    private var nextRequestAt = ContinuousClock.now
    private let userAgent: String

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        userAgent = "myPlayer2/\(version) (https://github.com/kmgcc/kmgccc_player)"
    }

    func search(
        title: String,
        artist: String,
        album: String,
        durationSeconds: Double?
    ) async throws -> [MusicBrainzAutomationCandidate] {
        var terms = ["recording:\(Self.quoted(title))"]
        if !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            terms.append("artist:\(Self.quoted(artist))")
        }
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            terms.append("release:\(Self.quoted(album))")
        }
        let query = terms.joined(separator: " AND ")
        let url = try Self.endpoint(path: "recording", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10")
        ])
        let response: SearchResponse = try await get(url, as: SearchResponse.self)
        return response.recordings.map { recording in
            let release = Self.bestRelease(recording.releases ?? [], queryAlbum: album)
            return MusicBrainzAutomationCandidate(
                recordingID: recording.id,
                title: recording.title,
                artist: recording.artistName,
                album: release?.title,
                durationSeconds: recording.length.map { Int((Double($0) / 1_000).rounded()) },
                releaseID: release?.id,
                releaseDate: release?.date ?? recording.firstReleaseDate,
                genreTags: recording.genreNames
            )
        }
    }

    func recording(id: String) async throws -> MusicBrainzAutomationCandidate? {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.caseInsensitiveCompare(id) == .orderedSame else {
            throw MusicBrainzAutomationProviderError.invalidRecordingID
        }
        let url = try Self.endpoint(path: "recording/\(uuid.uuidString.lowercased())", queryItems: [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "artists+releases+genres+tags")
        ])
        let recording: Recording = try await get(url, as: Recording.self)
        let release = Self.bestRelease(recording.releases ?? [], queryAlbum: "")
        return MusicBrainzAutomationCandidate(
            recordingID: recording.id,
            title: recording.title,
            artist: recording.artistName,
            album: release?.title,
            durationSeconds: recording.length.map { Int((Double($0) / 1_000).rounded()) },
            releaseID: release?.id,
            releaseDate: release?.date ?? recording.firstReleaseDate,
            genreTags: recording.genreNames
        )
    }

    private func get<Response: Decodable>(_ url: URL, as type: Response.Type) async throws -> Response {
        try await waitForRequestSlot()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MusicBrainzAutomationProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MusicBrainzAutomationProviderError.httpStatus(response.statusCode)
        }
        return try decoder.decode(type, from: data)
    }

    private func waitForRequestSlot() async throws {
        let now = clock.now
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.advanced(by: .seconds(1))
        let delay = now.duration(to: scheduled)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
    }

    private static func endpoint(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/\(path)"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MusicBrainzAutomationProviderError.invalidResponse
        }
        return url
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func bestRelease(_ releases: [Release], queryAlbum: String) -> Release? {
        guard !releases.isEmpty else { return nil }
        guard !queryAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return releases.first
        }
        return releases.max { lhs, rhs in
            let leftScore = AutomationMetadataQualityEvaluator.score(
                queryTitle: queryAlbum,
                queryArtist: "",
                queryAlbum: "",
                queryDurationSeconds: nil,
                candidateTitle: lhs.title,
                candidateArtist: nil,
                candidateAlbum: nil,
                candidateDurationSeconds: nil
            ) ?? 0
            let rightScore = AutomationMetadataQualityEvaluator.score(
                queryTitle: queryAlbum,
                queryArtist: "",
                queryAlbum: "",
                queryDurationSeconds: nil,
                candidateTitle: rhs.title,
                candidateArtist: nil,
                candidateAlbum: nil,
                candidateDurationSeconds: nil
            ) ?? 0
            if leftScore == rightScore {
                return (lhs.date ?? "9999") > (rhs.date ?? "9999")
            }
            return leftScore < rightScore
        }
    }
}
