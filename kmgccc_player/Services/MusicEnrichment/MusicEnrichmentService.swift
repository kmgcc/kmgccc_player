import Foundation
import Observation

nonisolated protocol MusicEnrichmentFetching: Sendable {
    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult?
    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MusicEnrichmentHelperClient.MaterializedMotion
    func artworkData(from url: URL) async throws -> Data
    func searchMotion(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult]
}

extension MusicEnrichmentFetching {
    nonisolated func searchMotion(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult] { [] }

    nonisolated func artworkData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard !data.isEmpty,
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") != false else {
            throw MusicEnrichmentHelperError.invalidResponse
        }
        return data
    }
}

extension MusicEnrichmentHelperClient: MusicEnrichmentFetching {}

/// One library owns one enrichment service. Provider arrivals fill the current
/// record independently; media downloads never hold up metadata publication.
@Observable
@MainActor
final class MusicEnrichmentService {
    var onChange: (() -> Void)?
    var onSnapshot: ((MusicEnrichmentSnapshot) -> Void)?
    /// An album's artwork changed (nil: none); songs without their own choice follow it.
    var onAlbumMotionChange: ((MusicAlbumMotionIdentity, TrackMotionArtwork?) -> Void)?

    private var currentSnapshot: MusicEnrichmentSnapshot?
    @ObservationIgnored let store: MusicEnrichmentStore
    @ObservationIgnored let client: any MusicEnrichmentFetching
    @ObservationIgnored var currentRecord: MusicEnrichmentRecord?
    @ObservationIgnored var currentKey: String?
    @ObservationIgnored private var inputQuery: MusicEnrichmentQuery?
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored var isClosed = false
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var startedProviders = Set<String>()
    @ObservationIgnored private var pendingMotionKinds = Set<String>()
    @ObservationIgnored private var attemptedMotionURLs = Set<String>()
    @ObservationIgnored private var attemptedArtworkURLs = Set<String>()
    @ObservationIgnored private var artworkPending = false
    @ObservationIgnored private var independentTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var albumMotionTaskIdentities: [String: MusicAlbumMotionIdentity] = [:]
    @ObservationIgnored var albumMotionTasks: [String: Task<StoredMotionArtwork?, Error>] = [:]
    @ObservationIgnored private var selectionIDs: [String: UUID] = [:]
    @ObservationIgnored private var selectionTasks: [String: Task<MusicEnrichmentSnapshot, Error>] = [:]

    init(store: MusicEnrichmentStore, client: any MusicEnrichmentFetching = MusicEnrichmentHelperClient()) {
        self.store = store
        self.client = client
    }

    func snapshot(for key: String) -> MusicEnrichmentSnapshot? {
        currentSnapshot?.record.query.key == key ? currentSnapshot : nil
    }

    func resetMotionSelectionTasks(for key: String) {
        selectionTasks[key]?.cancel()
        selectionTasks[key] = nil
        selectionIDs[key] = nil
        if currentKey == key { attemptedMotionURLs.removeAll() }
    }

    func resumeMotionAssetsAfterEdit(for key: String) {
        if currentKey == key { startAssets(generation: generation) }
    }

    /// Re-resolves the playing song's album artwork after an album edit and
    /// lets the automatic pass try again when the album was handed back to it.
    func refreshCurrentMotion() async {
        guard let record = currentRecord, record.manualMotionSelection == nil else { return }
        attemptedMotionURLs.removeAll()
        let generation = generation
        await publish(generation: generation)
        startAssets(generation: generation)
    }

    func searchMotionCandidates(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult] {
        guard !isClosed else { throw CancellationError() }
        let client = client
        let candidates = try await trackIndependent(Task { try await client.searchMotion(query: query) })
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        return candidates
    }

