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

    private struct SourceAttempt: Sendable {
        let source: LDDCSource
        let startedAt: Date
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Search one provider. Multi-provider callers must use searchBySource so
    /// each provider has independent timeout and health handling.
    private func searchSingleSource(
        title: String,
        artist: String?,
        source: LDDCSource,
        mode: LDDCMode = .verbatim,
        translation: Bool = false,
        limitPerSource: Int = 20,
        requestTimeout: TimeInterval? = nil
    ) async throws -> LDDCSearchResponse {
        var body: [String: Any] = [
            "title": title,
            "sources": [source.rawValue],
            "limit_per_source": limitPerSource,
            "mode": mode.rawValue,
            "translation": translation ? "provider" : "none",
        ]

        if let artist = artist, !artist.isEmpty {
            body["artist"] = artist
        }

        let data = try await postJSON(
            path: "search",
            body: body,
            timeout: requestTimeout ?? timeout
        )

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
        limitPerSource: Int = 20,
        policy: LDDCSourceSearchPolicy = .adaptive
    ) -> AsyncStream<LDDCSourceSearchResult> {
        let client = self
        let orderedSources = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        let (stream, continuation) = AsyncStream<LDDCSourceSearchResult>.makeStream()
        let sourceHealth = LDDCSourceHealthStore.shared
        let sourceTimeout = LDDCSourceHealthStore.slowSourceTimeout

        let worker = Task {
            await withTaskGroup(of: LDDCSourceSearchResult?.self) { group in
                for source in orderedSources {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }

                        let decision = await sourceHealth.decision(for: source, policy: policy)
                        let attemptStartedAt: Date
                        switch decision {
                        case .attempt(let startedAt):
                            attemptStartedAt = startedAt
                        case .skip(let retryAfter):
                            let retrySeconds = max(
                                1,
                                Int(retryAfter.timeIntervalSinceNow.rounded(.up))
                            )
                            return LDDCSourceSearchResult(
                                source: source,
                                results: [],
                                errors: [
                                    "\(source.displayName) 已暂时跳过：上次请求超过 \(Int(sourceTimeout)) 秒未响应，约 \(retrySeconds) 秒后重试"
                                ],
                                status: .skipped
                            )
                        }

                        do {
                            let response = try await client.searchSingleSource(
                                title: title,
                                artist: artist,
                                source: source,
                                mode: mode,
                                translation: translation,
                                limitPerSource: limitPerSource,
                                requestTimeout: sourceTimeout
                            )

                            guard !Task.isCancelled else { return nil }
                            await sourceHealth.recordSuccess(
                                for: source,
                                attemptStartedAt: attemptStartedAt
                            )
                            return LDDCSourceSearchResult(
                                source: source,
                                results: response.results,
                                errors: response.errors ?? [],
                                status: .completed
                            )
                        } catch {
                            guard !Task.isCancelled, !Self.isCancellationError(error) else {
                                return nil
                            }

                            if Self.isTimeoutError(error) {
                                await sourceHealth.recordTimeout(
                                    for: source,
                                    attemptStartedAt: attemptStartedAt
                                )
                                return LDDCSourceSearchResult(
                                    source: source,
                                    results: [],
                                    errors: [
                                        "\(source.displayName) 请求超过 \(Int(sourceTimeout)) 秒未响应，已暂时降低优先级"
                                    ],
                                    status: .timedOut
                                )
                            }

                            return LDDCSourceSearchResult(
                                source: source,
                                results: [],
                                errors: [error.localizedDescription],
                                status: .failed
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
        offsetMs: Int = 0,
        requestTimeout: TimeInterval? = nil,
        policy: LDDCSourceSearchPolicy = .forceAll
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

        let attempt = try await beginSourceAttempt(for: candidate, policy: policy)
        let data: Data
        do {
            data = try await postJSON(
                path: "fetch_by_id",
                body: body,
                timeout: requestTimeout ?? timeout
            )
            await finishSourceAttempt(attempt, error: nil)
        } catch {
            await finishSourceAttempt(attempt, error: error)
            throw error
        }

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
        offsetMs: Int = 0,
        requestTimeout: TimeInterval? = nil,
        policy: LDDCSourceSearchPolicy = .forceAll
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

        let attempt = try await beginSourceAttempt(for: candidate, policy: policy)
        let data: Data
        do {
            data = try await postJSON(
                path: "fetch_by_id_separate",
                body: body,
                timeout: requestTimeout ?? timeout
            )
            await finishSourceAttempt(attempt, error: nil)
        } catch {
            await finishSourceAttempt(attempt, error: error)
            throw error
        }

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

    private func beginSourceAttempt(
        for candidate: LDDCCandidate,
        policy: LDDCSourceSearchPolicy
    ) async throws -> SourceAttempt? {
        guard let source = LDDCSource(rawValue: candidate.source) else {
            return nil
        }

        let decision = await LDDCSourceHealthStore.shared.decision(
            for: source,
            policy: policy
        )
        switch decision {
        case .attempt(let startedAt):
            return SourceAttempt(source: source, startedAt: startedAt)
        case .skip(let retryAfter):
            let retrySeconds = max(
                1,
                Int(retryAfter.timeIntervalSinceNow.rounded(.up))
            )
            throw LDDCError.sourceTemporarilyUnavailable(
                "\(source.displayName) 已暂时跳过：上次请求超过 \(Int(LDDCSourceHealthStore.slowSourceTimeout)) 秒未响应，约 \(retrySeconds) 秒后重试"
            )
        }
    }

    private func finishSourceAttempt(
        _ attempt: SourceAttempt?,
        error: Error?
    ) async {
        guard let attempt else { return }

        if let error {
            guard Self.isTimeoutError(error) else { return }
            await LDDCSourceHealthStore.shared.recordTimeout(
                for: attempt.source,
                attemptStartedAt: attempt.startedAt
            )
        } else {
            await LDDCSourceHealthStore.shared.recordSuccess(
                for: attempt.source,
                attemptStartedAt: attempt.startedAt
            )
        }
    }

    private func postJSON(
        path: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> Data {
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

    nonisolated private static func isTimeoutError(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }
}
