import Foundation

// The standalone executable does not link the App's logging infrastructure.
// Keep the service's actual categories and call signature visible to swiftc.
nonisolated enum LogCategory { case playback, library }
nonisolated enum Log {
    static func info(_ message: String, category: LogCategory) {}
    static func warning(_ message: String, category: LogCategory) {}
}

private enum StubFailure: Error { case unavailable }

private actor StubEnrichmentClient: MusicEnrichmentFetching {
    var responses: [String: MusicEnrichmentResult] = [:]
    var waiting = Set<String>()
    var calls: [String: Int] = [:]
    var mediaWaiting = false
    var materializeCount = 0
    var artworkCount = 0
    var failing = Set<String>()
    var late = Set<String>()
    var motionCandidates: [MusicEnrichmentResult] = []
    var blockedMotionURLs = Set<String>()
    var completedMotionURLs = Set<String>()
    var failedMotionURLs = Set<String>()
    var finishedProviders = Set<String>()

    func configure(_ responses: [String: MusicEnrichmentResult], waiting: Set<String> = [], mediaWaiting: Bool = false, failing: Set<String> = [], late: Set<String> = []) {
        self.responses = responses
        self.waiting = waiting
        self.mediaWaiting = mediaWaiting
        self.failing = failing
        self.late = late
    }

    func release(_ provider: String) { waiting.remove(provider) }
    func releaseMedia() { mediaWaiting = false }
    func blockMotion(_ url: String) { blockedMotionURLs.insert(url) }
    func releaseMotion(_ url: String) { blockedMotionURLs.remove(url) }
    func completedMotion(_ url: String) -> Bool { completedMotionURLs.contains(url) }
    func setCandidates(_ values: [MusicEnrichmentResult]) { motionCandidates = values }
    func failMotion(_ url: String) { failedMotionURLs.insert(url) }
    func finished(_ provider: String) -> Bool { finishedProviders.contains(provider) }
    func count(_ provider: String) -> Int { calls[provider, default: 0] }
    func totalCalls() -> Int { calls.values.reduce(0, +) }
    func mediaCounts() -> (Int, Int) { (materializeCount, artworkCount) }

    func searchMotion(query: MusicEnrichmentQuery) async throws -> [MusicEnrichmentResult] {
        calls["motionSearch", default: 0] += 1
        return motionCandidates
    }

    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult? {
        calls[provider, default: 0] += 1
        defer { finishedProviders.insert(provider) }
        if late.contains(provider) {
            // Deliberately emulate a backend that returns after cancellation.
            await withCheckedContinuation { continuation in
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(80))
                    continuation.resume()
                }
            }
            return responses[provider]
        }
        while waiting.contains(provider) { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if failing.contains(provider) { throw StubFailure.unavailable }
        return responses[provider]
    }

    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MusicEnrichmentHelperClient.MaterializedMotion {
        materializeCount += 1
        while mediaWaiting || blockedMotionURLs.contains(descriptor.url) { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if failedMotionURLs.contains(descriptor.url) { throw StubFailure.unavailable }
        try Data("standalone-test-video:\(descriptor.url)".utf8).write(to: destination)
        completedMotionURLs.insert(descriptor.url)
        return .init(path: destination.path, startTime: 0.4, duration: 7.5)
    }

    func artworkData(from url: URL) async throws -> Data {
        artworkCount += 1
        while mediaWaiting { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        return Data("standalone-test-image".utf8)
    }
}

@main
@MainActor
struct MusicEnrichmentCoreTests {
    static func main() async throws {
        try await diskRoundTripAndFillOnly()
        try await publishesFastProviderAndStartsDependentLyrics()
        try await metadataDoesNotWaitForMedia()
        try await diskHitResumesOnlyMissingSources()
        try await changedTrackAndCloseCancelOldWork()
        try await manualSelectionForAnotherTrackPersists()
        try await automaticArrivalCannotReplaceManualSelection()
        try await trackReferenceRestoresMissingEnrichmentRecord()
        try await manualSelectionDropsOtherAlbumShapes()
        try await albumChoiceIsSharedByEverySong()
        try await metadataCorrectionInvalidatesAutomaticMatches()
        try motionImportDurationBoundaries()
        try await nonVideoImportAndCancellationLeaveNoRecords()
        print("MusicEnrichmentCoreTests passed (13 cases)")
    }

    private static func query(_ key: String = "track-1") -> MusicEnrichmentQuery {
        .init(key: key, title: "Song", artist: "Artist", album: "Album", duration: 180)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("music-enrichment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "MusicEnrichmentCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func eventually(_ message: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            try expect(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func diskRoundTripAndFillOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let enrichmentRoot = root.appendingPathComponent("Enrichment", isDirectory: true)
        let store = MusicEnrichmentStore(rootURL: enrichmentRoot)
        let trackID = UUID()
        var seeded = query("track:\(trackID.uuidString)")
        seeded.seedAttributes = ["composerName": .string("Music.app Composer")]
        var record = MusicEnrichmentRecord(query: seeded)
        record.merge(.init(source: "appleCache", songID: "123", attributes: ["recordLabel": .string("First Label"), "composerName": .string("Catalog Composer")], resources: ["song": .object(["id": .string("123")])], lyricsTTML: "<tt><span>Words</span></tt>"))
        record.merge(.init(source: "musicBrainz", attributes: ["recordLabel": .string("Late Label"), "producer": .string("Producer")]))
        try expect(record.attributes["recordLabel"]?.text == "First Label", "A later provider must only fill missing fields")
        try expect(record.attributes["composerName"]?.text == "Music.app Composer", "Music.app seed fields must keep their authority")
        try expect(record.attributes["producer"]?.text == "Producer", "A later provider must fill absent fields")
        let image = Data("image".utf8)
        try await store.importArtwork(image, key: record.query.key)
        let temporaryVideo = root.appendingPathComponent("temporary.mp4")
        let videoBytes = Data("video".utf8)
        try videoBytes.write(to: temporaryVideo)
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "https://example.com/artwork.m3u8", width: 1080, height: 1080)
        let imported = try await store.importMotion(from: temporaryVideo, descriptor: descriptor, startTime: 1.2, duration: 8, queryKey: seeded.key)
        try expect(imported != nil, "Video import must produce a stored asset")
        try expect(imported?.relativePath.hasPrefix("Tracks/\(trackID.uuidString)/") == true, "Local-track motion must live inside that track's library directory")
        record.assets = [imported!]
        try await store.save(record)
        await store.close()
        try FileManager.default.removeItem(at: temporaryVideo)
        let reopened = MusicEnrichmentStore(rootURL: enrichmentRoot)
        let restored = try await reopened.load(key: record.query.key)
        try expect(restored?.results == record.results, "Every provider snapshot, raw resource and lyric must survive reopening")
        let snapshot = await reopened.snapshot(restored!)
        try expect(snapshot.artworkData == image, "Still artwork must survive reopening")
        try expect(snapshot.squareArtwork?.startTime == 1.2 && snapshot.squareArtwork?.duration == 8, "Video timing must survive reopening")
        let persistedVideo = try Data(contentsOf: snapshot.squareArtwork!.url)
        try expect(persistedVideo == videoBytes, "Video must be a library-owned file, independent of the temporary source")
        await reopened.close()
    }

    private static func publishesFastProviderAndStartsDependentLyrics() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StubEnrichmentClient()
        await client.configure([
            "appleCache": .init(source: "appleCache", songID: "123", attributes: ["recordLabel": .string("Cache Label")]),
            "appleWeb": .init(source: "appleWeb", songID: "123", attributes: ["recordLabel": .string("Web Label"), "copyright": .string("Copyright")]),
            "amllDB": .init(source: "amllDB", lyricsTTML: "<tt>Synced words</tt>"),
        ], waiting: ["appleWeb", "musicBrainz"], failing: ["musicBrainz"])
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: client)
        var publications = 0
        service.onChange = { publications += 1 }
        service.update(query: query())
        try await eventually("Cache metadata and dependent AMLL lyrics should publish without waiting for slow providers") {
            service.snapshot(for: "track-1")?.lyricsTTML != nil
        }
        try expect(service.snapshot(for: "track-1")?.attributes["recordLabel"]?.text == "Cache Label", "The fast cache result must be visible immediately")
        try expect(await client.count("amllDB") == 1, "The discovered Apple ID must trigger AMLL exactly once")
        let before = await client.totalCalls()
        service.update(query: query())
        try expect(await client.totalCalls() == before, "Updating the same track must not start duplicate requests")
        await client.release("appleWeb")
        try await eventually("Late metadata should fill missing fields") {
            service.snapshot(for: "track-1")?.attributes["copyright"] != nil
        }
        try expect(service.snapshot(for: "track-1")?.attributes["recordLabel"]?.text == "Cache Label", "Late metadata must not replace the first visible value")
        await client.release("musicBrainz")
        try await eventually("A failing source must complete independently") { await client.finished("musicBrainz") }
        try expect(service.snapshot(for: "track-1")?.lyricsTTML != nil, "A failed provider must preserve successful lyrics and metadata")
        try expect(publications >= 3, "Independent arrivals must publish incrementally")
        await service.close()
    }

    private static func metadataDoesNotWaitForMedia() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StubEnrichmentClient()
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "https://example.com/motion.m3u8")
        await client.configure([
            "appleWeb": .init(source: "appleWeb", attributes: ["recordLabel": .string("Label"), "artwork": .object(["url": .string("https://example.com/{w}x{h}.{f}")])], motion: [descriptor]),
        ], mediaWaiting: true)
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: client)
        service.update(query: query())
        try await eventually("Metadata must publish before media downloads finish") { service.snapshot(for: "track-1")?.attributes["recordLabel"] != nil }
        try expect(service.snapshot(for: "track-1")?.squareArtwork == nil, "A pending video must not be advertised as available")
        try await eventually("Media work should start independently") {
            let counts = await client.mediaCounts()
            return counts.0 == 1 && counts.1 == 1
        }
        await client.releaseMedia()
        try await eventually("Materialized media must publish after import") {
            let snapshot = service.snapshot(for: "track-1")
            return snapshot?.squareArtwork != nil && snapshot?.artworkData != nil
        }
        let counts = await client.mediaCounts()
        try expect(counts.0 == 1 && counts.1 == 1, "Completed media must not download repeatedly")
        await service.close()
        let reopened = MusicEnrichmentStore(rootURL: root)
        let record = try await reopened.load(key: "track-1")
        let snapshot = await reopened.snapshot(record!)
        try expect(snapshot.squareArtwork != nil && snapshot.artworkData != nil, "Downloaded media must remain available after closing the service")
        await reopened.close()
    }

    private static func diskHitResumesOnlyMissingSources() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root)
        var cached = MusicEnrichmentRecord(query: query())
        cached.merge(.init(source: "appleCache", songID: "123", attributes: ["recordLabel": .string("Saved Label")]))
        cached.merge(.init(source: "amllDB", lyricsTTML: "<tt>Saved lyrics</tt>"))
        try await store.save(cached)
        let client = StubEnrichmentClient()
        await client.configure(["appleWeb": .init(source: "appleWeb", attributes: ["copyright": .string("Late")])], waiting: ["appleWeb"])
        let service = MusicEnrichmentService(store: store, client: client)
        service.update(query: query())
        try await eventually("Saved metadata must be shown while missing sources are pending") { service.snapshot(for: "track-1")?.lyricsTTML != nil }
        try await eventually("A partial disk record must resume its missing providers") { await client.count("appleWeb") == 1 }
        let cacheCalls = await client.count("appleCache")
        let lyricsCalls = await client.count("amllDB")
        try expect(cacheCalls == 0 && lyricsCalls == 0, "Successful stored sources must not be requested again")
        await client.release("appleWeb")
        try await eventually("A resumed provider must complete the stored record") { service.snapshot(for: "track-1")?.attributes["copyright"] != nil }
        await service.close()
    }

    private static func changedTrackAndCloseCancelOldWork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root)
        let client = StubEnrichmentClient()
        await client.configure(["appleCache": .init(source: "appleCache", attributes: ["recordLabel": .string("Must not arrive")])], waiting: ["appleWeb", "musicBrainz"], late: ["appleCache"])
        let service = MusicEnrichmentService(store: store, client: client)
        service.update(query: query("old"))
        try await eventually("Old requests must have started") { await client.totalCalls() == 3 }
        service.update(query: query("new"))
        try expect(service.snapshot(for: "old") == nil, "A track change must immediately hide the old snapshot")
        try await eventually("The new track must have started independently") { await client.totalCalls() == 6 }
        await service.close()
        await client.release("appleCache")
        try expect(service.snapshot(for: "old") == nil && service.snapshot(for: "new") == nil, "Closed libraries must publish no snapshot")
        let reopened = MusicEnrichmentStore(rootURL: root)
        let old = try await reopened.load(key: "old")
        let new = try await reopened.load(key: "new")
        try expect(old?.results.isEmpty != false && new?.results.isEmpty != false, "Cancelled requests must not persist late provider data")
        await reopened.close()
    }

    private static func manualSelectionForAnotherTrackPersists() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StubEnrichmentClient()
        let candidate = MusicEnrichmentResult(
            source: "appleWeb", songID: "different-catalog-id",
            attributes: ["name": .string("A different album")],
            motion: [.init(kind: "square", url: "https://example.com/chosen.m3u8")]
        )
        await client.setCandidates([candidate])
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: client)
        var snapshots: [String] = []
        service.onSnapshot = { snapshots.append($0.record.query.key) }
        service.update(query: query("playing"))
        try await eventually("The current track must have a snapshot before editing another track") { service.snapshot(for: "playing") != nil }
        let search = try await service.searchMotionCandidates(query: query("edited"))
        try expect(search == [candidate], "Manual search must return provider candidates")
        let chosen = try await service.selectMotion(candidate, for: query("edited"))
        try expect(chosen.squareArtwork != nil && chosen.record.manualMotionSelection == candidate, "Manual selection must import media before it becomes available")
        try expect(chosen.record.query.appleSongID == nil && chosen.attributes["name"] == nil, "Artwork selection must not change the song identity or metadata")
        try expect(service.snapshot(for: "playing") != nil && service.snapshot(for: "edited") == nil, "Editing another track must preserve the current playback snapshot")
        try expect(snapshots.contains("edited"), "An edited noncurrent track must emit a snapshot for Track persistence")
        let failingURL = "https://example.com/unavailable.m3u8"
        await client.failMotion(failingURL)
        do {
            _ = try await service.selectMotion(.init(source: "appleWeb", motion: [.init(kind: "square", url: failingURL)]), for: query("edited"))
            try expect(false, "A selection with no downloadable media must fail")
        } catch MusicEnrichmentHelperError.invalidResponse { }
        await service.close()
        let reopened = MusicEnrichmentStore(rootURL: root)
        let record = try await reopened.load(key: "edited")
        try expect(record?.manualMotionSelection == candidate, "Manual selection must survive closing and reopening the library")
        let restored = await reopened.snapshot(record!)
        try expect(restored.squareArtwork != nil, "The manually downloaded file must remain available after reopening")
        await reopened.close()
    }

    private static func automaticArrivalCannotReplaceManualSelection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StubEnrichmentClient()
        let automaticURL = "https://example.com/automatic.m3u8"
        let chosenURL = "https://example.com/manual.m3u8"
        await client.configure([
            "appleCache": .init(source: "appleCache", attributes: ["recordLabel": .string("Keep metadata")], motion: [.init(kind: "square", url: automaticURL)]),
        ])
        await client.blockMotion(automaticURL)
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: client)
        service.update(query: query())
        try await eventually("Automatic artwork download must be in flight") { await client.mediaCounts().0 == 1 }
        let candidate = MusicEnrichmentResult(source: "appleWeb", motion: [.init(kind: "square", url: chosenURL)])
        let selected = try await service.selectMotion(candidate, for: query())
        try expect(selected.record.assets.first?.sourceURL == chosenURL, "The explicit selection must be stored")
        await client.releaseMotion(automaticURL)
        try await eventually("The older automatic download must finish after the manual choice") { await client.completedMotion(automaticURL) }
        try await Task.sleep(for: .milliseconds(30))
        try expect(service.snapshot(for: "track-1")?.record.assets.first?.sourceURL == chosenURL, "A late automatic download must not replace the manual selection")
        try expect(service.snapshot(for: "track-1")?.attributes["recordLabel"]?.text == "Keep metadata", "Manual motion must leave provider metadata intact")
        await service.close()
        let reopened = MusicEnrichmentStore(rootURL: root)
        let record = try await reopened.load(key: "track-1")
        try expect(record?.assets.first?.sourceURL == chosenURL && record?.manualMotionSelection == candidate, "Manual priority must survive reopening")
        await reopened.close()
    }

    private static func trackReferenceRestoresMissingEnrichmentRecord() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let enrichmentRoot = root.appendingPathComponent("Enrichment", isDirectory: true)
        let trackID = UUID()
        let trackKey = "track:\(trackID.uuidString)"
        let store = MusicEnrichmentStore(rootURL: enrichmentRoot)
        let video = root.appendingPathComponent("original.mp4")
        try Data("retained-track-video".utf8).write(to: video)
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "https://example.com/retained.m3u8")
        let asset = try await store.importMotion(from: video, descriptor: descriptor, startTime: 0, duration: 8, queryKey: trackKey)
        var original = MusicEnrichmentRecord(query: query(trackKey))
        original.assets = [asset!]
        original.manualMotionSelection = .init(source: "appleWeb", albumID: "chosen-album", motion: [descriptor])
        let storedReference = TrackMotionArtwork(snapshot: await store.snapshot(original))
        // Deliberately never save an enrichment record: only the Track reference
        // and the library-owned media file survive an import/export operation.
        var restoredQuery = query(trackKey)
        restoredQuery.storedMotionArtwork = storedReference
        let client = StubEnrichmentClient()
        await client.configure([
            "appleWeb": .init(source: "appleWeb", attributes: ["recordLabel": .string("Other metadata")], motion: [.init(kind: "square", url: "https://example.com/automatic-other.m3u8")]),
        ])
        let service = MusicEnrichmentService(store: store, client: client)
        service.update(query: restoredQuery)
        try await eventually("A Track reference must restore artwork when the enrichment record is absent") {
            service.snapshot(for: trackKey)?.squareArtwork != nil
        }
        try await eventually("Metadata must still enrich the track independently") { service.snapshot(for: trackKey)?.attributes["recordLabel"] != nil }
        let snapshot = service.snapshot(for: trackKey)!
        try expect(snapshot.record.manualMotionSelection?.source == "manual" && snapshot.record.manualMotionSelection?.albumID == "chosen-album", "Restored Track references must retain manual priority and the selected album")
        let counts = await client.mediaCounts()
        try expect(counts.0 == 0, "An existing Track video must not be downloaded again")
        await service.close()
        let reopened = MusicEnrichmentStore(rootURL: enrichmentRoot)
        let persisted = try await reopened.load(key: trackKey)
        try expect(persisted?.manualMotionSelection?.albumID == "chosen-album" && persisted?.assets == original.assets, "The reconstructed reference must become a persistent enrichment record")
        await reopened.close()
    }
    private static func manualSelectionDropsOtherAlbumShapes() async throws {
        for failedTall in [false, true] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = MusicEnrichmentStore(rootURL: root)
            var old = MusicEnrichmentRecord(query: query())
            let video = root.appendingPathComponent("old.mp4")
            try Data("old".utf8).write(to: video)
            for kind in ["square", "tall"] {
                let asset = try await store.importMotion(from: video, descriptor: .init(kind: kind, url: "https://example.com/old-\(kind)"), startTime: 0, duration: 8)
                old.assets.append(asset!)
            }
            try await store.save(old)
            let client = StubEnrichmentClient()
            let tallURL = "https://example.com/new-tall"
            await client.failMotion(tallURL)
            var motion = [MotionArtworkDescriptor(kind: "square", url: "https://example.com/new-square")]
            if failedTall { motion.append(.init(kind: "tall", url: tallURL)) }
            let service = MusicEnrichmentService(store: store, client: client)
            let chosen = try await service.selectMotion(.init(source: "appleWeb", motion: motion), for: query())
            try expect(chosen.squareArtwork != nil && chosen.tallArtwork == nil, "A new choice must never retain the previous album's tall artwork")
            try expect(chosen.record.assets.count == 1 && chosen.record.assets[0].sourceURL == motion[0].url, "Only assets belonging to the new selection may remain")
            let persisted = try await store.load(key: "track-1")
            try expect(persisted?.assets == chosen.record.assets, "The filtered selection must be persisted")
            await service.close()
        }
    }

    private static func albumChoiceIsSharedByEverySong() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root)
        let client = StubEnrichmentClient()
        let service = MusicEnrichmentService(store: store, client: client)
        var announced: [TrackMotionArtwork?] = []
        service.onAlbumMotionChange = { _, artwork in announced.append(artwork) }

        let own = MotionArtworkDescriptor(kind: "square", url: "https://example.com/own")
        _ = try await service.selectMotion(.init(source: "appleWeb", motion: [own]), for: query("track-3"))
        let shared = MotionArtworkDescriptor(kind: "square", url: "https://example.com/album")
        let chosen = try await service.selectMotion(.init(source: "appleWeb", motion: [shared]), for: query("track-1"), scope: .album)
        try expect(chosen.squareArtwork != nil && chosen.record.manualMotionSelection == nil, "An album choice must leave the song following its album")
        let sibling = try await service.loadSnapshot(for: query("track-2"))
        try expect(sibling?.squareArtwork != nil && sibling?.record.assets.first?.sourceURL == shared.url, "Every song of the album must show the album's choice")
        let other = try await service.loadSnapshot(for: query("track-3"))
        try expect(other?.record.assets.first?.sourceURL == own.url, "A song's own choice must take precedence over the album")
        try expect(announced.last??.assets.first?.sourceURL == shared.url, "Album changes must reach local siblings")
        var featured = query("track-4")
        featured.artist = "Artist, Guest"
        let guest = try await service.loadSnapshot(for: featured)
        try expect(guest?.record.assets.first?.sourceURL == shared.url, "A song with a featured artist must share its album's artwork")

        await client.configure(["appleWeb": .init(source: "appleWeb", motion: [.init(kind: "square", url: "https://example.com/automatic")])])
        _ = try await service.completeIndependently(query: query("track-2"))
        let afterAutomatic = try await service.loadSnapshot(for: query("track-2"))
        try expect(afterAutomatic?.record.assets.first?.sourceURL == shared.url, "The automatic pass must never replace an explicit album choice")

        try await service.clearAlbumMotion(for: query("track-2"), resumeAutomatic: false)
        let cleared = try await service.loadSnapshot(for: query("track-1"))
        try expect(cleared?.squareArtwork == nil, "Removing the album's artwork must apply to every song following it")
        try expect(announced.last == .some(nil), "Removal must reach local siblings")
        await service.close()
    }

    private static func metadataCorrectionInvalidatesAutomaticMatches() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root)
        var old = MusicEnrichmentRecord(query: query())
        old.merge(.init(source: "appleCache", songID: "old-song", albumID: "old-album", storefront: "old-region", attributes: ["recordLabel": .string("Wrong label")]))
        old.merge(.init(source: "amllDB", lyricsTTML: "<tt>Wrong lyrics</tt>"))
        let video = root.appendingPathComponent("manual.mp4")
        try Data("manual".utf8).write(to: video)
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "https://example.com/manual")
        old.assets = [try await store.importMotion(from: video, descriptor: descriptor, startTime: 0, duration: 8)!]
        old.manualMotionSelection = .init(source: "manual", motion: [descriptor])
        try await store.importArtwork(Data("wrong-still".utf8), key: old.query.key)
        try await store.save(old)
        let client = StubEnrichmentClient()
        let service = MusicEnrichmentService(store: store, client: client)
        service.update(query: query())
        try await eventually("Stored provider identity must first load") { service.snapshot(for: "track-1")?.record.resolvedAppleSongID == "old-song" }
        try await eventually("Missing sources must start") { await client.totalCalls() == 2 }
        var jittered = query()
        jittered.duration += 0.004
        service.update(query: jittered)
        try expect(await client.totalCalls() == 2, "Millisecond source-duration jitter must not restart matching")
        var seeded = query()
        seeded.seedAttributes = ["composerName": .string("Edited composer")]
        service.update(query: seeded)
        try await eventually("Seed edits must refresh independently") { service.snapshot(for: "track-1")?.attributes["composerName"]?.text == "Edited composer" }
        try expect(await client.totalCalls() == 2, "Seed edits must not restart provider requests")
        seeded.title = "Corrected song"
        service.update(query: seeded)
        try await eventually("A matching-input correction must start all automatic providers again") { await client.totalCalls() == 5 }
        try await eventually("Corrected snapshot must be published") { service.snapshot(for: "track-1")?.record.query.title == seeded.title }
        let corrected = service.snapshot(for: "track-1")!
        try expect(corrected.record.query.appleSongID == nil && corrected.record.query.appleAlbumID == nil && corrected.record.query.storefront == nil, "Resolved identities must be discarded after a metadata correction")
        try expect(corrected.record.results.isEmpty && corrected.lyricsTTML == nil && corrected.artworkData == nil, "Wrong provider data, lyrics and still artwork must be discarded")
        try expect(corrected.squareArtwork != nil && corrected.record.manualMotionSelection != nil, "Explicitly chosen media must survive metadata correction")
        service.update(query: seeded)
        try expect(await client.totalCalls() == 5, "Repeated original input must not restart after resolved IDs change")
        await service.close()
        // A correction made while closed must also invalidate the loaded record.
        let reopenedStore = MusicEnrichmentStore(rootURL: root)
        var stale = corrected.record
        stale.merge(.init(source: "appleCache", songID: "stale-again", attributes: ["recordLabel": .string("Stale")]))
        try await reopenedStore.save(stale)
        let reopenedClient = StubEnrichmentClient()
        let reopened = MusicEnrichmentService(store: reopenedStore, client: reopenedClient)
        seeded.artist = "Corrected artist"
        reopened.update(query: seeded)
        try await eventually("Disk query mismatch must invalidate old success markers") { await reopenedClient.totalCalls() == 3 }
        let restored = reopened.snapshot(for: "track-1")!
        try expect(restored.record.query.artist == seeded.artist && restored.record.query.appleSongID == nil && restored.record.results.isEmpty, "Reopening must use current matching input rather than stale disk identity")
        try expect(restored.squareArtwork != nil, "Reopening with corrected metadata must preserve manual media")
        await reopened.close()
    }

    private static func motionImportDurationBoundaries() throws {
        try ValidatedMotionVideo.validateDuration(1_200)
        try ValidatedMotionVideo.validateDuration(0.001)
        for duration in [1_200.001, 0, -1, Double.nan, Double.infinity] {
            var rejected = false
            do { try ValidatedMotionVideo.validateDuration(duration) }
            catch let error as MotionVideoImportError {
                rejected = true
                if duration.isFinite, duration > 1_200 {
                    guard case .tooLong = error else {
                        throw NSError(domain: "MusicEnrichmentCoreTests", code: 1)
                    }
                }
            }
            try expect(rejected, "Invalid or over-20-minute durations must be rejected")
        }
    }

    private static func nonVideoImportAndCancellationLeaveNoRecords() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("not-video.mov")
        try Data("This is text rather than a video container".utf8).write(to: input)
        let store = MusicEnrichmentStore(rootURL: root.appendingPathComponent("Enrichment"))
        let service = MusicEnrichmentService(store: store, client: StubEnrichmentClient())
        var rejected = false
        do { _ = try await service.importMotionVideo(from: input, for: query("invalid-video")) }
        catch is MotionVideoImportError { rejected = true }
        try expect(rejected, "A movie extension cannot turn a non-video file into an importable video")
        let missing = try await store.load(key: "invalid-video")
        try expect(missing == nil, "Rejected video must not create an enrichment record")

        let cancelled = Task { @MainActor in
            try await service.importMotionVideo(from: input, for: query("cancelled-video"))
        }
        // This MainActor test does not yield between creation and cancellation.
        cancelled.cancel()
        var observedCancellation = false
        do { _ = try await cancelled.value }
        catch is CancellationError { observedCancellation = true }
        try expect(observedCancellation, "An import cancelled before execution must stop before validation or writes")
        let cancelledRecord = try await store.load(key: "cancelled-video")
        try expect(cancelledRecord == nil, "Cancelled import must not persist a record")
        let records = try await store.listRecords(offset: 0, limit: 20)
        try expect(records.records.isEmpty, "Rejected and cancelled imports must leave the library empty")
        await service.close()
    }

}
