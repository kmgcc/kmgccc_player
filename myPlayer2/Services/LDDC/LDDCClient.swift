//
//  LDDCClient.swift
//  myPlayer2
//
//  TrueMusic - LDDC HTTP API Client
//  Makes requests to the local LDDC server.
//

import Foundation

/// HTTP client for the LDDC lyrics server.
actor LDDCClient {

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
        let manager = await LDDCServerManager.shared
        try await manager.ensureRunning()
        await manager.recordRequest()

        let url = await manager.baseURL.appendingPathComponent("search")

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

        let data = try await postJSON(url: url, body: body)

        let response = try JSONDecoder().decode(LDDCSearchResponse.self, from: data)

        // Log any errors from sources
        if let errors = response.errors, !errors.isEmpty {
            print("[LDDCClient] Search partial errors: \(errors)")
        }

        return response
    }

    /// Fetch lyrics for a specific candidate.
    func fetchById(
        candidate: LDDCCandidate,
        mode: LDDCMode = .verbatim,
        translation: Bool = false,
        offsetMs: Int = 0
    ) async throws -> String {
        let manager = await LDDCServerManager.shared
        try await manager.ensureRunning()
        await manager.recordRequest()

        let url = await manager.baseURL.appendingPathComponent("fetch_by_id")

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

        let data = try await postJSON(url: url, body: body)

        let response = try JSONDecoder().decode(LDDCFetchResponse.self, from: data)

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
        let manager = await LDDCServerManager.shared
        try await manager.ensureRunning()
        await manager.recordRequest()

        let url = await manager.baseURL.appendingPathComponent("fetch_by_id_separate")

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

        let data = try await postJSON(url: url, body: body)

        let response = try JSONDecoder().decode(LDDCFetchSeparateResponse.self, from: data)

        if let error = response.error {
            throw LDDCError.requestFailed(error)
        }

        guard let orig = response.lrcOrig else {
            throw LDDCError.noResults
        }

        return (orig, response.lrcTrans)
    }

    // MARK: - Private Methods

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

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
}
