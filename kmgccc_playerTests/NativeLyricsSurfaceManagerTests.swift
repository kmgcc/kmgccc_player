import XCTest
import MelismaKit
import SwiftUI
import QuartzCore
@testable import kmgccc_player

final class NativeLyricsSurfaceManagerTests: XCTestCase {
    private let mainTTML = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='5s'>Main</p></div></body></tt>"
    private let previewTTML = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='2s' end='8s'>Preview</p></div></body></tt>"
    private let legacyAbsoluteTTML = """
    <tt xmlns='http://www.w3.org/ns/ttml'>
      <body>
        <div begin='1s' end='8s'>
          <p begin='1s' end='4s'>
            <span begin='1s' end='2s'>First</span><span begin='2s' end='4s'> line</span>
          </p>
          <p begin='4s' end='8s'>
            <span begin='4s' end='6s'>Second</span><span begin='6s' end='8s'> line</span>
          </p>
        </div>
      </body>
    </tt>
    """
    private let legacyUnnamespacedTTML = """
    <tt>
      <body>
        <div begin='1s' end='4s'>
          <p begin='1s' end='4s'><span begin='1s' end='4s'>Unnamespaced</span></p>
        </div>
      </body>
    </tt>
    """
    private let strictRelativeNestedTTML = """
    <tt xmlns='http://www.w3.org/ns/ttml'>
      <body>
        <div begin='1s' end='7s'>
          <p begin='0s' end='2s'><span begin='0s' end='1s'>First</span><span begin='1s' end='2s'> line</span></p>
          <p begin='3s' end='6s'><span begin='0s' end='1s'>Second</span><span begin='1s' end='3s'> line</span></p>
        </div>
      </body>
    </tt>
    """

    @MainActor
    func testAMLLTTMLIsPassedToDecoderWithoutTimingRewrite() throws {
        let surface = NativeLyricsSurface(role: .main)
        surface.applyTrack(
            trackID: UUID(),
            ttml: mainTTML,
            currentTime: 1,
            isPlaying: false
        )

        let groups = try XCTUnwrap(surface.view.document?.groups)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(surface.lastTTML, mainTTML)
        XCTAssertEqual(groups[0].main.range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.range.end, 5, accuracy: 0.0001)
    }

    @MainActor
    func testRepeatedForceRefreshDoesNotRestartAnActiveInterludeEntrance() throws {
        let surface = NativeLyricsSurface(role: .main)
        surface.view.configuration.timing.enabled = false
        surface.view.configuration.spring = false
        surface.view.configuration.blur = false
        let data = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='8s' end='10s'>First</p><p begin='15s' end='17s'>Second</p></div></body></tt>"
        let trackID = UUID()
        let start = CACurrentMediaTime()

        surface.applyTrack(
            trackID: trackID,
            ttml: data,
            currentTime: 0,
            isPlaying: true
        )
        let progressed = try XCTUnwrap(surface.view.render(at: start + 2).interlude)

        // The fullscreen/presentation pipeline can issue a forced refresh with
        // the same valid TTML but a stale time sample. It must rebase playback
        // without replaying the already visible scale-in entrance.
        let refreshHost = CACurrentMediaTime()
        surface.applyTrack(
            trackID: trackID,
            ttml: data,
            currentTime: 0.1,
            isPlaying: true,
            forceLyricsReload: true
        )
        let afterRefresh = try XCTUnwrap(surface.view.render(at: refreshHost + 0.02).interlude)
        XCTAssertGreaterThanOrEqual(afterRefresh.opacity, progressed.opacity - 0.001)
        XCTAssertGreaterThanOrEqual(afterRefresh.walk[0], progressed.walk[0] - 0.001)
        XCTAssertGreaterThanOrEqual(afterRefresh.walk[1], progressed.walk[1] - 0.001)
        XCTAssertGreaterThanOrEqual(afterRefresh.walk[2], progressed.walk[2] - 0.001)
    }

    @MainActor
    func testSameTrackReplayRestartsTheNativeEntrySpring() throws {
        let surface = NativeLyricsSurface(role: .main)
        surface.view.frame = NSRect(x: 0, y: 0, width: 760, height: 720)
        surface.view.configuration.timing.enabled = false
        surface.view.configuration.spring = true
        surface.view.configuration.blur = false

        let trackID = UUID()
        let data = "<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='20s'>First</p><p begin='20s' end='40s'>Second</p></div></body></tt>"
        let initialHost = CACurrentMediaTime()
        surface.applyTrack(trackID: trackID, ttml: data, currentTime: 0, isPlaying: true)
        let settled = surface.view.render(at: initialHost + 3)
        let targetY = try XCTUnwrap(settled.groups.first).y

        // Advance the adapter's snapshot without changing the document, then
        // emulate pressing the same track's restart button. The force-refresh
        // path must reinstall the document so the first frame starts below the
        // viewport instead of synchronizing directly at the settled position.
        surface.applyTrack(trackID: trackID, ttml: data, currentTime: 3, isPlaying: true)
        let replayHost = CACurrentMediaTime()
        surface.applyTrack(
            trackID: trackID,
            ttml: data,
            currentTime: 0,
            isPlaying: true,
            forceLyricsReload: true
        )
        let replay = surface.view.render(at: replayHost + 0.02)

        XCTAssertGreaterThan(try XCTUnwrap(replay.groups.first).y, targetY + 0.1)
    }

