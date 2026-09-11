//
//  NativeLyricsSurface.swift
//  myPlayer2
//
//  App adapter for the standalone NativeLyrics package.
//
//  The package owns TTML parsing, layout and animation. This file only maps
//  player state/theme values to the package and owns one surface per visible
//  AppKit role. Keeping this boundary small lets NativeLyrics remain usable
//  outside the player without importing Track, AppSettings or ThemeStore.
//

import AppKit
import Foundation
import NativeLyrics
import SwiftUI

@MainActor
final class NativeLyricsSurface: NSObject {
    let role: LyricsSurfaceRole
    let view: LyricsView

    var onSeek: ((Double) -> Void)?
    private(set) var lastError: Error?
    private(set) var lastTTML = ""
    private(set) var lastTrackID: UUID?
    // Keep the input identity separate from the last successfully decoded
    // document. This preserves the old failure boundary: a repeatedly
    // delivered invalid payload is reported once while the last valid view
    // remains on screen.
    private var lastInputTTML = ""
    private var lastInputTrackID: UUID?
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    private var pendingClickSeek = false

    init(role: LyricsSurfaceRole) {
        self.role = role
        self.view = LyricsView(frame: .zero)
        super.init()

        // A surface may be configured or receive a snapshot before a host is
        // visible. Activation is the only operation that starts frame delivery.
        view.automaticDisplayUpdates = false

        view.onSeek = { [weak self] seconds in
            guard let self else { return }
            self.pendingClickSeek = true
            self.onSeek?(seconds)
        }
    }

    var isReady: Bool { lastError == nil }

    var isRenderingActive: Bool { view.automaticDisplayUpdates }

    func setRenderingActive(_ active: Bool) {
        let wasActive = view.automaticDisplayUpdates
        if active {
            // A surface can be reattached to a fullscreen host without a
            // matching mouse-exit event. Reset the transient hover gate before
            // the first frame so inactive-row blur is not lost on re-entry.
            view.setPointerInside(false)
            if !wasActive { view.prepareWakeEntryAnimation() }
        }
        guard wasActive != active else { return }
        view.automaticDisplayUpdates = active
    }

    func apply(configuration: LyricsConfiguration) {
        view.configuration = configuration
    }

    func applyTrack(
        trackID: UUID?,
        ttml: String?,
        currentTime: Double,
        isPlaying: Bool,
        forceLyricsReload: Bool = false
    ) {
        let rawText = ttml ?? ""
        let rawChanged = trackID != lastInputTrackID || rawText != lastInputTTML
        let nextTime = currentTime.isFinite ? max(0, currentTime) : 0
        let sameValidDocument = !rawChanged
            && lastError == nil
            && view.document != nil
            && lastTrackID == trackID
            && lastTTML == rawText
        let isSameTrackReplay = forceLyricsReload
            && sameValidDocument
            && self.currentTime > 1.0
            && nextTime < 0.2
        let forcedSeek = forceLyricsReload && abs(nextTime - self.currentTime) > 0.05
        let shouldReload = rawChanged || isSameTrackReplay || (forceLyricsReload && !sameValidDocument)
        guard shouldReload else {
            // Repeated force-refresh callbacks are common during a track/mode
            // transition. Keep the existing document (and its interlude
            // entrance state) and only rebase the clock when the requested
            // media position actually moved. This prevents a second forced
            // callback from replaying the intro dots halfway through.
            synchronize(time: nextTime, playing: isPlaying, seek: forcedSeek)
            return
        }

        self.currentTime = nextTime
        self.isPlaying = isPlaying
        lastInputTTML = rawText
        lastInputTrackID = trackID

        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            view.clear(time: self.currentTime, playing: isPlaying)
            lastError = nil
            lastTTML = ""
            lastTrackID = trackID
            pendingClickSeek = false
            return
        }

