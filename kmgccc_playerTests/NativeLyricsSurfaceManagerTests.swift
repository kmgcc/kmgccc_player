import XCTest
import NativeLyrics
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

        manager.updatePlaybackSnapshot(
            trackID: UUID(),
            lyricsTTML: mainTTML,
            currentTime: 1,
            isPlaying: true
        )
        let surface = manager.surface(for: .main)
        XCTAssertFalse(surface.isRenderingActive)

        manager.activate(role: .main)
        XCTAssertTrue(surface.isRenderingActive)

        manager.deactivate(role: .main)
        XCTAssertFalse(surface.isRenderingActive)
        XCTAssertIdentical(manager.existingSurface(for: .main), surface)
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
        XCTAssertEqual(configuration.renderScale, 1, accuracy: 0.0001)
        let expectedSpring = SpringParameters.positionOverride(duration: 0.55, bounce: 0.75)
        XCTAssertEqual(configuration.positionSpring, expectedSpring)
        XCTAssertNotEqual(configuration.positionSpring, .position)
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
        native.shutdownAll()
        defer {
            native.shutdownAll()
            surfaces.updateThemeOverrideSnapshot(nil, for: .fullscreen)
            surfaces.updateSurfaceConfigSnapshot("{}", for: .fullscreen)
        }

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

        surfaces.applyTheme(base)

        let configuration = try XCTUnwrap(native.configuration(for: .fullscreen))
        XCTAssertEqual(configuration.palette.mainActive.red, 242.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.palette.mainInactive.blue, 45.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(configuration.palette.lineTimingInactive.red, 80.0 / 255.0, accuracy: 0.0001)
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

}