    func testW3CRelativeProfileRemainsExplicit() throws {
        let document = try TTMLDecoder(profile: .w3cRelative).decode(Data(strictRelativeNestedTTML.utf8))
        XCTAssertEqual(document.groups.count, 2)
        XCTAssertEqual(document.groups[0].main.range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(document.groups[0].main.words[0].range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(document.groups[1].main.range.start, 4, accuracy: 0.0001)
        XCTAssertEqual(document.groups[1].main.words[1].range.end, 7, accuracy: 0.0001)
    }

    @MainActor
    func testAMLLAbsoluteTTMLIsDecodedWithoutNormalization() throws {
        let surface = NativeLyricsSurface(role: .main)
        surface.applyTrack(
            trackID: UUID(),
            ttml: legacyAbsoluteTTML,
            currentTime: 1,
            isPlaying: true
        )

        XCTAssertNil(surface.lastError)
        let groups = try XCTUnwrap(surface.view.document?.groups)
        XCTAssertEqual(groups.count, 2)

        // The source repeats absolute values (div/p/span: 1, 1, 1). The
        // native document must retain the authored media positions instead of
        // adding those values at every nesting level.
        XCTAssertEqual(groups[0].main.range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.range.end, 4, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.range.start, 4, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.range.end, 8, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.words[0].range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.words[0].range.end, 2, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.words[0].range.start, 4, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.words[0].range.end, 6, accuracy: 0.0001)
    }

    @MainActor
    func testLegacyUnnamespacedTTMLIsAcceptedWithoutNamespaceRewrite() throws {
        let surface = NativeLyricsSurface(role: .main)
        surface.applyTrack(
            trackID: UUID(),
            ttml: legacyUnnamespacedTTML,
            currentTime: 1,
            isPlaying: false
        )

        XCTAssertNil(surface.lastError)
        let group = try XCTUnwrap(surface.view.document?.groups.first)
        XCTAssertEqual(group.main.text, "Unnamespaced")
        XCTAssertEqual(group.main.range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(group.main.range.end, 4, accuracy: 0.0001)
    }

    @MainActor
    func testSharedPlaybackDoesNotOverwriteBatchPreview() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        manager.activate(role: .batchPreview)
        let preview = manager.surface(for: .batchPreview)
        let previewID = UUID()
        preview.applyTrack(
            trackID: previewID,
            ttml: previewTTML,
            currentTime: 3,
            isPlaying: false
        )

        manager.updatePlaybackSnapshot(
            trackID: UUID(),
            lyricsTTML: mainTTML,
            currentTime: 12,
            isPlaying: true
        )

        XCTAssertEqual(preview.lastTrackID, previewID)
        XCTAssertEqual(preview.lastTTML, previewTTML)
        XCTAssertEqual(preview.currentTime, 3)
        XCTAssertFalse(preview.isPlaying)
    }

    @MainActor
    func testActivationOwnsAutomaticFrameDelivery() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        let originalTrackID = UUID()
        let latestTrackID = UUID()
        let latestTTML = mainTTML.replacingOccurrences(of: "Main", with: "Latest")
        manager.updatePlaybackSnapshot(
            trackID: originalTrackID,
            lyricsTTML: mainTTML,
            currentTime: 1,
            isPlaying: true
        )
        let surface = manager.surface(for: .main)
        XCTAssertFalse(surface.isRenderingActive)
        XCTAssertNil(surface.lastTrackID)

        manager.activate(role: .main)
        XCTAssertTrue(surface.isRenderingActive)
        XCTAssertEqual(surface.lastTrackID, originalTrackID)
        XCTAssertEqual(surface.lastTTML, mainTTML)

        manager.deactivate(role: .main)
        XCTAssertFalse(surface.isRenderingActive)
        XCTAssertIdentical(manager.existingSurface(for: .main), surface)

        manager.updatePlaybackSnapshot(
            trackID: latestTrackID,
            lyricsTTML: latestTTML,
            currentTime: 3,
            isPlaying: false
        )
        XCTAssertEqual(surface.lastTrackID, originalTrackID)
        XCTAssertEqual(surface.lastTTML, mainTTML)

        manager.activate(role: .main)
        XCTAssertTrue(surface.isRenderingActive)
        XCTAssertEqual(surface.lastTrackID, latestTrackID)
        XCTAssertEqual(surface.lastTTML, latestTTML)
        XCTAssertEqual(surface.currentTime, 3)
        XCTAssertFalse(surface.isPlaying)
    }

    @MainActor
    func testActivationRestoresPausedSeekAfterDeferredResourceReleaseForPlaybackSurfaces() async throws {
        let manager = NativeLyricsSurfaceManager.shared
        defer { manager.shutdownAll() }

        for role in [LyricsSurfaceRole.main, .fullscreen, .fullscreenCoverBlurHighlight] {
            manager.shutdownAll()

            let trackID = UUID()
            manager.updatePlaybackSnapshot(
                trackID: trackID,
                lyricsTTML: legacyAbsoluteTTML,
                currentTime: 2,
                isPlaying: false
            )
            let surface = manager.surface(for: role)
            surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            manager.activate(role: role)
            XCTAssertEqual(surface.view.lastFrame?.timeline.focus, 0, "Initial focus for \(role)")

            manager.deactivate(role: role)
            manager.updatePlaybackSnapshot(
                trackID: trackID,
                lyricsTTML: legacyAbsoluteTTML,
                currentTime: 6,
                isPlaying: false
            )
            try await Task.sleep(for: .milliseconds(650))

            XCTAssertFalse(surface.isRenderingActive, "Inactive state for \(role)")
            XCTAssertEqual(renderedRowLayerCount(of: surface), 0, "Released row layers for \(role)")
            XCTAssertEqual(manager.currentPlaybackTime, 6, accuracy: 0.0001)

            manager.activate(role: role)
            let restoredSurface = manager.surface(for: role)
            restoredSurface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)

            XCTAssertEqual(restoredSurface.currentTime, 6, accuracy: 0.0001, "Restored time for \(role)")
            XCTAssertEqual(manager.currentPlaybackTime, 6, accuracy: 0.0001)
            let restoredFrame = restoredSurface.view.render(at: CACurrentMediaTime())
            XCTAssertEqual(restoredFrame.timeline.focus, 1, "Restored focus for \(role)")
            XCTAssertGreaterThan(renderedRowLayerCount(of: restoredSurface), 0, "Rebuilt row layers for \(role)")
        }
    }

