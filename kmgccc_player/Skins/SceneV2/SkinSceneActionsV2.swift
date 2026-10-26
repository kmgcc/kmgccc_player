import SwiftUI

enum SkinSceneActionRunner {
    static func run(_ commands: [SkinCompiledAction], context: SkinEvaluationContext, actions: SkinSceneActions) {
        for command in commands {
            guard command.condition?.evaluate(context).isTruthy != false else { continue }
            let value = command.value?.evaluate(context) ?? .null
            let p = context.data.playback
            switch command.name {
            case "playPause": if p["playback.canControl"]?.isTruthy == true { actions.playPause() }
            case "play": if p["playback.canControl"]?.isTruthy == true { actions.play() }
            case "pause": if p["playback.canControl"]?.isTruthy == true { actions.pause() }
            case "stop": if p["playback.canControl"]?.isTruthy == true { actions.stop() }
            case "previous": if p["playback.canControl"]?.isTruthy == true { actions.previous() }
            case "next": if p["playback.canControl"]?.isTruthy == true { actions.next() }
            case "seek": if p["playback.canSeek"]?.isTruthy == true { actions.seek(max(0, value.number())) }
            case "seekAndResume": if p["playback.canSeek"]?.isTruthy == true { actions.seekAndResume(max(0, value.number())) }
            case "seekBy": if p["playback.canSeek"]?.isTruthy == true { actions.seek(max(0, context.data.clock.position(at: context.now) + value.number())) }
            case "seekToLyric":
                let line = context.data.lyricsTimeline.lines
                let index = value.integer()
                if line.indices.contains(index), p["playback.canSeek"]?.isTruthy == true {
                    actions.seek(line[index][member: "start"].number() + context.data.clock.seekOffset)
                }
            case "setVolume": if p["playback.canSetVolume"]?.isTruthy == true { actions.setVolume(value.number().clamped01) }
            case "setOrderMode": if p["playback.canSetOrderMode"]?.isTruthy == true, let mode = PlaybackOrderMode(rawValue: value.textValue) { actions.setPlaybackOrder(mode) }
            case "setAppleMusicMode": if p["playback.canSetOrderMode"]?.isTruthy == true, let mode = AppleMusicPlaybackMode(rawValue: value.textValue) { actions.setExternalPlaybackOrder(mode) }
            case "toggleLike": actions.like()
            case "toggleDislike": actions.toggleDislike()
            case "setLike": if let state = ManualLikeState(rawValue: value.textValue) { actions.setLikeState(state) }
            case "playlist.add": if let id = UUID(uuidString: value.textValue) { actions.addToPlaylist(id) }
            case "playlist.new": actions.addToPlaylist(nil)
            case "track.delete": actions.deleteTrack()
            case "musicInfo.open": actions.openMusicInfo()
            case "artist.show": actions.showArtist()
            case "album.show": actions.showAlbum()
            case "output.select": actions.selectOutput(value.textValue.isEmpty ? nil : value.textValue)
            case "queue.toggle": actions.toggleQueue()
            case "queue.show": if context.data.host["host.queueVisible"]?.isTruthy != true { actions.toggleQueue() }
            case "queue.hide": if context.data.host["host.queueVisible"]?.isTruthy == true { actions.toggleQueue() }
            case "queue.play": actions.playQueueIndex(value.integer())
            case "lyrics.toggle": actions.toggleLyrics()
            case "lyrics.show": if context.data.host["host.lyricsVisible"]?.isTruthy != true { actions.toggleLyrics() }
            case "lyrics.hide": if context.data.host["host.lyricsVisible"]?.isTruthy == true { actions.toggleLyrics() }
            case "fullscreen.enter": actions.enterFullscreen()
            case "fullscreen.exit": actions.exit()
            case "fullscreen.toggle": context.data.viewport["viewport.isFullscreen"]?.isTruthy == true ? actions.exit() : actions.enterFullscreen()
            case "quickPanel.open": actions.openQuickPanel()
            case "settings.open": actions.openSettings()
            case "trackDetail.open": actions.openTrackDetail()
            case "trackEdit.open": actions.openTrackEdit()
            case "externalInfo.open": actions.openExternalInfo()
            case "skin.reload": actions.reload()
            case "skin.restore": actions.restore()
            case "state.set": if let key = command.key { context.data.setState(key, value) }
            case "state.toggle": if let key = command.key { context.data.setState(key, .boolean(!context.data.stateValue(key).isTruthy)) }
            case "state.reset": context.data.resetState(context.data.initialState)
            case "params.set": if let key = command.key { actions.setParameter(key, value.parameterValue) }
            default: break
            }
        }
    }
}

struct SkinSceneEventModifier: ViewModifier {
    let program: SkinSceneProgram
    let data: SkinSceneData
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneIsActive) private var active
    func body(content: Content) -> some View {
        content
            .onChange(of: data.track["track.id"], initial: false) { _, _ in emit("trackChange") }
            .onChange(of: data.artwork["artwork.identity"]) { _, _ in emit("artworkChange") }
            .onChange(of: data.artwork["artwork.hasMotion"]) { _, _ in emit("motionArtworkReady") }
            .onChange(of: data.playback["playback.isPlaying"]) { _, playing in emit(playing?.isTruthy == true ? "playbackStart" : "playbackPause") }
            .onChange(of: data.playback["playback.volume"]) { _, _ in emit("volumeChange") }
            .onChange(of: data.playback["playback.orderMode"]) { _, _ in emit("orderChange") }
            .onChange(of: data.seekRevision) { _, _ in emit("seek") }
            .onChange(of: data.lyrics["lyrics.revision"]) { _, _ in emit("lyricsChange") }
            .onChange(of: data.host["host.lyricsVisible"]) { _, _ in emit("lyricsVisibilityChange") }
            .onChange(of: data.viewport["viewport.fullscreenHost"]) { _, _ in emit("fullscreenHostChange") }
            .onChange(of: data.audioAvailability) { _, _ in emit("audioAvailabilityChange") }
            .onChange(of: data.theme) { _, _ in emit("themeChange") }
            .onChange(of: data.viewport) { _, _ in emit("viewportChange") }
            .onChange(of: active) { _, _ in emit("visibilityChange") }
            .background {
                if ["lyricLineChange", "interludeStart", "interludeEnd"].contains(where: { program.events[$0] != nil }) {
                    // Lyric position stands still while paused; seeks re-render this view anyway.
                    TimelineView(.animation(minimumInterval: nil, paused: !active || !data.clock.isPlaying)) { timeline in
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let time = data.clock.lyricsTime(at: now)
                        Color.clear
                            .onChange(of: data.lyricsTimeline.currentIndex(at: time)) { _, _ in emit("lyricLineChange") }
                            .onChange(of: data.lyricsTimeline.value("lyrics.isInterlude", time: time).isTruthy) { _, value in emit(value ? "interludeStart" : "interludeEnd") }
                    }.allowsHitTesting(false)
                }
            }
    }
    private func emit(_ name: String) {
        guard active || name == "visibilityChange" else { return }
        SkinSceneActionRunner.run(program.events[name] ?? [], context: SkinEvaluationContext(data: data), actions: actions)
    }
}
