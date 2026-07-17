//
//  LDDCClient.swift
//  myPlayer2
//
//  kmgccc_player - LDDC HTTP API Client
//  Makes requests to the local LDDC server.
//

import Foundation

/// HTTP client for the LDDC lyrics server.
actor LDDCClient {

    /// Stateless apart from its URLSession, so view code can share one instance
    /// instead of paying URLSession creation per SwiftUI struct init.
    static let shared = LDDCClient()

    private let session: URLSession
    private let timeout: TimeInterval = 30

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Search for lyrics across multiple platforms.
    func search(
        title: String,
        artist: String?,
        sources: [LDDCSource],
        mode: LDDCMode = .verbatim,
        translation: Bool = false,
        limitPerSource: Int = 20
    ) async throws -> LDDCSearchResponse {
        var body: [String: Any] = [
            "title": title,
            "sources": sources.map { $0.rawValue },
            "limit_per_source": limitPerSource,
            "mode": mode.rawValue,
            "translation": translation ? "provider" : "none",
        ]

        if let artist = artist, !artist.isEmpty {
            body["artist"] = artist
        }

        let data = try await postJSON(path: "search", body: body)

        let response = try await MainActor.run {
            try JSONDecoder().decode(LDDCSearchResponse.self, from: data)
        }

        // Log any errors from sources
        if let errors = response.errors, !errors.isEmpty {
            print("[LDDCClient] Search partial errors: \(errors)")
        }

        return response
    }

    /// Search each provider independently and yield outcomes as they finish.
    ///
    /// The bundled server is able to handle these requests concurrently. This
    /// keeps one slow provider from delaying or erasing results from the others.
    func searchBySource(
        title: String,
        artist: String?,
        sources: [LDDCSource],
        mode: LDDCMode = .verbatim,
        translation: Bool = false,
        limitPerSource: Int = 20
    ) -> AsyncStream<LDDCSourceSearchResult> {
        let client = self
        let orderedSources = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        let (stream, continuation) = AsyncStream<LDDCSourceSearchResult>.makeStream()

        let worker = Task {
            await withTaskGroup(of: LDDCSourceSearchResult?.self) { group in
                for source in orderedSources {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }

                        do {
                            let response = try await client.search(
                                title: title,
                                artist: artist,
                                sources: [source],
                                mode: mode,
                                translation: translation,
                                limitPerSource: limitPerSource
                            )

                            guard !Task.isCancelled else { return nil }
                            return LDDCSourceSearchResult(
                                source: source,
                                results: response.results,
                                errors: response.errors ?? []
                            )
                        } catch {
                            guard !Task.isCancelled, !Self.isCancellationError(error) else {
                                return nil
                            }

                            return LDDCSourceSearchResult(
                                source: source,
                                results: [],
                                errors: [error.localizedDescription]
                            )
                        }
                    }
                }

                while let result = await group.next() {
                    if let result {
                        continuation.yield(result)
                    }
                }
            }

            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            worker.cancel()
        }

        return stream
    }

    /// Fetch lyrics for a specific candidate.
    func fetchById(
        candidate: LDDCCandidate,
        mode: LDDCMode = .verbatim,
        translation: Bool = false,
        offsetMs: Int = 0
    ) async throws -> String {
        var body: [String: Any] = [
            "source": candidate.source,
            "id": candidate.songId,
            "mode": mode.rawValue,
            "translation": translation ? "provider" : "none",
            "offset_ms": offsetMs,
        ]

        // Include additional info needed for some providers
        if let title = candidate.title as String? {
            body["title"] = title
        }
        if let artist = candidate.artist {
            body["artist"] = artist
        }
        if let album = candidate.album {
            body["album"] = album
        }
        if let duration = candidate.durationMs {
            body["duration_ms"] = duration
        }
        if let extra = candidate.extra {
            body["extra"] = extra
        }

        let data = try await postJSON(path: "fetch_by_id", body: body)

        let response = try await MainActor.run {
            try JSONDecoder().decode(LDDCFetchResponse.self, from: data)
        }

        if let error = response.error {
            throw LDDCError.requestFailed(error)
        }

        guard let lrc = response.lrc else {
            throw LDDCError.noResults
        }

        return lrc
    }

    /// Fetch lyrics with original and translation separated.
    func fetchByIdSeparate(
        candidate: LDDCCandidate,
        mode: LDDCMode = .verbatim,
        offsetMs: Int = 0
    ) async throws -> (orig: String, trans: String?) {
        var body: [String: Any] = [
            "source": candidate.source,
            "id": candidate.songId,
            "mode": mode.rawValue,
            "translation": "provider",  // Always request translation for separate endpoint
            "offset_ms": offsetMs,
        ]

        // Include additional info needed for some providers
        if let title = candidate.title as String? {
            body["title"] = title
        }
        if let artist = candidate.artist {
            body["artist"] = artist
        }
        if let album = candidate.album {
            body["album"] = album
        }
        if let duration = candidate.durationMs {
            body["duration_ms"] = duration
        }
        if let extra = candidate.extra {
            body["extra"] = extra
        }

        let data = try await postJSON(path: "fetch_by_id_separate", body: body)

        let response = try await MainActor.run {
            try JSONDecoder().decode(LDDCFetchSeparateResponse.self, from: data)
        }

        if let error = response.error {
            throw LDDCError.requestFailed(error)
        }

        guard let orig = response.lrcOrig else {
            throw LDDCError.noResults
        }

        return (orig, response.lrcTrans)
    }

    // MARK: - Private Methods

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        let manager = await LDDCServerManager.shared
        try await manager.ensureRunning()

        let url = await manager.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await manager.beginRequest()
        let networkResponse: (Data, URLResponse)
        do {
            networkResponse = try await session.data(for: request)
        } catch {
            await manager.endRequest()
            throw error
        }
        await manager.endRequest()

        let (data, response) = networkResponse

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LDDCError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            // Try to parse error message
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let errorMsg = json["error"] as? String
            {
                throw LDDCError.requestFailed(errorMsg)
            }
            throw LDDCError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    nonisolated private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}
