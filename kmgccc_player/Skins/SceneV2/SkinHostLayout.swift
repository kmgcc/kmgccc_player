import MotionKit
import SwiftUI

/// The geometry the built-in hosts give a preset skin, in viewport points. Scenes read it as
/// `host.layout`, and preset layers drawn with `layout: "host"` use the same numbers, so an
/// author template can line its lyrics and mini player up with the bundled skins exactly.
enum SkinHostLayout {
    static let canvas = CGSize(width: 1470, height: 923)
    static let buttonSize: CGFloat = 60
    static let controlsBottomPadding: CGFloat = 72
    /// Window scenes draw the fullscreen capsule a little smaller than the fullscreen host.
    static let windowControlsScale: CGFloat = 0.8

    struct Frames {
        var scale: CGFloat
        var canvas: CGRect
        var artwork: CGRect
        var lyrics: CGRect
        var miniPlayer: CGRect
    }

    static func fullscreenScale(for size: CGSize) -> CGFloat {
        max(0.01, min(size.width / canvas.width, size.height / canvas.height))
    }

    static func frames(size: CGSize, surface: SkinSurface, lyricsVisible: Bool,
                       presentation: SkinPresentationPolicy) -> Frames {
        surface == .fullscreen
            ? fullscreen(size: size, lyricsVisible: lyricsVisible, presentation: presentation)
            : window(size: size, lyricsVisible: lyricsVisible)
    }

    private static func fullscreen(size: CGSize, lyricsVisible: Bool, presentation: SkinPresentationPolicy) -> Frames {
        let scale = fullscreenScale(for: size)
        let origin = CGPoint(x: max(0, (size.width - canvas.width * scale) / 2), y: max(0, (size.height - canvas.height * scale) / 2))
        let split = FullscreenHorizontalSplitLayout.resolve(showLyricsColumn: lyricsVisible)
        let backdrop = presentation.artworkLayout == .backdrop && presentation.lyricsBackdrop == .coverBlur
        let groupShift = lyricsVisible && !backdrop ? FullscreenCoverHorizontalOffset.groupLeftBias : 0
        // FullscreenScaledArtworkContainer: 6 pt above, 12 pt below, then the controls reserve.
        let artworkHeight = canvas.height - controlsBottomPadding - buttonSize - 18
        let artwork = CGRect(x: origin.x + (split.artworkLeadingX - groupShift) * scale, y: origin.y + 6 * scale,
                             width: split.artworkWidth * scale, height: artworkHeight * scale)

        // Mirrors FullscreenNativeLyricsLayer, including the cover-blur legacy column.
        let lyricsLeadingX: CGFloat
        let readableWidth: CGFloat
        if backdrop {
            let constrained = max(0, canvas.width - 88)
            let legacyLyricsWidth = min(max(constrained * 0.30, 320), 560)
            let legacyArtworkWidth = max(constrained - legacyLyricsWidth + 58, 360)
            let scaleX = size.width / canvas.width
            let columnCenterX = -44 + legacyArtworkWidth / 2
            let correction = (columnCenterX - canvas.width / 2) * (scaleX - scale) / scale
            lyricsLeadingX = -44 + correction + legacyArtworkWidth - 58 - 80 - 80 + 30
            readableWidth = legacyLyricsWidth
        } else {
            lyricsLeadingX = split.lyricsLeadingX - groupShift
            readableWidth = split.lyricsWidth
        }
        let lyricsX = lyricsLeadingX * scale + origin.x
        let rightPad = max(44 * scale, readableWidth * scale * 0.08)
        let lyricsWidth = max(100, max(readableWidth * scale, size.width - lyricsX - rightPad))
        let lyrics = CGRect(x: lyricsX, y: 0, width: lyricsWidth, height: (canvas.height - controlsBottomPadding) * scale)

        let group = FullscreenBottomControlsGeometry.make(isLeftActionsExpanded: false, isVolumeExpanded: false).fullGroupRect
        let miniPlayer = CGRect(x: origin.x + group.minX * scale,
                                y: size.height - (controlsBottomPadding + buttonSize) * scale,
                                width: group.width * scale, height: buttonSize * scale)
        return Frames(scale: scale, canvas: CGRect(origin: origin, size: CGSize(width: canvas.width * scale, height: canvas.height * scale)),
                      artwork: artwork, lyrics: lyrics, miniPlayer: miniPlayer)
    }

    private static func window(size: CGSize, lyricsVisible: Bool) -> Frames {
        let scale = windowControlsScale
        let controlsHeight = buttonSize * scale
        let bottom = size.height - controlsHeight - 20
        let artworkWidth = lyricsVisible ? size.width * 0.56 : size.width
        let artwork = CGRect(x: 0, y: 0, width: artworkWidth, height: max(0, bottom - 12))
        let lyrics = CGRect(x: artworkWidth, y: 24, width: max(0, size.width - artworkWidth - 32), height: max(0, bottom - 36))
        let group = FullscreenBottomControlsGeometry.make(isLeftActionsExpanded: false, isVolumeExpanded: false).fullGroupRect
        let width = min(size.width - 48, group.width * scale)
        let miniPlayer = CGRect(x: (size.width - width) / 2, y: bottom, width: width, height: controlsHeight)
        return Frames(scale: scale, canvas: CGRect(origin: .zero, size: size), artwork: artwork, lyrics: lyrics, miniPlayer: miniPlayer)
    }

    static func value(_ frames: Frames) -> SkinValue {
        func rect(_ rect: CGRect) -> SkinValue {
            .record(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height),
                     "midX": .number(rect.midX), "midY": .number(rect.midY)])
        }
        return .record(["scale": .number(frames.scale), "canvas": rect(frames.canvas), "artwork": rect(frames.artwork),
                        "lyrics": rect(frames.lyrics), "miniPlayer": rect(frames.miniPlayer)])
    }
}

extension EnvironmentValues {
    /// The presentation policy of the skin a scene belongs to.
    @Entry var skinScenePresentation = SkinPresentationPolicy()
}

extension SkinContext {
    /// The same facts laid out as a host would lay them out for a preset renderer.
    func relaid(windowSize: CGSize, contentSize: CGSize, fullscreenScale: CGFloat, lyricsVisible: Bool,
                presentationMode: PresentationMode, motionTokens: MotionTokens, motionPolicy: MotionPolicy) -> SkinContext {
        SkinContext(
            track: track, playback: playback, theme: theme, motionTokens: motionTokens, motionPolicy: motionPolicy,
            windowSize: windowSize, contentBounds: CGRect(origin: .zero, size: contentSize),
            fullscreenScale: fullscreenScale, lyricsVisible: lyricsVisible,
            presentationMode: presentationMode, fullscreenHostMode: fullscreenHostMode
        )
    }
}