        do {
            try view.load(
                ttml: Data(rawText.utf8),
                time: self.currentTime,
                playing: isPlaying
            )
            lastError = nil
            lastTTML = rawText
            lastTrackID = trackID
        } catch {
            // Parse before replacing the previous visible document. The native
            // view follows the same failure boundary as the old bridge: an
            // invalid payload is recorded and the last valid surface remains.
            lastError = error
            Log.error(
                "Native lyrics TTML rejected role=\(role.rawValue): \(error.localizedDescription)",
                category: .lyrics
            )
            view.synchronize(
                time: self.currentTime,
                playing: isPlaying,
                seek: true,
                motion: .immediate
            )
        }
        pendingClickSeek = false
    }

    func synchronize(
        time: Double,
        playing: Bool,
        seek: Bool = false,
        motion: LyricsSeekMotion = .immediate
    ) {
        guard time.isFinite else { return }
        let hostTime = CACurrentMediaTime()
        let requestedTime = max(0, time)
        let playbackTransition = self.isPlaying != playing
        let clickSeek = pendingClickSeek
        pendingClickSeek = false
        // While paused, ordinary transport callbacks are not seeks. They can
        // still contain the last pre-pause sample and must not rebase the
        // already-frozen lyric clock. Explicit seeks and a real pause/resume
        // transition remain allowed through the normal clock path.
        let effectiveRequestedTime = !playing && !playbackTransition && !seek && !clickSeek
            ? currentTime
            : requestedTime
        currentTime = view.synchronize(
            time: effectiveRequestedTime,
            playing: playing,
            seek: seek || clickSeek,
            motion: clickSeek ? .cascade : motion,
            hostTime: hostTime
        )
        isPlaying = playing
    }

    func setCurrentTime(
        _ time: Double,
        force: Bool = false,
        motion: LyricsSeekMotion = .immediate
    ) {
        guard time.isFinite else { return }
        guard force || abs(time - currentTime) >= 0.001 || pendingClickSeek else { return }
        // A forced update is used for an explicit seek/reveal (for example
        // when the fullscreen surface is brought back on screen). Preserve
        // that intent all the way through the native clock so a stale
        // low-frequency playback sample cannot be mistaken for the seek.
        synchronize(time: time, playing: isPlaying, seek: force, motion: motion)
    }

    func setPlaying(_ playing: Bool, force: Bool = false, hostTime: Double = CACurrentMediaTime()) {
        guard force || playing != isPlaying else { return }
        currentTime = view.synchronize(time: currentTime, playing: playing, hostTime: hostTime)
        isPlaying = playing
    }

    func followCurrentLyrics() {
        view.followCurrentLyrics()
    }

    func setPointerInside(_ inside: Bool) {
        view.setPointerInside(inside)
    }

    func setMouseInteractionSuppressed(_ suppressed: Bool) {
        // Keep the gate in the native view itself. Clearing hover once is not
        // sufficient: the next mouse-moved event would otherwise make a lyric
        // surface under the mini-player clear its blur again.
        view.setPointerInteractionSuppressed(suppressed)
    }

    func releaseRenderingResources() {
        view.releaseRenderingResources()
    }

    func shutdown() {
        setRenderingActive(false)
        view.releaseRenderingResources()
        onSeek = nil
    }
}

@MainActor
final class NativeLyricsSurfaceManager {
    static let shared = NativeLyricsSurfaceManager()

    private struct PlaybackSnapshot {
        var trackID: UUID?
        var ttml = ""
        var time = 0.0
        var playing = false
    }

    private var surfaces: [LyricsSurfaceRole: NativeLyricsSurface] = [:]
    private var configurations: [LyricsSurfaceRole: LyricsConfiguration] = [:]
    private var seekHandlers: [LyricsSurfaceRole: (Double) -> Void] = [:]
    private var activeRoles: Set<LyricsSurfaceRole> = []
    private var snapshot = PlaybackSnapshot()

    private init() {}

    func surface(for role: LyricsSurfaceRole) -> NativeLyricsSurface {
        if let surface = surfaces[role] { return surface }
        let surface = NativeLyricsSurface(role: role)
        if let configuration = configurations[role] {
            surface.apply(configuration: configuration)
        }
        if role.receivesSharedPlaybackSnapshot {
            surface.applyTrack(
                trackID: snapshot.trackID,
                ttml: snapshot.ttml,
                currentTime: snapshot.time,
                isPlaying: snapshot.playing,
                forceLyricsReload: true
            )
        }
        surface.onSeek = seekHandlers[role]
        surface.setRenderingActive(activeRoles.contains(role))
        surfaces[role] = surface
        return surface
    }

    func existingSurface(for role: LyricsSurfaceRole) -> NativeLyricsSurface? {
        surfaces[role]
    }

    var currentPlaybackTime: Double { snapshot.time }

    func activate(role: LyricsSurfaceRole) {
        activeRoles.insert(role)
        surface(for: role).setRenderingActive(true)
    }

    func deactivate(role: LyricsSurfaceRole) {
        activeRoles.remove(role)
        surfaces[role]?.setRenderingActive(false)
        guard !role.persistsState else { return }
        surfaces.removeValue(forKey: role)?.shutdown()
    }

    func isActive(_ role: LyricsSurfaceRole) -> Bool {
        activeRoles.contains(role)
    }

