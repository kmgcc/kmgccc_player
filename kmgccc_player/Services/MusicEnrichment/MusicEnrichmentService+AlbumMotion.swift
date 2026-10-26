import Foundation

extension MusicEnrichmentService {
    /// Resolves an album default without starting a provider or changing the
    /// record timestamp. It also accepts tracks with no individual JSON yet.
    func loadSnapshot(for query: MusicEnrichmentQuery) async throws -> MusicEnrichmentSnapshot? {
        guard !isClosed else { throw CancellationError() }
        let loaded = try await store.load(key: query.key)
        let valid = loaded.map { $0.version >= 2 && Self.albumQueryMatches($0.query, query) } ?? true
        var input = query
        if !valid, input.storedMotionArtwork?.isUserSelected != true { input.storedMotionArtwork = nil }
        var record = valid ? (loaded ?? MusicEnrichmentRecord(query: input)) : MusicEnrichmentRecord(query: input)
        if !valid, let loaded {
            record.manualAttributes = loaded.manualAttributes
            record.manualMotionSelection = loaded.manualMotionSelection
            if loaded.manualMotionSelection != nil { record.assets = loaded.assets }
        }
        record.query = input
        Self.restoreStoredMotion(in: &record, from: input)
        var snapshot = await store.snapshot(record)
        guard !snapshot.record.results.isEmpty || !snapshot.record.assets.isEmpty
                || snapshot.record.manualMotionSelection != nil || snapshot.record.manualAttributes?.isEmpty == false else { return nil }
        if loaded == nil || !valid {
            snapshot.record.updatedAt = try await store.albumMotionUpdatedAt(for: snapshot.record)
                ?? loaded?.updatedAt ?? Date(timeIntervalSince1970: 0)
        }
        return snapshot
    }

