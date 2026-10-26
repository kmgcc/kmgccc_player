import Foundation

extension MusicEnrichmentService {
    func loadSnapshot(for key: String) async throws -> MusicEnrichmentSnapshot? {
        guard !isClosed else { throw CancellationError() }
        guard let record = try await store.load(key: key), record.version >= 2 else { return nil }
        return await store.snapshot(record)
    }

    func listRecords(offset: Int, limit: Int) async throws -> (records: [MusicEnrichmentRecord], nextOffset: Int?) {
        try await store.listRecords(offset: offset, limit: limit)
    }

    nonisolated static let completionProviders = ["appleCache", "appleWeb", "musicBrainz", "amllDB"]

    /// Library preparation and automation share this path without taking over
    /// the playback query. Providers and media run serially to keep idle work gentle.
    /// `providers` narrows the pass, e.g. to the catalog sources motion artwork needs.
    func completeIndependently(query: MusicEnrichmentQuery, force: Bool = false, includeMotion: Bool = true,
                               providers: [String] = completionProviders, context: BackgroundWorkContext? = nil) async throws -> MusicEnrichmentSnapshot {
        try await trackIndependent(Task { try await self.performCompletion(query: query, force: force, includeMotion: includeMotion, providers: providers, context: context) })
    }

    private func performCompletion(query: MusicEnrichmentQuery, force: Bool, includeMotion: Bool, providers: [String], context: BackgroundWorkContext?) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        let loaded = try await store.load(key: query.key)
        let expectedQuery = loaded?.query ?? query
        var record = loaded ?? MusicEnrichmentRecord(query: query)
        let invalidated = record.version < 2 || !Self.completionMatches(record.query, query)
        var input = query
        if invalidated, input.storedMotionArtwork?.isUserSelected != true { input.storedMotionArtwork = nil }
        if invalidated {
            let manual = record.manualMotionSelection
            let attributes = record.manualAttributes
            let assets = manual == nil ? [] : record.assets
            record = MusicEnrichmentRecord(query: query)
            record.manualMotionSelection = manual
            record.manualAttributes = attributes
            record.assets = assets
        }
        if invalidated { try await store.removeArtwork(key: query.key) }
        record.query = input
        Self.restoreStoredMotion(in: &record, from: input)
        // Persist a first recovery from the Track before awaiting providers.
        // Thereafter nil in the store is authoritative, including an explicit
        // request to resume automatic artwork while this pass is in flight.
        if loaded?.manualMotionSelection == nil, let recovered = record.manualMotionSelection {
            let recoveredAssets = record.assets
            let recoveryQuery = record.query
            let recoveredRecord = try await store.updateRecord(key: query.key, fallbackQuery: input) { latest in
                try Task.checkCancellation()
                let unchanged = loaded.map { latest == $0 }
                    ?? (latest.query == recoveryQuery && latest.results.isEmpty && latest.assets.isEmpty && latest.manualMotionSelection == nil)
                guard unchanged else { return }
                latest.manualMotionSelection = recovered
                latest.assets = recoveredAssets
                latest.query.storedMotionArtwork = recoveryQuery.storedMotionArtwork
            }
            record.manualMotionSelection = recoveredRecord.manualMotionSelection
            record.assets = recoveredRecord.assets
            record.query.storedMotionArtwork = recoveredRecord.query.storedMotionArtwork
        }
        var lastError: Error?
        for provider in providers {
            try Task.checkCancellation()
            try await context?.checkpoint()
            guard !isClosed else { throw CancellationError() }
            if !force, record.results.contains(where: { $0.source == provider }) { continue }
            if provider == "amllDB", record.resolvedAppleSongID == nil { continue }
            var providerQuery = record.query
            if provider == "amllDB" { providerQuery.appleSongID = record.resolvedAppleSongID }
            Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=attempt mode=independent", category: .library)
            do {
                if let result = try await client.fetch(provider: provider, query: providerQuery) {
                    Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=result mode=independent match=\(result.matchKind ?? "unknown") confidence=\(result.confidence ?? 0)", category: .library)
                    record.merge(result)
                } else {
                    Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=empty mode=independent", category: .library)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=failed mode=independent errorType=\(String(describing: type(of: error)))", category: .library)
                lastError = error
            }
        }
        // Preserve an edit or playback arrival made while the network was busy.
        if let latest = try await store.load(key: query.key), latest.version >= 2, Self.completionMatches(latest.query, query) {
            for result in latest.results where !record.results.contains(where: { $0.source == result.source }) { record.merge(result) }
            record.manualAttributes = latest.manualAttributes
            record.manualMotionSelection = latest.manualMotionSelection
            record.query.storedMotionArtwork = latest.query.storedMotionArtwork
            record.assets = latest.assets
        }
        record = try await store.resolveMotion(in: record)
        if includeMotion, record.manualMotionSelection == nil {
            for descriptor in record.motionDescriptors where ["square", "tall"].contains(descriptor.kind) {
                try Task.checkCancellation()
                try await context?.checkpoint()
                if record.assets.contains(where: { $0.kind == descriptor.kind }) { continue }
                let asset = try await automaticMotion(descriptor, for: record)
                try Task.checkCancellation()
                try await context?.checkpoint()
                guard !isClosed else { throw CancellationError() }
                // An explicit selection always wins over the automatic pass.
                if let latest = try await store.load(key: query.key), latest.manualMotionSelection != nil {
                    record.manualMotionSelection = latest.manualMotionSelection
                    record.assets = latest.assets
                    break
                }
                if let asset { record.assets.append(asset) }
            }
        }
        if let url = Self.artworkURL(record.attributes), (await store.snapshot(record)).artworkData == nil {
            try await context?.checkpoint()
            let data = try await client.artworkData(from: url)
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            try await store.importArtwork(data, key: query.key)
        }
        try Task.checkCancellation()
        try await context?.checkpoint()
        guard !isClosed else { throw CancellationError() }