    /// A library edit is independent of playback. Choosing artwork for another
    /// track never changes the current playback query or its displayed metadata.
    /// With `.album` scope the choice becomes the album's and the song follows it.
    func selectMotion(_ candidate: MusicEnrichmentResult, for query: MusicEnrichmentQuery, scope: MotionArtworkScope = .track) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        guard candidate.motion?.isEmpty == false else {
            throw MusicEnrichmentHelperError.invalidResponse
        }
        if scope == .album, try await setAlbumMotion(candidate, for: query) {
            return try await clearMotion(for: query, resumeAutomatic: true)
        }
        selectionTasks[query.key]?.cancel()
        let id = UUID()
        selectionIDs[query.key] = id
        let operation = Task { try await self.performSelection(candidate, query: query, id: id) }
        selectionTasks[query.key] = operation
        defer {
            if selectionIDs[query.key] == id {
                selectionIDs[query.key] = nil
                selectionTasks[query.key] = nil
                if currentKey == query.key {
                    attemptedMotionURLs.removeAll()
                    startAssets(generation: generation)
                }
            }
        }
        return try await trackIndependent(operation)
    }

    func update(query: MusicEnrichmentQuery?) {
        guard !isClosed else { return }
        if currentKey == query?.key, Self.matches(inputQuery, query) {
            guard inputQuery?.seedAttributes != query?.seedAttributes else { return }
            inputQuery = query
            if var record = currentRecord {
                record.query.seedAttributes = query?.seedAttributes
                record.updatedAt = Date()
                currentRecord = record
                let generation = generation
                launch { await $0.publish(generation: generation) }
            }
            return
        }
        inputQuery = query
        tasks.values.forEach { $0.cancel() }
        generation = UUID()
        revision = 0
        currentKey = query?.key
        currentRecord = nil
        currentSnapshot = nil
        startedProviders.removeAll()
        pendingMotionKinds.removeAll()
        attemptedMotionURLs.removeAll()
        attemptedArtworkURLs.removeAll()
        artworkPending = false
        onChange?()
        guard let query else { return }
        let generation = generation
        launch { service in
            let loaded = try? await service.store.load(key: query.key)
            guard service.isCurrent(generation) else { return }
            let input = service.inputQuery ?? query
            let matchingRecord = loaded.map { $0.version >= 2 && Self.matches($0.query, input) } ?? true
            var record = matchingRecord ? (loaded ?? MusicEnrichmentRecord(query: input)) : MusicEnrichmentRecord(query: input)
            if !matchingRecord, let loaded {
                if input.storedMotionArtwork?.isUserSelected != true { record.query.storedMotionArtwork = nil }
                // A metadata correction invalidates automatic identities and
                // downloads, while an explicit artwork decision remains valid.
                record.manualAttributes = loaded.manualAttributes
                record.manualMotionSelection = loaded.manualMotionSelection
                if let selection = loaded.manualMotionSelection {
                    record.assets = loaded.assets.filter { asset in
                        selection.motion?.contains { $0.kind == asset.kind && $0.url == asset.sourceURL } == true
                    }
                }
                try? await service.store.removeArtwork(key: query.key)
                guard service.isCurrent(generation) else { return }
            }
            record.query.title = input.title
            record.query.artist = input.artist
            record.query.album = input.album
            record.query.duration = input.duration
            record.query.albumArtist = input.albumArtist
            record.query.appleSongID = input.appleSongID
            record.query.appleAlbumID = input.appleAlbumID
            record.query.storefront = input.storefront
            record.query.isrc = input.isrc
            record.query.seedAttributes = service.inputQuery?.seedAttributes
            if matchingRecord || input.storedMotionArtwork?.isUserSelected == true {
                Self.restoreStoredMotion(in: &record, from: input)
            }
            service.currentRecord = record
            await service.publish(generation: generation, persist: record != loaded)
            guard service.isCurrent(generation) else { return }
            // A prior visit may have persisted only the fastest provider. Resume
            // missing sources rather than treating a partial record as complete.
            for provider in ["appleCache", "appleWeb", "musicBrainz"] {
                service.startProvider(provider, generation: generation)
            }
            service.startAMLLIfPossible(generation: generation)
            service.startAssets(generation: generation)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        generation = UUID()
        let pending = Array(tasks.values) + Array(independentTasks.values)
        pending.forEach { $0.cancel() }
        selectionTasks.values.forEach { $0.cancel() }
        let albumTasks = Array(albumMotionTasks.values)
        albumTasks.forEach { $0.cancel() }
        for task in albumTasks { _ = try? await task.value }
        albumMotionTasks.removeAll()
        albumMotionTaskIdentities.removeAll()
        for task in pending { await task.value }
        tasks.removeAll()
        independentTasks.removeAll()
        selectionIDs.removeAll()
        selectionTasks.removeAll()
        currentRecord = nil
        currentSnapshot = nil
        currentKey = nil
        inputQuery = nil
        onChange?()
        onChange = nil
        onSnapshot = nil
        onAlbumMotionChange = nil
        await store.close()
    }

    private nonisolated static func matches(_ lhs: MusicEnrichmentQuery?, _ rhs: MusicEnrichmentQuery?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && abs(lhs.duration - rhs.duration) < 0.01
            && lhs.appleSongID == rhs.appleSongID && lhs.appleAlbumID == rhs.appleAlbumID
            && lhs.isrc == rhs.isrc && lhs.storefront == rhs.storefront
    }

    private func isCurrent(_ candidate: UUID) -> Bool {
        !isClosed && generation == candidate && !Task.isCancelled
    }

    private func launch(_ operation: @escaping @MainActor (MusicEnrichmentService) async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            self.tasks[id] = nil
        }
    }

    func trackIndependent<Value: Sendable>(_ operation: Task<Value, Error>) async throws -> Value {
        let id = UUID()
        independentTasks[id] = Task {
            await withTaskCancellationHandler {
                _ = try? await operation.value
            } onCancel: { operation.cancel() }
        }
        defer { independentTasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    private func selectionIsCurrent(key: String, id: UUID) -> Bool {
        !isClosed && !Task.isCancelled && selectionIDs[key] == id
    }

    private func performSelection(_ candidate: MusicEnrichmentResult, query: MusicEnrichmentQuery, id: UUID) async throws -> MusicEnrichmentSnapshot {
        var record = MusicEnrichmentRecord(query: query)
        guard selectionIsCurrent(key: query.key, id: id) else { throw CancellationError() }
        var kinds = Set<String>()
        let descriptors = (candidate.motion ?? []).filter {
            ["square", "tall"].contains($0.kind) && kinds.insert($0.kind).inserted
        }
        guard !descriptors.isEmpty else { throw MusicEnrichmentHelperError.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("music-enrichment-selection-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = client
        var saved = false
        try await withThrowingTaskGroup(of: (MotionArtworkDescriptor, MusicEnrichmentHelperClient.MaterializedMotion)?.self) { group in
            for descriptor in descriptors {
                group.addTask {
                    do {
                        let asset = try await client.materialize(descriptor, destination: directory.appendingPathComponent("\(descriptor.kind).mp4"))
                        return (descriptor, asset)
                    } catch { return nil }
                }
            }
            for try await completed in group {
                guard selectionIsCurrent(key: query.key, id: id) else { throw CancellationError() }
                guard let (descriptor, materialized) = completed,
                      let asset = try await store.importMotion(
                        from: URL(fileURLWithPath: materialized.path), descriptor: descriptor,
                        startTime: materialized.startTime, duration: materialized.duration,
                        queryKey: query.key
                      ) else { continue }
                guard selectionIsCurrent(key: query.key, id: id) else { throw CancellationError() }
                let isFirstAsset = !saved
                record = try await store.updateRecord(key: query.key, fallbackQuery: query, alignQuery: true) { record in
                    try Task.checkCancellation()
                    if isFirstAsset {
                        record.assets.removeAll { old in
                            candidate.motion?.contains { $0.kind == old.kind && $0.url == old.sourceURL } != true
                        }
                    }
                    record.manualMotionSelection = candidate
                    record.assets.removeAll { $0.kind == descriptor.kind }
                    record.assets.append(asset)
                }
                guard selectionIsCurrent(key: query.key, id: id) else { throw CancellationError() }
                if currentKey == query.key { currentRecord = record }
                saved = true
                if currentKey == query.key { await publish(generation: generation, persist: false) }
            }
        }
        guard saved, selectionIsCurrent(key: query.key, id: id) else {
            if Task.isCancelled || isClosed { throw CancellationError() }
            throw MusicEnrichmentHelperError.invalidResponse
        }
        let snapshot = await store.snapshot(record)
        guard selectionIsCurrent(key: query.key, id: id) else { throw CancellationError() }
        if currentKey != query.key { onSnapshot?(snapshot) }
        return snapshot
    }

    private func allowsAutomaticMotion(_ descriptor: MotionArtworkDescriptor, generation: UUID) -> Bool {
        guard isCurrent(generation), let record = currentRecord,
              selectionIDs[record.query.key] == nil else { return false }
        guard let selection = record.manualMotionSelection else { return AppSettings.isMotionArtworkFetchEnabled }
        return selection.motion?.contains(where: { $0.kind == descriptor.kind && $0.url == descriptor.url }) == true
    }

    nonisolated static func restoreStoredMotion(in record: inout MusicEnrichmentRecord, from query: MusicEnrichmentQuery) {
        guard let stored = query.storedMotionArtwork ?? record.query.storedMotionArtwork else { return }
        record.query.storedMotionArtwork = stored
        if record.assets.isEmpty { record.assets = stored.assets }
        if stored.isUserSelected, record.manualMotionSelection == nil {
            record.manualMotionSelection = MusicEnrichmentResult(
                source: "manual", albumID: stored.catalogAlbumID,
                motion: stored.assets.map {
                    MotionArtworkDescriptor(kind: $0.kind, url: $0.sourceURL, width: $0.width, height: $0.height)
                }
            )
        }
    }

    private func startProvider(_ provider: String, generation: UUID) {
        guard isCurrent(generation), var query = currentRecord?.query,
              currentRecord?.results.contains(where: { $0.source == provider }) != true,
              startedProviders.insert(provider).inserted else { return }
        if provider == "amllDB" { query.appleSongID = currentRecord?.resolvedAppleSongID }
        Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=attempt title=\(query.title) artist=\(query.artist) album=\(query.album) catalogID=\(query.appleSongID ?? "none")", category: .playback)
        launch { service in
            do {
                let response = try await service.client.fetch(provider: provider, query: query)
                guard service.isCurrent(generation) else { return }
                guard let result = response, Self.hasContent(result) else {
                    Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=empty", category: .playback)
                    return
                }
                Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=result songID=\(result.songID ?? "none") match=\(result.matchKind ?? "unknown") confidence=\(result.confidence ?? 0) fields=\((result.attributes ?? [:]).keys.sorted().joined(separator: ",")) lyrics=\(result.lyricsTTML?.isEmpty == false)", category: .playback)
                service.currentRecord?.merge(result)
                // Start dependent work before awaiting disk I/O; independent
                // providers can continue publishing while media is in flight.
                service.startAMLLIfPossible(generation: generation)
                await service.publish(generation: generation)
                guard service.isCurrent(generation) else { return }
                service.startAssets(generation: generation)
            } catch {
                Log.info("[MusicEnrichment] key=\(query.key) provider=\(provider) event=failed errorType=\(String(describing: type(of: error)))", category: .playback)
                // A failed source leaves all successful snapshots intact. A
                // later visit can retry it because no success was persisted.
            }
        }
    }

    private func startAMLLIfPossible(generation: UUID) {
        guard currentRecord?.resolvedAppleSongID?.isEmpty == false else { return }
        startProvider("amllDB", generation: generation)
    }

    func publish(generation: UUID, persist: Bool = true) async {
        guard isCurrent(generation), let record = currentRecord else { return }
        revision += 1
        let expectedRevision = revision
        if persist { try? await store.save(record) }
        guard isCurrent(generation) else { return }
        let snapshot = await store.snapshot(record)
        guard isCurrent(generation), revision == expectedRevision else { return }
        Log.info("[MusicEnrichment] key=\(record.query.key) event=published sources=\(record.attributeSources.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) lyrics=\(record.lyricsSource ?? "none")", category: .playback)
        currentRecord = snapshot.record
        currentSnapshot = snapshot
        onSnapshot?(snapshot)
        onChange?()
    }

    private func startAssets(generation: UUID) {
        guard isCurrent(generation), let record = currentRecord else { return }
        for descriptor in record.motionDescriptors where ["square", "tall"].contains(descriptor.kind) {
            let existing = descriptor.kind == "square" ? currentSnapshot?.squareArtwork : currentSnapshot?.tallArtwork
            guard allowsAutomaticMotion(descriptor, generation: generation),
                  existing == nil, !pendingMotionKinds.contains(descriptor.kind),
                  attemptedMotionURLs.insert(descriptor.url).inserted else { continue }
            pendingMotionKinds.insert(descriptor.kind)
            launch { service in
                defer {
                    if service.isCurrent(generation) {
                        service.pendingMotionKinds.remove(descriptor.kind)
                        service.startAssets(generation: generation)
                    }
                }
                do {
                    if let asset = try await service.automaticMotion(descriptor, for: record) {
                        guard service.allowsAutomaticMotion(descriptor, generation: generation) else { return }
                        service.currentRecord?.assets.removeAll { $0.kind == descriptor.kind }
                        service.currentRecord?.assets.append(asset)
                        service.currentRecord?.updatedAt = Date()
                        await service.publish(generation: generation)
                    }
                } catch { /* Another descriptor can still provide this shape. */ }
            }
        }
        guard currentSnapshot?.artworkData == nil, !artworkPending,
              let url = Self.artworkURL(record.attributes),
              attemptedArtworkURLs.insert(url.absoluteString).inserted else { return }
        artworkPending = true
        launch { service in
            do {
                let data = try await service.client.artworkData(from: url)
                guard service.isCurrent(generation) else { return }
                try await service.store.importArtwork(data, key: record.query.key)
                guard service.isCurrent(generation) else { return }
                service.currentRecord?.updatedAt = Date()
                await service.publish(generation: generation)
            } catch { /* Keep metadata and motion when a still image fails. */ }
            guard service.isCurrent(generation) else { return }
            service.artworkPending = false
            service.startAssets(generation: generation)
        }
    }

    nonisolated static func artworkURL(_ attributes: [String: MusicMetadataValue]) -> URL? {
        for field in ["artwork", "albumArtwork"] {
            guard let template = attributes[field]?.dictionary?["url"]?.text else { continue }
            let address = template.replacingOccurrences(of: "{w}", with: "1200")
                .replacingOccurrences(of: "{h}", with: "1200")
                .replacingOccurrences(of: "{f}", with: "jpg")
                .replacingOccurrences(of: "{c}", with: "bb")
            if let url = URL(string: address), url.scheme == "https" { return url }
        }
        return nil
    }

    private nonisolated static func hasContent(_ result: MusicEnrichmentResult) -> Bool {
        !result.source.isEmpty && (
            result.attributes?.isEmpty == false || result.resources?.isEmpty == false ||
            result.lyricsTTML?.isEmpty == false || result.motion?.isEmpty == false || result.songID?.isEmpty == false
        )
    }
}
