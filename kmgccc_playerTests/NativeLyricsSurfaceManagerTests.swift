import XCTest
import NativeLyrics
import SwiftUI
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

    func testStrictTTMLPassesThroughWithoutTimingRewrite() {
        XCTAssertEqual(
            NativeLyricsTTMLAdapter.normalizeForNative(mainTTML),
            mainTTML
        )
    }

    @MainActor
    func testStrictRelativeNestedTTMLIsNotMistakenForAbsoluteExport() throws {
        let normalized = NativeLyricsTTMLAdapter.normalizeForNative(strictRelativeNestedTTML)
        XCTAssertEqual(normalized, strictRelativeNestedTTML.trimmingCharacters(in: .whitespacesAndNewlines))

        let surface = NativeLyricsSurface(role: .main)
        surface.applyTrack(
            trackID: UUID(),
            ttml: strictRelativeNestedTTML,
            currentTime: 1,
            isPlaying: false
        )

        let groups = try XCTUnwrap(surface.view.document?.groups)
        XCTAssertEqual(groups.count, 2)
        // The div starts at 1s. Child p/span clocks are relative, so the
        // second line begins at 1 + 3 = 4s and its second span ends at 7s.
        XCTAssertEqual(groups[0].main.range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.words[0].range.start, 1, accuracy: 0.0001)
        XCTAssertEqual(groups[0].main.words[1].range.end, 3, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.range.start, 4, accuracy: 0.0001)
        XCTAssertEqual(groups[1].main.words[1].range.end, 7, accuracy: 0.0001)
    }

    @MainActor
    func testLegacyAbsoluteTTMLIsNormalizedBeforeNativeDecode() throws {
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
    func testLegacyUnnamespacedTTMLGetsStandardNamespaceRepair() throws {
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
          "springDuration": 0.65,
          "springBounce": 0.25,
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
        XCTAssertNil(configuration.positionSpring)
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

}