    @MainActor
    func testPendingSidecarLoadCannotReplaceExternalLyricsForTheSameTrack() async throws {
        let nativeManager = NativeLyricsSurfaceManager.shared
        nativeManager.shutdownAll()
        let lyricsViewModel = LyricsViewModel(settings: AppSettings.shared)
        defer {
            lyricsViewModel.clearLyrics()
            nativeManager.shutdownAll()
        }

        let trackID = UUID()
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cancel-\(UUID().uuidString)", isDirectory: true)
        let paths = LibraryPaths(rootURL: libraryRoot)
        try FileManager.default.createDirectory(
            at: paths.trackFolderURL(for: trackID),
            withIntermediateDirectories: true
        )
        let lyricsURL = try XCTUnwrap(paths.trackAssetURL(for: trackID, fileName: "legacy.lrc"))
        try Data("[00:01.000]Local sidecar".utf8).write(to: lyricsURL)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let track = Track(
            id: trackID,
            title: "Matched local track",
            libraryRootSnapshot: libraryRoot.path,
            lyricsFileName: "legacy.lrc"
        )
        lyricsViewModel.ensureLyricsLoaded(
            track: track,
            currentTime: 1,
            isPlaying: false,
            reason: "test pending sidecar"
        )

        var external = NowPlayingPresentation.emptyAppleMusic
        external.localTrack = track
        external.title = "External playback"
        external.lyricsText = mainTTML
        external.lyricsIdentity = "test-external-lyrics"
        external.currentTime = 3
        external.lyricsCurrentTimeOverride = 3
        external.isPlaying = false
        external.lyricsIsPlaying = false
        lyricsViewModel.ensureExternalLyricsLoaded(
            presentation: external,
            reason: "test source switch"
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(nativeManager.currentTTML.contains("Main"))
        XCTAssertEqual(nativeManager.currentPlaybackTime, 3, accuracy: 0.0001)
        XCTAssertNil(track.lyricsText, "A cancelled track load must not start its legacy sidecar read")
    }

    @MainActor
    func testPendingLegacyLyricsMigrationCannotReplaceExternalLyricsForTheSameTrack() async throws {
        let nativeManager = NativeLyricsSurfaceManager.shared
        nativeManager.shutdownAll()
        let lyricsViewModel = LyricsViewModel(settings: AppSettings.shared)
        defer {
            lyricsViewModel.clearLyrics()
            nativeManager.shutdownAll()
        }

        let track = Track(
            title: "Matched local track with legacy lyrics",
            lyricsText: "[00:01.000]Local line\n[00:03.000]Next local line"
        )
        lyricsViewModel.applyTrack(track, currentTime: 1, isPlaying: false)

        var external = NowPlayingPresentation.emptyAppleMusic
        external.localTrack = track
        external.title = "External playback"
        external.lyricsText = mainTTML
        external.lyricsIdentity = "test-external-legacy-race"
        external.currentTime = 3
        external.lyricsCurrentTimeOverride = 3
        external.isPlaying = false
        external.lyricsIsPlaying = false
        lyricsViewModel.ensureExternalLyricsLoaded(
            presentation: external,
            reason: "test legacy source switch"
        )

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(nativeManager.currentTTML.contains("Main"))
        XCTAssertEqual(nativeManager.currentPlaybackTime, 3, accuracy: 0.0001)
        XCTAssertNil(track.ttmlLyricText)
    }

    @MainActor
    func testPendingSidecarLoadInstallsAtLatestSeekAndPlayingState() async throws {
        let nativeManager = NativeLyricsSurfaceManager.shared
        nativeManager.shutdownAll()
        let lyricsViewModel = LyricsViewModel(settings: AppSettings.shared)
        defer {
            lyricsViewModel.clearLyrics()
            nativeManager.shutdownAll()
        }

        let track = Track(title: "Pending sidecar seek")
        lyricsViewModel.syncTime(1, force: true)
        lyricsViewModel.setPlaying(true)
        lyricsViewModel.ensureLyricsLoaded(
            track: track,
            currentTime: 1,
            isPlaying: true,
            reason: "test pending seek"
        )

        lyricsViewModel.syncTime(6, force: true)
        lyricsViewModel.setPlaying(false)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(nativeManager.currentPlaybackTime, 6, accuracy: 0.0001)
        XCTAssertEqual(LyricsSurfaceManager.shared.currentPlaybackTime, 6, accuracy: 0.0001)
        XCTAssertFalse(LyricsSurfaceManager.shared.currentPlaybackIsPlaying)
    }

    @MainActor
    func testPlaybackTimePreviewIsNotOverwrittenByTransportSamples() {
        let nativeManager = NativeLyricsSurfaceManager.shared
        nativeManager.shutdownAll()
        defer { nativeManager.shutdownAll() }

        let surfaceManager = LyricsSurfaceManager.shared
        surfaceManager.updatePlaybackSnapshot(
            trackID: UUID(),
            lyricsTTML: mainTTML,
            currentTime: 1,
            isPlaying: true
        )
        nativeManager.activate(role: .main)
        let surface = nativeManager.surface(for: .main)

        surfaceManager.beginPlaybackTimePreview(at: 7, isPlaying: true)
        XCTAssertEqual(surface.currentTime, 7, accuracy: 0.0001)
        XCTAssertFalse(surface.isPlaying)

        // The normal presentation clock continues to publish while audio is
        // playing, but must not pull the lyric preview back under the pointer.
        surfaceManager.updatePlaybackTime(2)
        XCTAssertEqual(surface.currentTime, 7, accuracy: 0.0001)

        surfaceManager.updatePlaybackTimePreview(8)
        XCTAssertEqual(surface.currentTime, 8, accuracy: 0.0001)

        surfaceManager.endPlaybackTimePreview(at: 8, isPlaying: true)
        XCTAssertEqual(surface.currentTime, 8, accuracy: 0.0001)
        XCTAssertTrue(surface.isPlaying)
    }

    @MainActor
    func testPauseUsesPredictedSurfaceTimeAndIgnoresStalePausedSamples() {
        let surface = NativeLyricsSurface(role: .main)
        surface.applyTrack(
            trackID: UUID(),
            ttml: mainTTML,
            currentTime: 1,
            isPlaying: true
        )

        let pauseHost = CACurrentMediaTime() + 0.25
        surface.setPlaying(false, hostTime: pauseHost)
        let pausedTime = surface.currentTime
        XCTAssertGreaterThan(pausedTime, 1.1)

        // A normal callback after the pause can still carry the old transport
        // sample. It must not move the already-frozen native clock backwards.
        surface.setCurrentTime(1)
        XCTAssertEqual(surface.currentTime, pausedTime, accuracy: 0.0001)

        surface.setPlaying(true, hostTime: pauseHost + 0.5)
        XCTAssertEqual(surface.currentTime, pausedTime, accuracy: 0.0001)
    }

    @MainActor
    func testSeekHandlerSurvivesLazySurfaceCreation() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        var requestedTime: Double?
        manager.setSeekHandler({ requestedTime = $0 }, for: .fullscreen)
        manager.activate(role: .fullscreen)
        manager.surface(for: .fullscreen).onSeek?(17.25)

        XCTAssertEqual(requestedTime, 17.25)
    }

