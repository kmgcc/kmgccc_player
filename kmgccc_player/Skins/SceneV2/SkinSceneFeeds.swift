import AppKit
import CoreAudio
import MelismaKit
import MotionKit
import SwiftUI

/// A scene-scoped adapter. The application services remain the owners of all facts.
struct SkinSceneFeeds: View {
    let data: SkinSceneData
    let program: SkinSceneProgram
    let snapshot: SkinSceneSnapshot
    let viewport: SkinViewport
    let parameters: [String: SkinParameterValue]
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LEDMeterServiceProvider.self) private var meter
    @Environment(PlayerViewModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var library
    @Environment(UIStateViewModel.self) private var ui
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(\.skinScenePresentation) private var presentation

    var body: some View {
        let domains = values
        Color.clear
            .onChange(of: domains, initial: true) { _, next in
                for (domain, values) in next { data.set(domain, values) }
                data.freezesTime = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion) != .full
            }
            .onChange(of: audioKey, initial: true) { _, _ in updateAudio() }
            .onChange(of: NativeLyricsSurfaceManager.shared.documentPublication.revision, initial: true) { _, _ in updateLyrics() }
            .onDisappear { data.audio.stop() }
            .overlay { SkinSceneClockFeed(data: data, role: viewport.surface == .window ? .main : .fullscreen) }
            .background { SkinSceneHostProbe(data: data) }
            .allowsHitTesting(false)
    }

    private var audioKey: String { "\(active)|\(snapshot.playback.isPlaying)|\(playback.stablePresentation.source)|\(data.audioReaders.isEmpty)" }

    private func updateAudio() {
        data.audio.update(provider: meter, source: playback.stablePresentation.source,
                          active: active && !data.audioReaders.isEmpty, isPlaying: snapshot.playback.isPlaying, usesLED: true)
        data.audioAvailability = data.audio.availability.rawValue
    }

    private func updateLyrics() {
        guard program.domains.contains(.lyrics) || program.domains.contains(.lyricsTimeline) else { return }
        let manager = NativeLyricsSurfaceManager.shared
        let document = manager.documentForConsumers()
        let config = manager.configurationForConsumers(role: viewport.surface == .window ? .main : .fullscreen)
        data.lyricsTimeline.load(document, timing: config.timing)
        data.set(.lyrics, [
            "lyrics.available": .boolean(document != nil), "lyrics.availability": .text(document == nil ? "unavailable" : "available"),
            "lyrics.revision": .number(Double(manager.documentPublication.revision)),
            "lyrics.lineCount": .number(Double(data.lyricsTimeline.lines.count)), "lyrics.lines": .list(data.lyricsTimeline.lines),
            "lyrics.sourceTTML": .text(manager.currentTTML), "lyrics.title": .text(snapshot.track?.title ?? ""),
            "lyrics.duration": .number(playback.stablePresentation.duration),
            "lyrics.isWordTimed": .boolean(data.lyricsTimeline.lines.contains { $0[member: "isWordTimed"].isTruthy }),
            "lyrics.hasDuet": .boolean(data.lyricsTimeline.lines.contains { $0[member: "isDuet"].isTruthy }),
            "lyrics.timingMode": .text(config.lineTimingOnly ? "line" : "word"),
            "lyrics.prefs.showTranslation": .boolean(config.showTranslation), "lyrics.prefs.showRomanization": .boolean(config.showRomanization),
            "lyrics.prefs.showRuby": .boolean(config.showRuby), "lyrics.prefs.fontSize": .number(config.fontSize),
            "lyrics.prefs.fontFamily": .text(config.fontName), "lyrics.prefs.translationFontSize": .number(config.translationFontSize ?? config.fontSize * 0.5),
            "lyrics.prefs.translationLanguage": .text(config.translationLanguage), "lyrics.prefs.romanizationLanguage": .text(config.romanizationLanguage),
            "lyrics.prefs.obscenity": .text(config.obscenity.rawValue),
            "lyrics.metadata": .record(document?.metadata.mapValues { .list($0.map(SkinValue.text)) } ?? [:]),
        ])
    }

    private var values: [SkinDataDomain: [String: SkinValue]] {
        let p = playback.stablePresentation
        let track = snapshot.track
        var result: [SkinDataDomain: [String: SkinValue]] = [:]
        result[.params] = parameters.mapValues(SkinValue.init)
        result[.track] = [
            "track.hasTrack": .boolean(p.hasTrack), "track.id": .text(track?.id.uuidString ?? p.externalStableKey ?? ""),
            "track.title": .text(p.title), "track.artist": .text(p.artist), "track.album": .text(p.album ?? ""),
            "track.duration": .number(p.duration), "track.source": .text(String(describing: p.source)), "track.emptyTitleKey": .text(p.emptyTitleKey),
            "track.external.rawTitle": .text(p.externalRawTitle ?? ""), "track.external.rawArtist": .text(p.externalRawArtist ?? ""),
            "track.external.rawAlbum": .text(p.externalRawAlbum ?? ""), "track.external.effectiveTitle": .text(p.externalEffectiveTitle ?? ""),
            "track.external.effectiveArtist": .text(p.externalEffectiveArtist ?? ""), "track.external.effectiveAlbum": .text(p.externalEffectiveAlbum ?? ""),
            "track.external.usesOverride": .boolean(p.externalUsesOverride), "track.external.matchConfidence": .number(p.externalMatchConfidence ?? 0),
            "track.external.connectionState": .text(p.externalConnectionState?.rawValue ?? ""),
            "track.external.lyricsStatusMessage": .text(p.externalLyricsStatusMessage ?? ""),
            "track.external.lyricsTimeOffset": .number((p.externalLyricsTimeOffsetMs ?? 0) / 1000),
            "track.metadataSources": .record(p.metadataSources.mapValues { .text($0) }),
            "track.hasMusicInfo": .boolean(p.musicEnrichment != nil),
            "track.audio": Self.audioProperties(p.localTrack?.audioProperties),
        ]
        let size = track?.artworkImage?.size ?? .zero
        result[.artwork] = [
            "artwork.available": .boolean(track?.artworkImage != nil), "artwork.identity": .text(p.artworkIdentity ?? ""),
            "artwork.checksum": .number(Double(track?.artworkChecksum ?? 0)), "artwork.isLoading": .boolean(p.isArtworkLoading),
            "artwork.width": .number(size.width), "artwork.height": .number(size.height), "artwork.aspectRatio": .number(size.width / max(1, size.height)),
            "artwork.hasMotion": .boolean(p.motionArtwork != nil), "artwork.hasTallMotion": .boolean(p.tallMotionArtwork != nil),
            "artwork.averageColor": .color(OKLCHColor(snapshot.theme.artworkAverageColor ?? .black)),
            "artwork.palette": .list(snapshot.theme.artworkPalette.map { .color(OKLCHColor($0)) }),
        ]
        result[.playback] = [
            "playback.isPlaying": .boolean(p.isPlaying), "playback.volume": .number(p.volume), "playback.duration": .number(p.duration),
            "playback.orderMode": .text(p.localPlaybackOrderMode?.rawValue ?? ""), "playback.appleMusicMode": .text(p.appleMusicPlaybackMode?.rawValue ?? ""),
            "playback.isLocal": .boolean(p.source == .local), "playback.canControl": .boolean(p.isControlEnabled),
            "playback.canSeek": .boolean(p.isSeekEnabled), "playback.canSetVolume": .boolean(p.isVolumeControlEnabled),
            "playback.canSetOrderMode": .boolean(p.isPlaybackModeControlEnabled), "playback.hasTrack": .boolean(p.hasTrack),
            "playback.audioOutputDelay": .number(p.audioOutputDelay),
        ]
        var colors = Dictionary(uniqueKeysWithValues: SkinThemeRoles.colorRoles.map { ($0.path, SkinValue.color(OKLCHColor($0.read(theme.semanticPalette)))) })
        colors["theme.scheme"] = .text(theme.colorScheme == .dark ? "dark" : "light")
        colors["theme.isDark"] = .boolean(theme.colorScheme == .dark)
        colors["theme.accent"] = .color(OKLCHColor(theme.accentNSColor))
        colors["theme.hasArtworkColor"] = .boolean(theme.hasArtworkThemeColor)
        colors["theme.palette"] = .list(snapshot.theme.artworkPalette.map { .color(OKLCHColor($0)) })
        colors["theme.averageColor"] = .color(OKLCHColor(snapshot.theme.artworkAverageColor ?? .black))
        colors["theme.spectrumColors"] = .list(snapshot.theme.spectrumArtworkColors.map { .color(OKLCHColor($0)) })
        colors["theme.spectrumUsesDarkForeground"] = .boolean(snapshot.theme.spectrumUsesDarkForeground)
        colors["theme.artBackgroundIsUltraDark"] = .boolean(snapshot.theme.artBackgroundIsUltraDark)
        colors["theme.roles"] = Self.paletteRoles(theme.semanticPalette)
        for strategy in SkinThemeRoles.foregroundStrategies {
            let foreground = FullscreenMiniPlayerForegroundStrategy.resolve(palette: theme.semanticPalette, localArtworkPolarity: nil,
                hasArtworkThemeColor: theme.hasArtworkThemeColor, controlForeground: strategy, colorScheme: theme.colorScheme,
                materialStyle: .normal, fullscreenArtBackgroundEnabled: settings.fullscreenArtBackgroundEnabled)
            let prefix = "theme.controlForeground.\(strategy.rawValue)."
            colors[prefix + "primary"] = .color(OKLCHColor(foreground.primary))
            colors[prefix + "secondary"] = .color(OKLCHColor(foreground.secondary))
            colors[prefix + "disabled"] = .color(OKLCHColor(foreground.disabled))
            colors[prefix + "pillTint"] = .color(OKLCHColor(foreground.pillTint))
        }
        colors["theme.readability.usesDarkForeground"] = .boolean(theme.semanticPalette.readabilityProfile.usesDarkForeground)
        do {
            let analysis = theme.analysis
            for field in SkinThemeRoles.analysisFields { colors[field.path] = field.read(analysis) }
            colors["theme.readability.isNearMonochrome"] = .boolean(analysis.isNearMonochrome)
        }
        result[.theme] = colors
        result[.viewport] = [
            "viewport.width": .number(viewport.size.width), "viewport.height": .number(viewport.size.height),
            "viewport.w": .number(viewport.size.width), "viewport.h": .number(viewport.size.height),
            "viewport.min": .number(min(viewport.size.width, viewport.size.height)), "viewport.max": .number(max(viewport.size.width, viewport.size.height)),
            "viewport.aspect": .number(viewport.size.width / max(1, viewport.size.height)), "viewport.displayScale": .number(displayScale),
            "viewport.maximumRefreshRate": .number(Double(NSScreen.main?.maximumFramesPerSecond ?? 60)),
            "viewport.surface": .text(viewport.surface.rawValue), "viewport.fullscreenHost": .text(String(describing: viewport.fullscreenHost)),
            "viewport.isFullscreen": .boolean(viewport.surface == .fullscreen), "viewport.isDark": .boolean(theme.colorScheme == .dark),
            "viewport.colorScheme": .text(theme.colorScheme == .dark ? "dark" : "light"),
            "viewport.reduceMotion": .boolean(reduceMotion), "viewport.reduceTransparency": .boolean(reduceTransparency),
            "viewport.increaseContrast": .boolean(contrast == .increased), "viewport.safeArea": .record([:]),
            "motion.speed": .number(MotionTokens.standard.emphasis.duration / max(0.001, motionTokens.emphasis.duration)),
        ]
        for token in MotionToken.allCases { result[.viewport]?["motion.\(token.rawValue)"] = .number(motionTokens[token].duration) }
        let layout = SkinHostLayout.frames(size: viewport.size, surface: viewport.surface,
                                           lyricsVisible: lyricsVisible, presentation: presentation)
        result[.host] = ["host.isActive": .boolean(active), "host.lyricsVisible": .boolean(lyricsVisible),
                         "host.queueVisible": .boolean(ui.isWindowPlaybackQueueVisible),
                         "host.layout": SkinHostLayout.value(layout)]
        let fullscreen = viewport.surface == .fullscreen
        result[.prefs] = ["prefs.fullscreenDimming": .number(settings.fullscreenDimmingIntensity),
                          "prefs.artBackgroundEnabled": .boolean(fullscreen ? settings.fullscreenArtBackgroundEnabled : settings.nowPlayingArtBackgroundEnabled),
                          "prefs.artworkScale": .number(fullscreen ? settings.fullscreenArtworkScale : 1),
                          "prefs.miniPlayerAutoHide": .number(fullscreen ? settings.fullscreenMiniPlayerAutoHideSeconds : 0),
                          "prefs.lyricsRenderQuality": .text(String(settings.amllLyricsRenderQualityScale)),
                          "prefs.miniPlayerGlass": .text(settings.fullscreenMiniPlayerGlassMaterial == .normal ? "normal" : "clear"),
                          "prefs.cassetteKmgLook": .boolean(UserDefaults.standard.bool(forKey: "skin.kmgcccCassette.showKmgLook"))]
        // Preference writes surface through the library refresh trigger.
        let _ = library.refreshTrigger
        let likeState = p.localTrack.map { library.preferenceStats(for: $0.id).manualLikeState } ?? ManualLikeState.none
        result[.like] = ["like.available": .boolean(p.localTrack != nil),
                         "like.isLiked": .boolean(likeState == .liked), "like.isDisliked": .boolean(likeState == .disliked),
                         "like.state": .text(likeState.rawValue)]
        result[.library] = ["library.playlists": .list(library.playlists.map { .record(["id": .text($0.id.uuidString), "name": .text($0.name)]) }),
                            "library.canEditTrack": .boolean(p.localTrack != nil)]
        let route = AudioDSPDeviceController.current
        let current = route?.currentDevice
        result[.output] = ["output.name": .text(current?.name ?? ""), "output.symbol": .text(current?.symbolName ?? "hifispeaker"),
                           "output.isBluetooth": .boolean(current.map { $0.transportType == kAudioDeviceTransportTypeBluetooth || $0.transportType == kAudioDeviceTransportTypeBluetoothLE } ?? false),
                           "output.followsSystem": .boolean(settings.audioOutputDeviceUID == nil),
                           "output.devices": .list((route?.devices ?? []).map { device in
                               .record(["id": .text(device.uid), "name": .text(device.name), "symbol": .text(device.symbolName),
                                        "isCurrent": .boolean(device.id == current?.id)])
                           })]
        if program.domains.contains(.queue) {
            let tracks = player.currentQueueTracks
            let currentID = player.currentTrack?.id
            let order = p.localPlaybackOrderMode ?? settings.playbackOrderMode
            result[.queue] = ["queue.count": .number(Double(tracks.count)),
                              "queue.position": .number(Double(player.currentQueueDisplayIndex ?? -1)),
                              "queue.upNext": .list(tracks.prefix(32).map { .record(["id": .text($0.id.uuidString), "title": .text($0.title), "artist": .text($0.artist)]) }),
                              "queue.available": .boolean(p.source == .local),
                              "queue.currentIndex": .number(Double(tracks.firstIndex { $0.id == currentID } ?? -1)),
                              "queue.title": .text(order == .shuffle ? "随机队列" : order == .repeatOne ? "单曲循环队列" : order == .stopAfterTrack ? "当前队列" : "播放列表"),
                              "queue.items": .list(tracks.prefix(1024).enumerated().map { index, track in
                                  .record(["id": .text(track.id.uuidString), "index": .number(Double(index)), "title": .text(track.title),
                                           "artist": .text(track.artist), "album": .text(track.album), "duration": .number(track.duration),
                                           "isCurrent": .boolean(track.id == currentID)])
                              })]
        }
        return result.filter { program.domains.contains($0.key) || $0.key == .params || $0.key == .viewport || $0.key == .host }
    }

    /// Lossless follows the codec (or container when the codec is unknown); hi-res is lossless
    /// above 48 kHz or at 24 bits and more.
    private static func audioProperties(_ properties: TrackAudioProperties?) -> SkinValue {
        guard let properties else { return .record([:]) }
        let codec = (properties.codec ?? properties.format ?? "").lowercased()
        let lossless = ["alac", "flac", "pcm", "lpcm", "wav", "wave", "aif", "aiff", "ape", "wavpack", "wv", "dsd", "dsf", "dff"]
            .contains { codec.contains($0) }
        let hiRes = lossless && ((properties.sampleRateHz ?? 0) > 48_000 || (properties.bitDepth ?? 0) >= 24)
        return .record([
            "format": .text(properties.format ?? ""), "codec": .text(properties.codec ?? ""),
            "bitrate": .number(Double(properties.bitrateKbps ?? 0)), "sampleRate": .number(Double(properties.sampleRateHz ?? 0)),
            "bitDepth": .number(Double(properties.bitDepth ?? 0)), "channels": .number(Double(properties.channelCount ?? 0)),
            "isLossless": .boolean(lossless), "isHiRes": .boolean(hiRes),
        ])
    }

    /// Preserve the palette's complete stored hierarchy, including future nested roles.
    private static func paletteRoles(_ value: Any) -> SkinValue {
        if let color = value as? NSColor { return .color(OKLCHColor(color)) }
        if let value = value as? Bool { return .boolean(value) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? Float { return .number(Double(value)) }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .struct else { return .null }
        var result: [String: SkinValue] = [:]
        for child in mirror.children {
            guard let name = child.label, name != "analysis" else { continue }
            let role = paletteRoles(child.value)
            if role != .null { result[name] = role }
        }
        return .record(result)
    }
}

