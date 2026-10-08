import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
struct AutomationHistoryHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.historyList:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let from = try parameters.date("from")
                let to = try parameters.date("to")
                if let from, let to, from > to {
                    throw AutomationParameterError.invalidValue("from/to")
                }
                let trackID = try parameters.uuid("trackID")
                let query = try parameters.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let artistContains = try parameters.string("artistContains")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let albumContains = try parameters.string("albumContains")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedRevision = try parameters.string("expectedRevision")
                let items: [PlaybackHistoryItem]
                if from != nil || to != nil {
                    items = session.playbackHistoryStore.fetchItems(
                        from: from ?? .distantPast,
                        to: to
                    )
                } else {
                    items = session.playbackHistoryStore.fetchItems()
                }
                let orderedItems = items.sorted {
                    if $0.playedAt != $1.playedAt { return $0.playedAt > $1.playedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                let revision = playbackHistoryRevision(orderedItems)
                if let expectedRevision, expectedRevision != revision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "Playback history changed while the results were being paginated.",
                            retryable: true,
                            details: .object([
                                "expectedRevision": .string(expectedRevision),
                                "actualRevision": .string(revision)
                            ])
                        )
                    )
                }
                let filteredItems = orderedItems.filter { item in
                    if let trackID, item.trackID != trackID { return false }
                    if let query, !query.isEmpty,
                       !item.title.localizedCaseInsensitiveContains(query),
                       !item.artist.localizedCaseInsensitiveContains(query),
                       !item.album.localizedCaseInsensitiveContains(query) {
                        return false
                    }
                    if let artistContains, !artistContains.isEmpty,
                       !item.artist.localizedCaseInsensitiveContains(artistContains) {
                        return false
                    }
                    if let albumContains, !albumContains.isEmpty,
                       !item.album.localizedCaseInsensitiveContains(albumContains) {
                        return false
                    }
                    return true
                }
                let pageStart = min(offset, filteredItems.count)
                let pageEnd = min(pageStart + limit, filteredItems.count)
                let page = Array(filteredItems[pageStart..<pageEnd])
                return AutomationResponseSupport.encodeResult(
                    AutomationHistoryListResult(
                        items: page.map(makeHistoryItem),
                        revision: revision,
                        total: filteredItems.count,
                        offset: offset,
                        limit: limit,
                        nextOffset: pageEnd < filteredItems.count ? pageEnd : nil
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.historyStats:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let from = try parameters.date("from")
                let to = try parameters.date("to")
                if let from, let to, from > to {
                    throw AutomationParameterError.invalidValue("from/to")
                }
                let dimension = try parameters.string("dimension") ?? "all"
                guard ["all", "track", "artist", "album"].contains(dimension) else {
                    throw AutomationParameterError.invalidValue("dimension")
                }
                let limit = try parameters.integer("limit", default: 20)
                guard (1...100).contains(limit) else { throw AutomationParameterError.outOfRange("limit") }
                let items = (from != nil || to != nil)
                    ? session.playbackHistoryStore.fetchItems(from: from ?? .distantPast, to: to)
                    : session.playbackHistoryStore.fetchItems()

                struct Aggregate {
                    var name: String
                    var count = 0
                    var seconds = 0.0
                }
                func aggregates(_ keyPath: KeyPath<PlaybackHistoryItem, String>, unknown: String) -> [AutomationHistoryDimensionSummary] {
                    var values: [String: Aggregate] = [:]
                    for item in items {
                        let name = item[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedName = name.isEmpty ? unknown : name
                        let key = normalizedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        var value = values[key, default: Aggregate(name: normalizedName)]
                        value.count += 1
                        value.seconds += max(0, item.playedSeconds)
                        values[key] = value
                    }
                    return values.map { key, value in
                        AutomationHistoryDimensionSummary(key: key, name: value.name, playCount: value.count, playedSeconds: value.seconds)
                    }.sorted {
                        if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                        if $0.playedSeconds != $1.playedSeconds { return $0.playedSeconds > $1.playedSeconds }
                        return $0.key < $1.key
                    }.prefix(limit).map { $0 }
                }
                let trackStats = dimension == "all" || dimension == "track"
                    ? aggregates(\.title, unknown: "Unknown Track") : []
                let artistStats = dimension == "all" || dimension == "artist"
                    ? aggregates(\.artist, unknown: "Unknown Artist") : []
                let albumStats = dimension == "all" || dimension == "album"
                    ? aggregates(\.album, unknown: "Unknown Album") : []
                return AutomationResponseSupport.encodeResult(AutomationHistoryStatsResult(
                    from: from, to: to, playCount: items.count,
                    distinctTrackCount: Set(items.map(\.trackID)).count,
                    distinctArtistCount: Set(items.map { $0.artist.lowercased() }).count,
                    distinctAlbumCount: Set(items.map { $0.album.lowercased() }).count,
                    playedSeconds: items.reduce(0) { $0 + max(0, $1.playedSeconds) },
                    topTracks: trackStats, topArtists: artistStats, topAlbums: albumStats,
                    revision: playbackHistoryRevision(items)
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.historyClear:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let count = session.playbackHistoryStore.fetchItems().count
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationHistoryListResult(
                            items: [],
                            revision: "v1-\(session.playbackHistoryStore.revision)"
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "清除播放记录需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["recordCount": .number(Double(count))])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "清除播放记录？",
                    message: "要删除 \(count) 条播放记录吗？此操作无法在播放器中撤销。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard session.playbackHistoryStore.clearAll() else {
                    throw AutomationParameterError.invalidValue("history")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationHistoryListResult(
                        items: [],
                        revision: "v1-\(session.playbackHistoryStore.revision)"
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func makeHistoryItem(_ item: PlaybackHistoryItem) -> AutomationHistoryItem {
        AutomationHistoryItem(
            id: item.id,
            trackID: item.trackID,
            playedAt: item.playedAt,
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            playedSeconds: item.playedSeconds
        )
    }

    private func playbackHistoryRevision(_ items: [PlaybackHistoryItem]) -> String {
        let orderedItems = items.sorted {
            if $0.playedAt != $1.playedAt { return $0.playedAt > $1.playedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let data = try? AutomationWireCoding.encoder().encode(orderedItems.map(makeHistoryItem)) else {
            return "history-v1-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "history-v1-" + digest
    }
}