    @MainActor
    func testEmptyPayloadClearsThePreviouslyRenderedDocument() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        manager.activate(role: .main)
        manager.updatePlaybackSnapshot(
            trackID: UUID(),
            lyricsTTML: mainTTML,
            currentTime: 2,
            isPlaying: true
        )
        let surface = manager.surface(for: .main)
        XCTAssertNotNil(surface.view.document)

        manager.updatePlaybackSnapshot(
            trackID: UUID(),
            lyricsTTML: "",
            currentTime: 0,
            isPlaying: false
        )

        XCTAssertNil(surface.view.document)
        XCTAssertEqual(surface.lastTTML, "")
        XCTAssertNil(surface.lastError)
    }

    @MainActor
    func testInvalidPayloadPreservesTheLastValidDocument() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        manager.activate(role: .main)
        let surface = manager.surface(for: .main)
        let validID = UUID()
        surface.applyTrack(
            trackID: validID,
            ttml: mainTTML,
            currentTime: 2,
            isPlaying: true
        )
        let validDocument = surface.view.document

        surface.applyTrack(
            trackID: UUID(),
            ttml: "not TTML",
            currentTime: 3,
            isPlaying: true
        )

        XCTAssertEqual(surface.view.document, validDocument)
        XCTAssertEqual(surface.lastTrackID, validID)
        XCTAssertEqual(surface.lastTTML, mainTTML)
        XCTAssertNotNil(surface.lastError)
        XCTAssertEqual(surface.currentTime, 3)
    }

    @MainActor
    func testConfigurationIsInstalledBeforeLazySurfaceCreation() throws {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        let json = """
        {
          "timeOffsetMs": 275,
          "seekTimeOffsetMs": 425,
          "alignPosition": 0.72,
          "alignOffset": 18,
          "alignAnchor": "bottom",
          "springDuration": 0.55,
          "springBounce": 0.75,
          "enableSpring": true
        }
        """
        manager.applyConfigurationJSON(json, for: .fullscreen)
        XCTAssertNil(manager.existingSurface(for: .fullscreen))

        manager.activate(role: .fullscreen)
        let configuration = try XCTUnwrap(
            manager.existingSurface(for: .fullscreen)?.view.configuration
        )
        XCTAssertEqual(configuration.timing.trackOffset, 0.275, accuracy: 0.0001)
        XCTAssertEqual(configuration.timing.seekOffset, 0.425, accuracy: 0.0001)
        XCTAssertEqual(configuration.alignPosition, 0.72, accuracy: 0.0001)
        XCTAssertEqual(configuration.alignOffset, 18, accuracy: 0.0001)
        XCTAssertEqual(configuration.alignAnchor, .bottom)
        XCTAssertEqual(configuration.interludeDotScale, 1.45, accuracy: 0.0001)
        XCTAssertEqual(
            configuration.renderScale,
            AppSettings.shared.amllLyricsRenderQualityScale,
            accuracy: 0.0001
        )
        let expectedSpring = SpringParameters.positionOverride(duration: 0.55, bounce: 0.75)
        XCTAssertEqual(configuration.positionSpring, expectedSpring)
        XCTAssertNotEqual(configuration.positionSpring, .position)
    }

    @MainActor
    func testAMLLRenderQualityMapsToExpectedNativeResolutionScale() {
        XCTAssertEqual(AppSettings.AMLLLyricsRenderQuality.low.renderScale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(AppSettings.AMLLLyricsRenderQuality.medium.renderScale, 0.75, accuracy: 0.0001)
        XCTAssertEqual(AppSettings.AMLLLyricsRenderQuality.high.renderScale, 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testSettingsDefaultsAndJSONInstallTheSameConcreteSpring() throws {
        let fromSettings = try XCTUnwrap(
            NativeLyricsSurfaceManager.springParameters(
                from: LyricSpringUserSettings(
                    enabled: true,
                    duration: AppSettings.defaultLyricSpringDuration,
                    bounce: AppSettings.defaultLyricSpringBounce
                )
            )
        )
        let fromJSON = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(
                "{\"springDuration\":0.55,\"springBounce\":0.75,\"enableSpring\":true}",
                role: .fullscreen
            )?.positionSpring
        )

        XCTAssertEqual(fromSettings, fromJSON)
        XCTAssertLessThan(
            fromSettings.damping,
            2 * sqrt(fromSettings.mass * fromSettings.stiffness)
        )
    }

    @MainActor
    func testPreviousNativeSpringDefaultsAreNotTreatedAsCurrentDefault() throws {
        let configuration = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(
                "{\"springDuration\":0.65,\"springBounce\":0.25}",
                role: .fullscreen
            )
        )

        XCTAssertNotNil(configuration.positionSpring)
    }

    @MainActor
    func testFullscreenDiscreteHighlightConfigurationReachesNativeSurface() throws {
        let configuration = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(
                "{\"wordHighlightMode\":\"discrete\"}",
                role: .fullscreen
            )
        )
        XCTAssertEqual(configuration.highlightMode, .discrete)
    }

    @MainActor
    func testNativePointerSuppressionCannotBeReopenedByInsideEvents() {
        let manager = NativeLyricsSurfaceManager.shared
        manager.shutdownAll()
        defer { manager.shutdownAll() }

        manager.activate(role: .fullscreen)
        let surface = manager.surface(for: .fullscreen)
        surface.setMouseInteractionSuppressed(true)
        surface.setPointerInside(true)

        XCTAssertTrue(surface.view.isPointerInteractionSuppressed)
        surface.setMouseInteractionSuppressed(false)
        XCTAssertFalse(surface.view.isPointerInteractionSuppressed)
    }

    @MainActor
    func testGenericFullscreenCoverKeepsBothInkChannelsOnSingleSurface() throws {
        let json = "{\"coverBlurFullscreenGenericMode\":true,\"coverBlurFullscreenGenericProfile\":\"lighter\"}"
        let configuration = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(json, role: .fullscreen)
        )
        XCTAssertTrue(configuration.coverBlurGenericMode)
        XCTAssertEqual(configuration.surface, .coverBlurLight)
        XCTAssertEqual(configuration.effectiveRenderLayer, .full)

        let highlight = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(json, role: .fullscreenCoverBlurHighlight)
        )
        XCTAssertEqual(highlight.effectiveRenderLayer, .highlight)
    }

    @MainActor
    func testLineTimingColorsReachNativePaletteForFullscreenAndCoverBlur() throws {
        let json = """
        {
          "fullscreenInactiveColor": "rgb(20, 30, 40)",
          "fullscreenSubColor": "rgb(50, 60, 70)",
          "fullscreenLineTimingInactiveColor": "rgb(80, 90, 100)",
          "fullscreenLineTimingSubInactiveColor": "rgb(110, 120, 130)",
          "coverBlurLineTimingInactiveColor": "rgb(140, 150, 160)",
          "coverBlurLineTimingSubInactiveColor": "rgb(170, 180, 190)"
        }
        """
        let fullscreen = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(json, role: .fullscreen)
        )
        XCTAssertEqual(fullscreen.palette.lineTimingInactive.red, 80.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(fullscreen.palette.lineTimingSubInactive.blue, 130.0 / 255.0, accuracy: 0.0001)

        let cover = try XCTUnwrap(
            NativeLyricsConfigurationMapper.fromJSON(
                "{\"coverBlurFullscreenGenericMode\":true," +
                "\"coverBlurLineTimingInactiveColor\":\"rgb(140, 150, 160)\",\"coverBlurLineTimingSubInactiveColor\":\"rgb(170, 180, 190)\"}",
                role: .fullscreen
            )
        )
        XCTAssertEqual(cover.palette.lineTimingInactive.red, 140.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(cover.palette.lineTimingSubInactive.green, 180.0 / 255.0, accuracy: 0.0001)
    }

    @MainActor
    func testGlobalThemeRefreshReplaysGuardedFullscreenPaletteAndConfig() throws {
        let native = NativeLyricsSurfaceManager.shared
        let surfaces = LyricsSurfaceManager.shared
        surfaces.shutdownAll()
        defer { surfaces.shutdownAll() }

        let trackID = UUID()
        let base = ThemePalette(
            scheme: .dark,
            background: "#000000",
            text: "#ffffff",
            activeLine: "#ffffff",
            inactiveLine: "#555555"
        )
        let override = ThemePalette(
            scheme: .dark,
            background: "#111111",
            text: "#fefefe",
            activeLine: "#f2c078",
            inactiveLine: "#6a402d"
        )
        surfaces.updatePlaybackSnapshot(
            trackID: trackID,
            lyricsTTML: "",
            currentTime: 0,
            isPlaying: false
        )
        surfaces.updateThemeOverrideSnapshot(
            override,
            for: .fullscreen,
            trackID: trackID,
            trackGuarded: true
        )
        surfaces.updateSurfaceConfigSnapshot(
            "{\"fullscreenLineTimingInactiveColor\":\"rgb(80, 90, 100)\"}",
            for: .fullscreen,
            trackID: trackID,
            trackGuarded: true
        )

        let revision = native.documentPublication.revision
        surfaces.applyTheme(base)
        XCTAssertEqual(native.documentPublication.revision, revision + 1)

        let configuration = try XCTUnwrap(native.configuration(for: .fullscreen))
        XCTAssertEqual(configuration.palette.mainActive.red, 242.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.palette.mainInactive.blue, 45.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.palette.lineTimingInactive.red, 80.0 / 255.0, accuracy: 0.0001)

        // An unchanged final skin configuration must not publish the
        // intermediate global palette or override-only palette.
        surfaces.applyTheme(base)
        XCTAssertEqual(native.documentPublication.revision, revision + 1)

        // An inactive surface must also lose the old track's override before
        // it can be reactivated for a different playback source or track.
        surfaces.deactivate(role: .fullscreen)
        surfaces.updatePlaybackSnapshot(
            trackID: UUID(), lyricsTTML: "", currentTime: 0, isPlaying: false
        )
        surfaces.applyTheme(base)
        let nextTrack = try XCTUnwrap(native.configuration(for: .fullscreen))
        XCTAssertEqual(nextTrack.palette, NativeLyricsConfigurationMapper.paletteForWindow(base))
    }

    @MainActor
    func testClearedFullscreenThemeDoesNotReplaySavedSkinColors() throws {
        let native = NativeLyricsSurfaceManager.shared
        let surfaces = LyricsSurfaceManager.shared
        surfaces.shutdownAll()
        defer { surfaces.shutdownAll() }
        let palette = ThemePalette(
            scheme: .dark, background: "#000000", text: "#ffffff",
            activeLine: "#ffffff", inactiveLine: "#555555"
        )
        surfaces.updateThemeOverrideSnapshot(palette, for: .fullscreen)
        surfaces.updateSurfaceConfigSnapshot(
            "{\"fontSize\":42,\"fullscreenActiveColor\":\"rgb(80, 90, 100)\"}",
            for: .fullscreen
        )
        surfaces.applyTheme(palette)
        surfaces.updateThemeOverrideSnapshot(nil, for: .fullscreen)
        surfaces.applyTheme(palette)
        let configuration = try XCTUnwrap(native.configuration(for: .fullscreen))
        XCTAssertEqual(configuration.palette, NativeLyricsConfigurationMapper.paletteForWindow(palette))
        XCTAssertEqual(configuration.fontSize, 42)
    }

    @MainActor
    func testSurfaceCreatedAfterThemeRefreshInheritsLatestBasePalette() {
        let native = NativeLyricsSurfaceManager.shared
        native.shutdownAll()
        defer { native.shutdownAll() }
        let palette = ThemePalette(
            scheme: .dark, background: "#000000", text: "#ffffff",
            activeLine: "#f2c078", inactiveLine: "#6a402d"
        )
        native.applyTheme(palette)
        let surface = native.surface(for: .fullscreen)
        native.activate(role: .fullscreen)
        XCTAssertEqual(surface.view.configuration.palette, NativeLyricsConfigurationMapper.paletteForWindow(palette))
    }

    @MainActor
    func testGlobalThemeRefreshDoesNotRestoreStaleMainTextColor() throws {
        let native = NativeLyricsSurfaceManager.shared
        let surfaces = LyricsSurfaceManager.shared
        native.shutdownAll()
        defer {
            native.shutdownAll()
            surfaces.updateSurfaceConfigSnapshot("{}", for: .main)
        }

        // The main-panel snapshot contains the previous light-mode textColor,
        // while ThemeStore has just published the confirmed artwork palette.
        surfaces.updateSurfaceConfigSnapshot(
            "{\"textColor\":\"rgba(0,0,0,0.9)\"}",
            for: .main
        )
        let palette = ThemePalette(
            scheme: .dark,
            background: "#111111",
            text: "#f2c078",
            activeLine: "#f2c078",
            inactiveLine: "#6a402d"
        )

        surfaces.applyTheme(palette)

        let configuration = try XCTUnwrap(native.configuration(for: .main))
        XCTAssertEqual(configuration.palette.mainActive.red, 242.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.palette.mainActive.green, 192.0 / 255.0, accuracy: 0.0001)
    }

    @MainActor
    func testGlyphCacheBudgetIsStrictlyClampedToRoleBudget() throws {
        let native = NativeLyricsSurfaceManager.shared
        native.shutdownAll()
        defer { native.shutdownAll() }

        var largeConfig = LyricsConfiguration()
        largeConfig.cacheBudgetBytes = 64 * 1024 * 1024
        native.applyConfiguration(largeConfig, for: .main)

        let resolved = try XCTUnwrap(native.configuration(for: .main))
        XCTAssertLessThanOrEqual(resolved.cacheBudgetBytes, LyricsSurfaceRole.main.glyphCacheBudgetBytes)
        XCTAssertEqual(resolved.cacheBudgetBytes, 3 * 1024 * 1024)

        let jsonMapped = try XCTUnwrap(NativeLyricsConfigurationMapper.fromJSON(
            "{\"cacheBudgetBytes\": 104857600}",
            role: .fullscreen
        ))
        XCTAssertLessThanOrEqual(jsonMapped.cacheBudgetBytes, LyricsSurfaceRole.fullscreen.glyphCacheBudgetBytes)
        XCTAssertEqual(jsonMapped.cacheBudgetBytes, 6 * 1024 * 1024)
    }

    @MainActor
    func testPurgeInactiveRenderingResourcesOnlyReleasesInactiveSurfaces() throws {
        let native = NativeLyricsSurfaceManager.shared
        native.shutdownAll()
        defer { native.shutdownAll() }

        native.activate(role: .main)
        let mainSurface = native.surface(for: .main)
        mainSurface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        mainSurface.applyTrack(trackID: UUID(), ttml: mainTTML, currentTime: 2, isPlaying: true)

        let standaloneSurface = native.surface(for: .standalone)
        standaloneSurface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        standaloneSurface.applyTrack(trackID: UUID(), ttml: previewTTML, currentTime: 3, isPlaying: false)

        XCTAssertNotNil(mainSurface.view.document)
        XCTAssertNotNil(standaloneSurface.view.document)

        native.purgeInactiveRenderingResources()

        XCTAssertNotNil(mainSurface.view.document)
        XCTAssertFalse(standaloneSurface.isRenderingActive)
    }

    @MainActor
    func testInvalidTTMLDoesNotDestroyExistingRenderingLayers() throws {
        let native = NativeLyricsSurfaceManager.shared
        native.shutdownAll()
        defer { native.shutdownAll() }

        native.activate(role: .main)
        let surface = native.surface(for: .main)
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let validID = UUID()
        surface.applyTrack(trackID: validID, ttml: mainTTML, currentTime: 2, isPlaying: true)

        let originalDoc = surface.view.document
        XCTAssertNotNil(originalDoc)

        surface.applyTrack(trackID: UUID(), ttml: "<<bad-ttml>>", currentTime: 2.5, isPlaying: true)

        XCTAssertEqual(surface.view.document, originalDoc)
        XCTAssertEqual(surface.lastTrackID, validID)
        XCTAssertEqual(surface.lastTTML, mainTTML)
        XCTAssertNotNil(surface.lastError)
    }

    /// A skin switch remounts the fullscreen presentation layers and a memory
    /// reclaim can drop the surface's layer tree while the document stays
    /// installed. A visible surface must rebuild its rows in place instead of
    /// staying blank until the next fullscreen entry.
    @MainActor
    func testReassertRenderingRebuildsReleasedLayerTreeInPlace() throws {
        let native = NativeLyricsSurfaceManager.shared
        native.shutdownAll()
        defer { native.shutdownAll() }

        native.activate(role: .fullscreen)
        let surface = native.surface(for: .fullscreen)
        surface.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        surface.view.layoutSubtreeIfNeeded()
        surface.applyTrack(trackID: UUID(), ttml: mainTTML, currentTime: 2, isPlaying: false)

        XCTAssertNotNil(surface.view.document)
        XCTAssertTrue(surface.isRenderingActive)
        XCTAssertGreaterThan(
            renderedRowLayerCount(of: surface),
            0,
            "an installed document renders at least one row layer"
        )

        surface.releaseRenderingResources()
        XCTAssertEqual(
            renderedRowLayerCount(of: surface),
            0,
            "a released surface keeps no row layers"
        )
        XCTAssertNotNil(surface.view.document, "releasing resources keeps the decoded document")

        surface.reassertRendering()

        XCTAssertGreaterThan(
            renderedRowLayerCount(of: surface),
            0,
            "reassertRendering must rebuild the released layer tree in place"
        )
        XCTAssertTrue(surface.isRenderingActive)
    }

    /// `LyricsView` adds one content layer to its own layer; lyric rows,
    /// interlude dots and the bottom text are sublayers of it, so the row count
    /// is the content's children minus the dots and the bottom text.
    @MainActor
    private func renderedRowLayerCount(of surface: NativeLyricsSurface) -> Int {
        guard let content = surface.view.layer?.sublayers?.first else { return 0 }
        return max(0, (content.sublayers?.count ?? 0) - 2)
    }

}
