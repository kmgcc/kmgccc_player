//
//  LyricsSearchCoordinator.swift
//  myPlayer2
//
//  Coordinates progressive lyric search across AMLLDB and LDDC providers.
//

import Foundation

/// A progressive update emitted while a lyric search is running.
enum LyricsSearchUpdate: Sendable {
    case amlldbStatus(message: String, isUpdating: Bool)
    case amlldbResults([LDDCCandidate])
    case amlldbFailure(String)
    case lddc(LDDCSourceSearchResult)
}

/// Owns the search fan-out and keeps provider/index lifecycle out of views.
///
/// AMLLDB and LDDC run as independent branches. LDDC itself is split by
/// provider, so a slow source can report an error without withholding results
/// from sources that already completed.
@MainActor
final class LyricsSearchCoordinator {

    static let shared = LyricsSearchCoordinator()

    private let lddcClient = LDDCClient.shared
    private let amlldbService = AMLLDBService.shared

    private init() {}

    func search(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        lddcSources: Set<LDDCSource>,
        enableAMLLDB: Bool,
        mode: LDDCMode,
        translation: Bool,
        amlldbLimit: Int = 20,
        lddcLimitPerSource: Int = 20
    ) -> AsyncStream<LyricsSearchUpdate> {
        let (stream, continuation) = AsyncStream<LyricsSearchUpdate>.makeStream()

        let worker = Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }

            let amlldbService = self.amlldbService
            let lddcClient = self.lddcClient
            let sources = Array(lddcSources)

            // A first-use AMLLDB index build and a first-use LDDC helper launch
            // are both expensive. Serialize only that cold-start phase; once
            // the index is cached, the actual searches can run concurrently.
            if enableAMLLDB && !amlldbService.getIndexStatus().hasIndexData {
                await Self.emitAMLLDBSearchIfEnabled(
                    service: amlldbService,
                    enabled: true,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    limit: amlldbLimit,
                    continuation: continuation
                )

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                await Self.emitLDDCSearch(
                    client: lddcClient,
                    sources: sources,
                    title: title,
                    artist: artist,
                    mode: mode,
                    translation: translation,
                    limitPerSource: lddcLimitPerSource,
                    continuation: continuation
                )
            } else {
                async let amlldbSearch: Void = Self.emitAMLLDBSearchIfEnabled(
                    service: amlldbService,
                    enabled: enableAMLLDB,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    limit: amlldbLimit,
                    continuation: continuation
                )
                async let lddcSearch: Void = Self.emitLDDCSearch(
                    client: lddcClient,
                    sources: sources,
                    title: title,
                    artist: artist,
                    mode: mode,
                    translation: translation,
                    limitPerSource: lddcLimitPerSource,
                    continuation: continuation
                )

                await amlldbSearch
                await lddcSearch
            }

            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            worker.cancel()
        }

        return stream
    }

    private static func emitAMLLDBSearchIfEnabled(
        service: AMLLDBService,
        enabled: Bool,
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        limit: Int,
        continuation: AsyncStream<LyricsSearchUpdate>.Continuation
    ) async {
        guard enabled else { return }
        await emitAMLLDBSearch(
            service: service,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            limit: limit,
            continuation: continuation
        )
    }

    private static func emitLDDCSearch(
        client: LDDCClient,
        sources: [LDDCSource],
        title: String,
        artist: String?,
        mode: LDDCMode,
        translation: Bool,
        limitPerSource: Int,
        continuation: AsyncStream<LyricsSearchUpdate>.Continuation
    ) async {
        guard !sources.isEmpty else { return }

        let updates = await client.searchBySource(
            title: title,
            artist: artist,
            sources: sources,
            mode: mode,
            translation: translation,
            limitPerSource: limitPerSource
        )

        for await update in updates {
            guard !Task.isCancelled else { return }
            continuation.yield(.lddc(update))
        }
    }

    private static func emitAMLLDBSearch(
        service: AMLLDBService,
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        limit: Int,
        continuation: AsyncStream<LyricsSearchUpdate>.Continuation
    ) async {
        let initialStatus = service.getIndexStatus()
        var status = initialStatus

        if !status.hasIndexData {
            continuation.yield(.amlldbStatus(
                message: "正在初始化 AMLLDB 索引...",
                isUpdating: true
            ))

            let ready = await service.ensureIndexReady()
            guard !Task.isCancelled else { return }

            status = service.getIndexStatus()
            if ready && status.hasIndexData {
                continuation.yield(.amlldbStatus(
                    message: "AMLLDB 索引已就绪（\(status.entryCount) 条）",
                    isUpdating: false
                ))
            } else {
                continuation.yield(.amlldbFailure(
                    service.lastError ?? "AMLLDB 索引初始化失败"
                ))
                return
            }
        }

        guard !Task.isCancelled, status.hasIndexData else { return }

        let results = service.search(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            limit: limit
        )

        guard !Task.isCancelled else { return }
        continuation.yield(.amlldbResults(results.map { $0.toLDDCCandidate() }))
    }
}