    nonisolated private static func albumQueryMatches(_ a: MusicEnrichmentQuery, _ b: MusicEnrichmentQuery) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album
            && a.albumArtist == b.albumArtist && abs(a.duration - b.duration) < 0.01
            && a.appleSongID == b.appleSongID && a.appleAlbumID == b.appleAlbumID
            && a.isrc == b.isrc && a.storefront == b.storefront
    }

    /// One automatic download per album and shape, shared by playback and the
    /// idle pass. Cancelling a viewer does not cancel another song's download;
    /// closing the library cancels the owning tasks.
    func automaticMotion(_ descriptor: MotionArtworkDescriptor, for record: MusicEnrichmentRecord) async throws -> StoredMotionArtwork? {
        guard !isClosed else { throw CancellationError() }
        if record.manualMotionSelection == nil,
           let existing = try await store.albumMotion(for: record, kind: descriptor.kind) { return existing }
        // An explicit album choice, including none, is never filled in automatically.
        if record.manualMotionSelection == nil,
           try await store.albumMotionState(for: record)?.isUserSelected == true { return nil }
        let identity = record.manualMotionSelection == nil ? (record.albumMotionIdentity ?? record.motionAlbumIdentity?.key) : nil
        let key = "\(identity ?? record.query.key):\(descriptor.kind)"
        if record.manualMotionSelection == nil, let requested = record.motionAlbumIdentity {
            for (runningKey, runningIdentity) in albumMotionTaskIdentities where runningKey.hasSuffix(":\(descriptor.kind)") {
                guard runningIdentity.fallbackKey != nil, runningIdentity.fallbackKey == requested.fallbackKey,
                      runningIdentity.catalogAlbumID == nil || requested.catalogAlbumID == nil || runningIdentity.catalogAlbumID == requested.catalogAlbumID,
                      let pending = albumMotionTasks[runningKey] else { continue }
                return try await pending.value
            }
        }
        if let pending = albumMotionTasks[key] { return try await pending.value }
        let operation = Task<StoredMotionArtwork?, Error> { [store, client] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-motion-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let materialized = try await client.materialize(descriptor, destination: directory.appendingPathComponent("artwork.mp4"))
            try Task.checkCancellation()
            guard let asset = try await store.importMotion(from: URL(fileURLWithPath: materialized.path), descriptor: descriptor,
                startTime: materialized.startTime, duration: materialized.duration,
                queryKey: record.query.key, albumIdentity: identity) else { return nil }
            if identity != nil { try await store.saveAlbumMotion(asset, for: record) }
            return asset
        }
        albumMotionTasks[key] = operation
        if record.manualMotionSelection == nil { albumMotionTaskIdentities[key] = record.motionAlbumIdentity }
        defer { albumMotionTasks[key] = nil; albumMotionTaskIdentities[key] = nil }
        return try await operation.value
    }

    // MARK: Album choices

    /// The stored record (or a fresh one) whose catalog result names the album.
    /// Reading never rewrites the song's record.
    private func albumBaseRecord(for query: MusicEnrichmentQuery) async throws -> MusicEnrichmentRecord {
        guard !isClosed else { throw CancellationError() }
        var record = MusicEnrichmentRecord(query: query)
        if let loaded = try await store.load(key: query.key), loaded.version >= 2,
           loaded.query.album == query.album, loaded.query.artist == query.artist {
            record.results = loaded.results
        }
        return record
    }

    func albumMotionState(for query: MusicEnrichmentQuery) async throws -> MusicEnrichmentStore.AlbumMotionState? {
        try await store.albumMotionState(for: albumBaseRecord(for: query))
    }

    /// The album's own square artwork as a local file, for the album page.
    func albumMotionResource(for query: MusicEnrichmentQuery) async throws -> MotionArtworkResource? {
        let base = try await albumBaseRecord(for: query)
        return await store.snapshot(base).squareArtwork
    }

    /// Downloads a search result into the album. Returns false when the song
    /// has no album to share with, so the caller keeps the choice on the song.
    @discardableResult
    func setAlbumMotion(_ candidate: MusicEnrichmentResult, for query: MusicEnrichmentQuery) async throws -> Bool {
        let base = try await albumBaseRecord(for: query)
        guard let albumKey = try await store.albumMotionState(for: base)?.key else { return false }
        var kinds = Set<String>()
        let descriptors = (candidate.motion ?? []).filter { ["square", "tall"].contains($0.kind) && kinds.insert($0.kind).inserted }
        guard !descriptors.isEmpty else { throw MusicEnrichmentHelperError.invalidResponse }
        let store = store, client = client
        let operation = Task<[StoredMotionArtwork], Error> {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("album-selection-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            return try await withThrowingTaskGroup(of: StoredMotionArtwork?.self) { group in
                for descriptor in descriptors {
                    group.addTask {
                        do {
                            let materialized = try await client.materialize(descriptor, destination: directory.appendingPathComponent("\(descriptor.kind).mp4"))
                            return try await store.importMotion(from: URL(fileURLWithPath: materialized.path), descriptor: descriptor,
                                startTime: materialized.startTime, duration: materialized.duration, albumIdentity: albumKey)
                        } catch is CancellationError { throw CancellationError() }
                        catch { return nil }
                    }
                }
                var assets: [StoredMotionArtwork] = []
                for try await asset in group { if let asset { assets.append(asset) } }
                return assets
            }
        }
        let assets = try await trackIndependent(operation)
        guard !assets.isEmpty else { throw MusicEnrichmentHelperError.invalidResponse }
        try await commitAlbumMotion(assets, userSelected: true, base: base)
        return true
    }

    /// Copies a user video into the album, shown in both shapes.
    @discardableResult
    func importAlbumMotionVideo(from url: URL, for query: MusicEnrichmentQuery) async throws -> Bool {
        let base = try await albumBaseRecord(for: query)
        guard let albumKey = try await store.albumMotionState(for: base)?.key else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let validated = try await validateMotionVideo(from: url)
        try Task.checkCancellation()
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "importedVideo:\(UUID().uuidString)",
            width: validated.width, height: validated.height)
        guard let square = try await store.importMotion(from: url, descriptor: descriptor, startTime: 0,
            duration: validated.duration, fileExtension: validated.fileExtension, albumIdentity: albumKey) else { throw CancellationError() }
        var tall = square
        tall.kind = "tall"
        try await commitAlbumMotion([square, tall], userSelected: true, base: base)
        return true
    }

    /// Removes the album's artwork (`resumeAutomatic` false keeps it empty) or
    /// hands the album back to the automatic search, which starts right away.
    func clearAlbumMotion(for query: MusicEnrichmentQuery, resumeAutomatic: Bool) async throws {
        let base = try await albumBaseRecord(for: query)
        try await commitAlbumMotion([], userSelected: !resumeAutomatic, base: base)
        guard resumeAutomatic, AppSettings.isMotionArtworkFetchEnabled else { return }
        Task { [weak self] in _ = try? await self?.completeAlbumMotion(queries: [query]) }
    }

    private func commitAlbumMotion(_ assets: [StoredMotionArtwork], userSelected: Bool, base: MusicEnrichmentRecord) async throws {
        guard !isClosed else { throw CancellationError() }
        guard let identity = base.motionAlbumIdentity,
              let key = try await store.setAlbumMotion(assets, userSelected: userSelected, for: base) else { return }
        let artwork = assets.isEmpty ? nil : TrackMotionArtwork(albumAssets: assets, catalogAlbumID: identity.catalogAlbumID, albumIdentity: key)
        onAlbumMotionChange?(identity, artwork)
        // The playing song may belong to the album that just changed.
        await refreshCurrentMotion()
    }

    // MARK: Album completion

    /// Finds an album's artwork once for all of its songs. Songs are tried in
    /// order until one matches the catalog; a song with its own choice is
    /// skipped. Returns true when the album has artwork or an explicit choice.
    @discardableResult
    func completeAlbumMotion(queries: [MusicEnrichmentQuery], context: BackgroundWorkContext? = nil) async throws -> Bool {
        var lastError: Error?
        for query in queries.prefix(3) {
            try Task.checkCancellation()
            try await context?.checkpoint()
            guard !isClosed else { throw CancellationError() }
            let base = try await albumBaseRecord(for: query)
            if let state = try await store.albumMotionState(for: base), state.isUserSelected || !state.assets.isEmpty { return true }
            if let loaded = try await store.load(key: query.key), loaded.manualMotionSelection != nil { continue }
            do {
                let snapshot = try await completeIndependently(query: query, includeMotion: true,
                    providers: ["appleCache", "appleWeb"], context: context)
                if snapshot.squareArtwork != nil || snapshot.tallArtwork != nil { return true }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        return false
    }
}