/// Clock ticks only invalidate this invisible leaf, never the scene root or static siblings.
private struct SkinSceneClockFeed: View {
    let data: SkinSceneData
    let role: LyricsSurfaceRole
    @Environment(PlaybackCoordinator.self) private var playback
    var body: some View {
        let p = playback.presentation
        let key = [p.currentTime, p.lyricsCurrentTime, p.isPlaying ? 1 : 0, p.duration]
        Color.clear.onChange(of: key, initial: true) { _, _ in
            let manager = NativeLyricsSurfaceManager.shared
            let config = manager.configurationForConsumers(role: role)
            if data.clock.duration > 0, abs(data.clock.position(at: Date.timeIntervalSinceReferenceDate) - p.currentTime) > 0.5 { data.seekRevision &+= 1 }
            data.clock.lyricsOffset = p.currentTime - p.lyricsCurrentTime + config.timing.trackOffset
            data.clock.seekOffset = config.timing.seekOffset
            data.clock.updateLyrics(position: p.lyricsCurrentTime - config.timing.trackOffset, isPlaying: p.lyricsIsPlaying ?? p.isPlaying, now: Date.timeIntervalSinceReferenceDate)
            data.clock.update(position: p.currentTime, isPlaying: p.isPlaying, duration: p.duration, now: Date.timeIntervalSinceReferenceDate)
        }
    }
}