        if currentKey == query.key, let active = currentRecord {
            guard Self.completionMatches(active.query, query) else { throw CancellationError() }
            for result in active.results where !record.results.contains(where: { $0.source == result.source }) { record.merge(result) }
        }
        let proposed = record
        record = try await store.updateRecord(key: query.key, fallbackQuery: query) { latest in
            try Task.checkCancellation()
            guard Self.completionMatches(latest.query, query) || Self.completionMatches(latest.query, expectedQuery) else { throw CancellationError() }
            let manual = latest.manualMotionSelection
            let attributes = latest.manualAttributes
            let manualAssets = latest.assets
            let storedMotionArtwork = latest.query.storedMotionArtwork
            let selectionChanged = manual != proposed.manualMotionSelection
                || storedMotionArtwork != proposed.query.storedMotionArtwork
            let concurrentResults = Self.completionMatches(latest.query, query) && latest.version >= 2 ? latest.results : []
            latest = proposed
            latest.manualAttributes = attributes
            latest.manualMotionSelection = manual
            latest.query.storedMotionArtwork = storedMotionArtwork
            if manual != nil || selectionChanged {
                // A clear/resume also discards assets recovered from the old
                // manual selection. A later automatic pass may download anew.
                latest.assets = manualAssets
            }
            for result in concurrentResults where !latest.results.contains(where: { $0.source == result.source }) { latest.merge(result) }
        }
        let snapshot = await store.snapshot(record)
        record = snapshot.record
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        if currentKey == query.key {
            guard currentRecord.map({ Self.completionMatches($0.query, query) }) ?? true else { throw CancellationError() }
            currentRecord = record
            await publish(generation: generation, persist: false)
        } else { onSnapshot?(snapshot) }
        if let lastError { throw lastError }
        return snapshot
    }
    nonisolated private static func completionMatches(_ a: MusicEnrichmentQuery, _ b: MusicEnrichmentQuery) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && abs(a.duration - b.duration) < 0.01
    }
}