    func updatePlaybackSnapshot(
        trackID: UUID?,
        lyricsTTML: String,
        currentTime: Double,
        isPlaying: Bool,
        forceLyricsReload: Bool = false
    ) {
        snapshot = PlaybackSnapshot(
            trackID: trackID,
            ttml: lyricsTTML,
            time: currentTime.isFinite ? max(0, currentTime) : 0,
            playing: isPlaying
        )
        for (role, surface) in surfaces where role.receivesSharedPlaybackSnapshot {
            surface.applyTrack(
                trackID: trackID,
                ttml: lyricsTTML,
                currentTime: snapshot.time,
                isPlaying: isPlaying,
                forceLyricsReload: forceLyricsReload
            )
        }
        snapshot.time = surfaces.values.first(where: { $0.role.receivesSharedPlaybackSnapshot })?.currentTime ?? snapshot.time
    }

    func applyTrack(
        trackID: UUID?,
        ttml: String?,
        currentTime: Double,
        isPlaying: Bool,
        forceLyricsReload: Bool = false
    ) {
        snapshot = PlaybackSnapshot(
            trackID: trackID,
            ttml: ttml ?? "",
            time: currentTime.isFinite ? max(0, currentTime) : 0,
            playing: isPlaying
        )
        for (role, surface) in surfaces where role.receivesSharedPlaybackSnapshot {
            surface.applyTrack(
                trackID: trackID,
                ttml: ttml,
                currentTime: snapshot.time,
                isPlaying: isPlaying,
                forceLyricsReload: forceLyricsReload
            )
        }
        snapshot.time = surfaces.values.first(where: { $0.role.receivesSharedPlaybackSnapshot })?.currentTime ?? snapshot.time
    }

    func updatePlaybackTime(
        _ time: Double,
        force: Bool = false,
        motion: LyricsSeekMotion = .immediate
    ) {
        guard time.isFinite else { return }
        let normalized = max(0, time)
        snapshot.time = normalized
        for (role, surface) in surfaces where role.receivesSharedPlaybackSnapshot {
            surface.setCurrentTime(normalized, force: force, motion: motion)
        }
        snapshot.time = surfaces.values.first(where: { $0.role.receivesSharedPlaybackSnapshot })?.currentTime ?? normalized
    }

    func updatePlayingState(_ playing: Bool) {
        snapshot.playing = playing
        for (role, surface) in surfaces where role.receivesSharedPlaybackSnapshot {
            surface.setPlaying(playing)
        }
        if let effectiveTime = surfaces.values.first(where: { $0.role.receivesSharedPlaybackSnapshot })?.currentTime {
            snapshot.time = effectiveTime
        }
    }

    func applyConfiguration(_ configuration: LyricsConfiguration, for role: LyricsSurfaceRole) {
        configurations[role] = configuration
        surfaces[role]?.apply(configuration: configuration)
    }

    func applyConfigurationJSON(_ json: String, for role: LyricsSurfaceRole) {
        let current = configurations[role]
        guard let configuration = NativeLyricsConfigurationMapper.fromJSON(
            json,
            role: role,
            fallback: current
        ) else { return }
        applyConfiguration(configuration, for: role)
    }

    func applyPalette(_ palette: ThemePalette, for role: LyricsSurfaceRole) {
        var configuration = configurations[role] ?? NativeLyricsConfigurationMapper.base(role: role)
        configuration.palette = NativeLyricsConfigurationMapper.paletteForWindow(palette)
        applyConfiguration(configuration, for: role)
    }

    func setRenderScale(_ scale: Double, for role: LyricsSurfaceRole) {
        var configuration = configurations[role] ?? NativeLyricsConfigurationMapper.base(role: role)
        configuration.renderScale = max(0.35, min(1, scale))
        applyConfiguration(configuration, for: role)
    }

    func applyTheme(_ palette: ThemePalette) {
        let roles = Set(configurations.keys).union(surfaces.keys)
        for role in roles {
            var configuration = configurations[role] ?? NativeLyricsConfigurationMapper.base(role: role)
            configuration.palette = NativeLyricsConfigurationMapper.paletteForWindow(palette)
            applyConfiguration(configuration, for: role)
        }
    }

    func configuration(for role: LyricsSurfaceRole) -> LyricsConfiguration? {
        configurations[role]
    }

    func followCurrentLyrics(for role: LyricsSurfaceRole) {
        surfaces[role]?.followCurrentLyrics()
    }

    func setSeekHandler(_ handler: ((Double) -> Void)?, for role: LyricsSurfaceRole) {
        seekHandlers[role] = handler
        surfaces[role]?.onSeek = handler
    }

