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
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    private var pendingClickSeek = false

    init(role: LyricsSurfaceRole) {
        self.role = role
        self.view = LyricsView(frame: .zero)
        super.init()

        view.onSeek = { [weak self] seconds in
            guard let self else { return }
            self.pendingClickSeek = true
            self.onSeek?(seconds)
        }
    }

    var isReady: Bool { true }

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
        let text = ttml ?? ""
        let shouldReload = forceLyricsReload || trackID != lastTrackID || text != lastTTML
        self.currentTime = currentTime.isFinite ? max(0, currentTime) : 0
        self.isPlaying = isPlaying
        guard shouldReload else {
            synchronize(time: self.currentTime, playing: isPlaying)
            return
        }

        do {
            try view.load(
                ttml: Data(text.utf8),
                time: self.currentTime,
                playing: isPlaying
            )
            lastError = nil
            lastTTML = text
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
        currentTime = max(0, time)
        isPlaying = playing
        let clickSeek = pendingClickSeek
        pendingClickSeek = false
        view.synchronize(
            time: currentTime,
            playing: playing,
            seek: seek || clickSeek,
            motion: clickSeek ? .cascade : motion
        )
    }

    func setCurrentTime(_ time: Double, force: Bool = false) {
        guard time.isFinite else { return }
        guard force || abs(time - currentTime) >= 0.001 || pendingClickSeek else { return }
        synchronize(time: time, playing: isPlaying)
    }

    func setPlaying(_ playing: Bool, force: Bool = false) {
        guard force || playing != isPlaying else { return }
        synchronize(time: currentTime, playing: playing)
    }

    func followCurrentLyrics() {
        view.followCurrentLyrics()
    }

    func setPointerInside(_ inside: Bool) {
        view.setPointerInside(inside)
    }

    func setMouseInteractionSuppressed(_ suppressed: Bool) {
        // Native surfaces do not need a JavaScript pointer gate. Suppression
        // still has the same visible contract: a covered surface loses hover
        // state and returns to its normal blurred presentation.
        if suppressed { view.setPointerInside(false) }
    }

    func releaseRenderingResources() {
        view.releaseRenderingResources()
    }

    func shutdown() {
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
    private var activeRoles: Set<LyricsSurfaceRole> = []
    private var snapshot = PlaybackSnapshot()

    private init() {}

    func surface(for role: LyricsSurfaceRole) -> NativeLyricsSurface {
        if let surface = surfaces[role] { return surface }
        let surface = NativeLyricsSurface(role: role)
        if let configuration = configurations[role] {
            surface.apply(configuration: configuration)
        }
        if !snapshot.ttml.isEmpty || snapshot.trackID != nil {
            surface.applyTrack(
                trackID: snapshot.trackID,
                ttml: snapshot.ttml,
                currentTime: snapshot.time,
                isPlaying: snapshot.playing,
                forceLyricsReload: true
            )
        }
        surfaces[role] = surface
        return surface
    }

    func existingSurface(for role: LyricsSurfaceRole) -> NativeLyricsSurface? {
        surfaces[role]
    }

    func activate(role: LyricsSurfaceRole) {
        activeRoles.insert(role)
        _ = surface(for: role)
    }

    func deactivate(role: LyricsSurfaceRole) {
        activeRoles.remove(role)
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
        isPlaying: Bool
    ) {
        snapshot = PlaybackSnapshot(
            trackID: trackID,
            ttml: lyricsTTML,
            time: currentTime.isFinite ? max(0, currentTime) : 0,
            playing: isPlaying
        )
        for surface in surfaces.values {
            surface.applyTrack(
                trackID: trackID,
                ttml: lyricsTTML,
                currentTime: snapshot.time,
                isPlaying: isPlaying
            )
        }
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
        for surface in surfaces.values {
            surface.applyTrack(
                trackID: trackID,
                ttml: ttml,
                currentTime: snapshot.time,
                isPlaying: isPlaying,
                forceLyricsReload: forceLyricsReload
            )
        }
    }

    func updatePlaybackTime(_ time: Double) {
        guard time.isFinite else { return }
        snapshot.time = max(0, time)
        for surface in surfaces.values { surface.setCurrentTime(snapshot.time) }
    }

    func updatePlayingState(_ playing: Bool) {
        snapshot.playing = playing
        for surface in surfaces.values { surface.setPlaying(playing) }
    }

    func applyConfiguration(_ configuration: LyricsConfiguration, for role: LyricsSurfaceRole) {
        configurations[role] = configuration
        surface(for: role).apply(configuration: configuration)
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

    func applyTheme(_ palette: ThemePalette) {
        for role in configurations.keys {
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

    func shutdownAll() {
        surfaces.values.forEach { $0.shutdown() }
        surfaces.removeAll()
        configurations.removeAll()
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
        var body = trimmed
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
        let duration = max(0.1, min(1.6, settings.duration))
        let bounce = max(-0.8, min(0.8, settings.bounce))
        // Convert the existing duration/bounce controls to a damped system.
        // The native solver preserves velocity and delay; only these two user
        // controls are mapped here, keeping the package API independent.
        let stiffness = 110 / max(0.35, duration)
        let damping = 18 * (1 - bounce * 0.35)
        return SpringParameters(mass: 1, damping: damping, stiffness: stiffness, soft: bounce <= 0)
    }
}
