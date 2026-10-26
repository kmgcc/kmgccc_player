import Foundation

/// Shared by import, missing-cover completion and the one-time renovation.
/// Provider operations remain cancellable so an early result actually ends
/// network/process work when the structured group drains.
nonisolated enum AutomaticCoverLookup {
    struct Provider: Sendable {
        var source: CoverSource
        var timeout: TimeInterval
        var search: @Sendable () async throws -> [CoverCandidate]
    }

    private struct Batch: Sendable {
        var candidates: [CoverCandidate]
        var failed: Bool
    }

    static func select(providers: [Provider], fallbackDelay: Duration = .milliseconds(600)) async throws -> CoverCandidate? {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Batch.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        if provider.source != .appleMusic { try await Task.sleep(for: fallbackDelay) }
                        let candidates = try await withCoverLookupTimeout(provider.timeout, operation: provider.search)
                        return Batch(candidates: candidates, failed: false)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        Log.info("[CoverLookup] provider=\(provider.source.shortLabel) event=failed errorType=\(String(describing: type(of: error)))", category: .import)
                        return Batch(candidates: [], failed: true)
                    }
                }
            }
            var candidates: [CoverCandidate] = []
            var failed = false
            while let batch = try await group.next() {
                try Task.checkCancellation()
                candidates += batch.candidates
                failed = failed || batch.failed
                if let ready = CoverCandidateSorter.bestAutomaticCandidate(from: candidates.filter(\.meetsAutomaticTarget)) {
                    group.cancelAll()
                    return ready
                }
            }
            let best = CoverCandidateSorter.bestAutomaticCandidate(from: candidates)
            if best == nil && failed { throw MusicEnrichmentHelperError.network("cover lookup failed") }
            return best
        }
    }

    static func search(title: String?, artist: String, album: String, duration: Double?,
                       qqMusic: QQMusicCoverService) async throws -> CoverCandidate? {
        let hasAlbum = !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LibraryNormalization.isUnknownAlbum(album)
        let hasArtist = !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LibraryNormalization.isUnknownArtist(artist)
        guard title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || hasAlbum else { return nil }
        var providers = ["appleCache", "appleWeb"].map { provider in
            Provider(source: .appleMusic, timeout: CoverLookupConfiguration.appleMusicTimeout) {
                try await appleCandidates(provider: provider, title: title, artist: artist, album: album, duration: duration)
            }
        }
        providers.append(Provider(source: .qqmusic, timeout: CoverLookupConfiguration.qqMusicCandidatesTimeout) {
            do {
                return try await qqMusic.searchCoverCandidates(title: title, artist: artist, album: album, duration: duration,
                    limit: CoverLookupConfiguration.qqMusicCandidateLimit, stopAtTarget: true)
            } catch QQMusicCoverError.noResults { return [] }
        })
        if hasAlbum {
            providers.append(Provider(source: .netease, timeout: CoverLookupConfiguration.netEaseCandidatesTimeout) {
                let service = await NetEaseCoverService()
                do { return try await service.searchCoverCandidates(artist: artist, album: album, stopAtTarget: true) }
                catch NetEaseCoverError.noResults { return [] }
            })
        }
        if hasAlbum && hasArtist {
            providers.append(Provider(source: .sacad, timeout: CoverLookupConfiguration.sacadTimeout) {
                let data = try await CoverDownloadService.downloadCoverData(artist: artist, album: album, size: 1200)
                return [CoverCandidate(imageData: data, source: .sacad, sourceItemId: "\(artist):\(album)",
                                       matchedArtist: artist, matchedAlbum: album)]
            })
        }
        return try await select(providers: providers)
    }

    static func appleCandidates(provider: String, title: String?, artist: String, album: String, duration: Double?) async throws -> [CoverCandidate] {
        let client = MusicEnrichmentHelperClient()
        let query = MusicEnrichmentQuery(key: "coverSearch", title: title ?? "", artist: artist, album: album, duration: duration ?? 0)
        guard let result = try await client.fetch(provider: provider == "appleWeb" ? "appleArtwork" : provider, query: query),
              let artwork = (result.attributes?["artwork"] ?? result.attributes?["albumArtwork"])?.dictionary,
              let template = artwork["url"]?.text else { return [] }
        let width = max(1, Int(artwork["width"]?.text ?? "") ?? 1200)
        let height = max(1, Int(artwork["height"]?.text ?? "") ?? 1200)
        guard let url = URL(string: template.replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height)).replacingOccurrences(of: "{f}", with: "jpg")
            .replacingOccurrences(of: "{c}", with: "bb")) else { return [] }
        let data = try await client.artworkData(from: url)
        try Task.checkCancellation()
        return [CoverCandidate(imageData: data, source: .appleMusic, sourceItemId: result.songID ?? result.albumID,
            confidence: result.confidence, matchedTitle: result.attributes?["name"]?.text,
            matchedArtist: result.attributes?["artistName"]?.text, matchedAlbum: result.attributes?["albumName"]?.text,
            imageURL: url.absoluteString)]
    }
}