    func shutdownAll() {
        surfaces.values.forEach { $0.shutdown() }
        surfaces.removeAll()
        configurations.removeAll()
        seekHandlers.removeAll()
        activeRoles.removeAll()
        snapshot = PlaybackSnapshot()
    }
}

/// SwiftUI/AppKit bridge for a package-owned layer-backed LyricsView.
struct NativeLyricsViewRepresentable: NSViewRepresentable {
    let surface: NativeLyricsSurface

    func makeNSView(context: Context) -> LyricsView {
        surface.view
    }

    func updateNSView(_ nsView: LyricsView, context: Context) {
        guard nsView !== surface.view else { return }
        // A representable must never silently steal a view from another role.
        // Each surface is single-owner; this branch is only defensive for a
        // malformed host and deliberately does not reparent.
    }

    static func dismantleNSView(_ nsView: LyricsView, coordinator: ()) {}
}

extension NativeLyricsSurfaceManager {
    /// Converts the app's CSS color payload into package-native colors.
    /// ThemeStore uses both compact `rgb(...)` strings and the wide-gamut
    /// `{srgb, displayP3}` payload used by fullscreen skins.
    static func color(_ value: Any?, fallback: LyricsColor) -> LyricsColor {
        if let values = value as? [String: String] {
            if let p3 = values["displayP3"], let color = parseCSSColor(p3, preferDisplayP3: true) {
                return color
            }
            if let srgb = values["srgb"], let color = parseCSSColor(srgb, preferDisplayP3: false) {
                return color
            }
        }
        if let values = value as? [String: Any] {
            if let p3 = values["displayP3"] as? String,
               let color = parseCSSColor(p3, preferDisplayP3: true) {
                return color
            }
            if let srgb = values["srgb"] as? String,
               let color = parseCSSColor(srgb, preferDisplayP3: false) {
                return color
            }
        }
        if let string = value as? String, let color = parseCSSColor(string, preferDisplayP3: false) {
            return color
        }
        return fallback
    }

    private static func parseCSSColor(_ value: String, preferDisplayP3: Bool) -> LyricsColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("#") {
            let hex = String(lower.dropFirst())
            guard hex.count == 6 || hex.count == 8, let raw = UInt64(hex, radix: 16) else { return nil }
            let r = Double((raw >> (hex.count == 8 ? 24 : 16)) & 0xff) / 255
            let g = Double((raw >> (hex.count == 8 ? 16 : 8)) & 0xff) / 255
            let b = Double((raw >> (hex.count == 8 ? 8 : 0)) & 0xff) / 255
            let a = hex.count == 8 ? Double(raw & 0xff) / 255 : 1
            return LyricsColor(r, g, b, alpha: a, displayP3: preferDisplayP3)
        }

        let isP3 = lower.contains("display-p3")
        let isRGB = lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") || isP3
        guard isRGB else { return nil }
        let body = trimmed
            .replacingOccurrences(of: "color(display-p3", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "rgba(", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "rgb(", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "/", with: " / ")
            .replacingOccurrences(of: ",", with: " ")
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard tokens.count >= 3,
              var r = cssComponent(tokens[0]),
              var g = cssComponent(tokens[1]),
              var b = cssComponent(tokens[2])
        else { return nil }
        if !isP3 && max(r, g, b) > 1 { r /= 255; g /= 255; b /= 255 }
        let alphaIndex = tokens.firstIndex(of: "/").map { $0 + 1 }
        let alpha = alphaIndex.flatMap { $0 < tokens.count ? cssComponent(tokens[$0]) : nil }
            ?? (tokens.count >= 4 ? cssComponent(tokens[3]) : nil)
            ?? 1
        return LyricsColor(
            max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)),
            alpha: max(0, min(1, alpha)),
            displayP3: isP3 || preferDisplayP3
        )
    }

    private static func cssComponent(_ token: String) -> Double? {
        if token.hasSuffix("%"), let value = Double(token.dropLast()) { return value / 100 }
        return Double(token)
    }

    static func springParameters(from settings: LyricSpringUserSettings) -> SpringParameters? {
        guard settings.enabled else { return nil }
        let duration = max(
            AppSettings.lyricSpringDurationRange.lowerBound,
            min(AppSettings.lyricSpringDurationRange.upperBound, settings.duration)
        )
        let bounce = max(
            AppSettings.lyricSpringBounceRange.lowerBound,
            min(AppSettings.lyricSpringBounceRange.upperBound, settings.bounce)
        )
        return .positionOverride(
            duration: duration,
            bounce: bounce
        )
    }
}
