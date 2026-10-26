import AppKit
import MelismaKit
import Observation
import SwiftUI

/// The live data a v2 scene reads. Each domain is one observed dictionary, so a node that
/// reads `track.title` re-renders when the track changes and never when the theme changes.
/// Per-frame sources (clock, audio, lyric position, pointer idle time) are not observed: only
/// nodes inside a display timeline read them, with the frame's own timestamp.
@Observable
@MainActor
final class SkinSceneData {
    static let placeholder = SkinSceneData()

    private(set) var track: [String: SkinValue] = [:]
    private(set) var artwork: [String: SkinValue] = [:]
    private(set) var playback: [String: SkinValue] = [:]
    private(set) var lyrics: [String: SkinValue] = [:]
    private(set) var theme: [String: SkinValue] = [:]
    private(set) var viewport: [String: SkinValue] = [:]
    private(set) var host: [String: SkinValue] = [:]
    private(set) var prefs: [String: SkinValue] = [:]
    private(set) var like: [String: SkinValue] = [:]
    private(set) var queue: [String: SkinValue] = [:]
    private(set) var library: [String: SkinValue] = [:]
    private(set) var output: [String: SkinValue] = [:]
    private(set) var parameters: [String: SkinValue] = [:]
    private(set) var state: [String: SkinValue] = [:]
    @ObservationIgnored var initialState: [String: SkinValue] = [:]
    var audioReaders: Set<String> = []
    var audioAvailability = "inactive"
    var seekRevision: UInt64 = 0

    @ObservationIgnored var clock = SkinPlaybackClock()
    @ObservationIgnored let audio = SkinSceneAudio()
    @ObservationIgnored let lyricsTimeline = SkinLyricsTimeline()
    @ObservationIgnored private(set) var startTime = Date.timeIntervalSinceReferenceDate
    @ObservationIgnored var pointerMovedAt = Date.timeIntervalSinceReferenceDate
    /// Reduced motion freezes the scene clock, so `spin()` and friends hold still.
    @ObservationIgnored var freezesTime = false
    @ObservationIgnored private(set) var viewportSize = CGSize(width: 1, height: 1)
    @ObservationIgnored private var hostFacts: [String: SkinValue] = ["host.pointerIdle": .boolean(false)]
    @ObservationIgnored private var viewportFacts: [String: SkinValue] = [:]
    @ObservationIgnored private var idleTimer: Timer?

    init() { pointerMoved() }

    /// `host.pointerIdle` changes only when the pointer stops or starts again, so a layer that
    /// hides with it stays off the display timeline; on the timeline it would rebuild its whole
    /// subtree every frame.
    func pointerMoved() {
        pointerMovedAt = Date.timeIntervalSinceReferenceDate
        updateHostFacts(["host.pointerIdle": .boolean(false)])
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHostFacts(["host.pointerIdle": .boolean(true)]) }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    // MARK: Writes from the feeds

    /// Bumped on every observable write, so a node can keep values that did not change
    /// between display frames. Clock, lyric timing and audio are read live and never cached.
    @ObservationIgnored private(set) var revision: UInt64 = 0
    func invalidate() { revision &+= 1 }

    func set(_ domain: SkinDataDomain, _ values: [String: SkinValue]) {
        revision &+= 1
        switch domain {
        case .track: if track != values { track = values }
        case .artwork: if artwork != values { artwork = values }
        case .playback: if playback != values { playback = values }
        case .lyrics: if lyrics != values { lyrics = values }
        case .theme: if theme != values { theme = values }
        case .viewport:
            let merged = values.merging(viewportFacts) { _, new in new }
            if viewport != merged { viewport = merged }
            viewportSize = CGSize(width: values["viewport.width"]?.number(1) ?? 1, height: values["viewport.height"]?.number(1) ?? 1)
        case .host:
            let merged = values.merging(hostFacts) { _, new in new }
            if host != merged { host = merged }
        case .prefs: if prefs != values { prefs = values }
        case .like: if like != values { like = values }
        case .queue: if queue != values { queue = values }
        case .library: if library != values { library = values }
        case .output: if output != values { output = values }
        case .params: if parameters != values { parameters = values }
        case .state: if state != values { state = values }
        case .clock, .lyricsTimeline, .audio, .time, .local: break
        }
    }

    // Unchanged facts are not written, so a host probe update does not re-render every reader.
    func updateHostFacts(_ values: [String: SkinValue]) {
        revision &+= 1
        hostFacts.merge(values) { _, new in new }
        if values.contains(where: { host[$0.key] != $0.value }) { host.merge(values) { _, new in new } }
    }
    func updateViewportFacts(_ values: [String: SkinValue]) {
        revision &+= 1
        viewportFacts.merge(values) { _, new in new }
        if values.contains(where: { viewport[$0.key] != $0.value }) { viewport.merge(values) { _, new in new } }
    }

    func setState(_ name: String, _ value: SkinValue) {
        guard state[name] != value else { return }
        revision &+= 1
        state[name] = value
    }

    func resetState(_ defaults: [String: SkinValue]) {
        revision &+= 1
        if state != defaults { state = defaults }
    }

    // MARK: Reads from expressions

    func parameter(_ name: String) -> SkinValue { parameters[name] ?? .null }
    func stateValue(_ name: String) -> SkinValue { state[name] ?? .null }

    func time(at now: Double) -> Double { freezesTime ? 0 : max(0, now - startTime) }

    func value(forKey key: String, domain: SkinDataDomain, now: Double) -> SkinValue {
        switch domain {
        case .track: return track[key] ?? .null
        case .artwork: return artwork[key] ?? .null
        case .playback: return playback[key] ?? .null
        case .lyrics: return lyrics[key] ?? .null
        case .theme: return theme[key] ?? .null
        case .viewport: return viewport[key] ?? .null
        case .prefs: return prefs[key] ?? .null
        case .like: return like[key] ?? .null
        case .queue: return queue[key] ?? .null
        case .library: return library[key] ?? .null
        case .output: return output[key] ?? .null
        case .params: return parameters[key] ?? .null
        case .state: return state[key] ?? .null
        case .time: return .number(time(at: now))
        case .host:
            switch key {
            case "host.pointerIdleTime": return .number(max(0, now - pointerMovedAt))
            default: return host[key] ?? .null
            }
        case .clock:
            let position = clock.position(at: now)
            switch key {
            case "clock.position": return .number(position)
            case "clock.progress": return .number(clock.duration > 0 ? (position / clock.duration).clamped01 : 0)
            case "clock.remaining": return .number(max(0, clock.duration - position))
            case "clock.rate": return .number(clock.isPlaying ? clock.rate : 0)
            case "clock.lyrics": return .number(clock.lyricsTime(at: now))
            default: return .null
            }
        case .lyricsTimeline:
            return lyricsTimeline.value(key, time: clock.lyricsTime(at: now))
        case .audio:
            return audio.value(key, now: now)
        case .local:
            return .null
        }
    }

    func spectrum(count: Int, lowHz: Double, highHz: Double, now: Double) -> [Double] {
        audio.spectrum(count: count, lowHz: lowHz, highHz: highHz, now: now)
    }

    func waveform(count: Int) -> [Double] { audio.waveform(count: count) }

    func band(lowHz: Double, highHz: Double, now: Double) -> Double {
        audio.band(lowHz: lowHz, highHz: highHz, now: now)
    }

    func lyricLine(relative offset: Int, now: Double) -> SkinValue {
        lyricsTimeline.line(relative: offset, time: clock.lyricsTime(at: now))
    }

    func lyricProgress(index: Int, now: Double) -> Double {
        lyricsTimeline.progress(index: index, time: clock.lyricsTime(at: now))
    }
}

/// Playback position extrapolated from the coordinator's presentation updates.
struct SkinPlaybackClock {
    var position: Double = 0
    var anchor: Double = Date.timeIntervalSinceReferenceDate
    var isPlaying = false
    var duration: Double = 0
    var rate: Double = 1
    /// Seconds to subtract from the playback position to reach lyric document time.
    var lyricsOffset: Double = 0
    var seekOffset: Double = 0
    private var lyricsPosition: Double?
    private var lyricsAnchor: Double = 0
    private var lyricsPlaying = false

    func position(at now: Double) -> Double {
        let raw = isPlaying ? position + max(0, now - anchor) * rate : position
        return duration > 0 ? min(duration, max(0, raw)) : max(0, raw)
    }

    func lyricsTime(at now: Double) -> Double {
        guard let lyricsPosition else { return position(at: now) - lyricsOffset }
        return lyricsPosition + (lyricsPlaying ? max(0, now - lyricsAnchor) * rate : 0)
    }

    mutating func updateLyrics(position: Double, isPlaying: Bool, now: Double) {
        if lyricsPosition == nil || isPlaying != lyricsPlaying || abs(lyricsTime(at: now) - position) > 0.2 {
            lyricsPosition = position; lyricsAnchor = now
        }
        lyricsPlaying = isPlaying
    }

    /// Re-anchor only on a real discontinuity, so 4 Hz presentation ticks never jitter frames.
    mutating func update(position newPosition: Double, isPlaying playing: Bool, duration newDuration: Double, now: Double) {
        let predicted = position(at: now)
        if playing != isPlaying || abs(predicted - newPosition) > 0.2 || newDuration != duration {
            position = newPosition
            anchor = now
        }
        isPlaying = playing
        duration = newDuration
    }
}

// MARK: - Lyrics

/// The whole lyric document, converted once per revision, plus binary-searched position.
@MainActor
final class SkinLyricsTimeline {
    private(set) var lines: [SkinValue] = []
    private var starts: [Double] = []
    private var ranges: [(start: Double, end: Double)] = []
    private var words: [[(start: Double, end: Double)]] = []
    private var songParts: [String] = []
    private var cacheTime: Double = .nan
    private var cacheIndex = -1

    /// `timing` moves each line switch earlier the way native lyrics do, so a scene's current
    /// line arrives with the native one; word and line progress keep the authored times.
    func load(_ document: LyricsDocument?, timing: LyricsTimingConfiguration? = nil) {
        let groups = document?.groups ?? []
        lines = groups.enumerated().map { Self.record(for: $0.element, index: $0.offset) }
        ranges = groups.map { ($0.main.range.start, max($0.main.range.end, $0.background?.range.end ?? 0)) }
        starts = ranges.enumerated().map { index, range in
            guard let timing, timing.enabled, index > 0 else { return range.start }
            let gap = range.start - ranges[index - 1].end
            let near = gap <= timing.nearSwitchGap
            let leadInStart = max(0, range.start - (near ? timing.leadIn : 1))
            // A switch never moves before the previous line's own start.
            return max(ranges[index - 1].start, near ? leadInStart : max(ranges[index - 1].end, leadInStart))
        }
        words = groups.map { $0.main.words.map { ($0.range.start, $0.range.end) } }
        songParts = groups.map { $0.main.songPart ?? "" }
        cacheTime = .nan
        cacheIndex = -1
    }

    static func record(for group: LyricGroup, index: Int) -> SkinValue {
        var fields = lineFields(group.main)
        fields["index"] = .number(Double(index))
        fields["background"] = group.background.map { .record(lineFields($0)) } ?? .null
        return .record(fields)
    }

    private static func lineFields(_ line: LyricLine) -> [String: SkinValue] {
        [
            "id": .text(line.id),
            "start": .number(line.range.start), "end": .number(line.range.end), "duration": .number(line.range.duration),
            "text": .text(line.text),
            "words": .list(line.words.map(word)),
            "translation": .text(line.translations.first?.text ?? ""),
            "translations": .list(line.translations.map(layer)),
            "romanization": .text(line.romanizations.first?.text ?? ""),
            "romanizations": .list(line.romanizations.map(layer)),
            "isWordTimed": .boolean(line.hasEffectiveWordTiming),
            "isBackground": .boolean(line.isBackground), "isDuet": .boolean(line.isDuet),
            "agent": .text(line.agent), "language": .text(line.language),
            "songPart": .text(line.songPart ?? ""), "blockIndex": line.blockIndex.map { .number(Double($0)) } ?? .null,
        ]
    }

    private static func word(_ word: LyricWord) -> SkinValue {
        .record([
            "id": .text(word.id), "text": .text(word.text),
            "start": .number(word.range.start), "end": .number(word.range.end),
            "romanization": .text(word.romanization), "obscene": .boolean(word.obscene),
            "emptyBeat": word.emptyBeat.map { .number(Double($0)) } ?? .null,
            "ruby": .list(word.ruby.map { .record(["text": .text($0.text), "start": .number($0.range.start), "end": .number($0.range.end)]) }),
        ])
    }

    private static func layer(_ layer: LyricTextLayer) -> SkinValue {
        .record(["language": .text(layer.language), "text": .text(layer.text), "words": .list(layer.words.map(word))])
    }

    /// Index of the last line that has started, or -1 before the first line.
    func currentIndex(at time: Double) -> Int {
        if time == cacheTime { return cacheIndex }
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= time { low = middle + 1 } else { high = middle }
        }
        cacheTime = time
        cacheIndex = low - 1
        return cacheIndex
    }

    func line(relative offset: Int, time: Double) -> SkinValue {
        let index = currentIndex(at: time) + offset
        return lines.indices.contains(index) ? lines[index] : .null
    }

    func progress(index: Int, time: Double) -> Double {
        guard ranges.indices.contains(index) else { return 0 }
        let range = ranges[index]
        return range.end > range.start ? ((time - range.start) / (range.end - range.start)).clamped01 : (time >= range.start ? 1 : 0)
    }

    /// How much of a line has been sung, weighted by characters so a fill follows the voice.
    func sungFraction(index: Int, time: Double) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let texts = lines[index][member: "words"].listValue
        guard words.indices.contains(index), words[index].count == texts.count, !texts.isEmpty else {
            return progress(index: index, time: time)
        }
        var total = 0.0, sung = 0.0
        for (word, text) in zip(words[index], texts) {
            let weight = Double(max(1, text[member: "text"].textValue.count))
            total += weight
            sung += weight * (word.end > word.start ? ((time - word.start) / (word.end - word.start)).clamped01 : (time >= word.start ? 1 : 0))
        }
        return sung / total
    }

    /// Each word of a word-timed line with how far it has been sung; nil for line-timed lines.
    func wordProgress(index: Int, time: Double) -> [(text: String, progress: Double)]? {
        guard lines.indices.contains(index), words.indices.contains(index) else { return nil }
        let texts = lines[index][member: "words"].listValue
        guard !texts.isEmpty, texts.count == words[index].count else { return nil }
        return zip(words[index], texts).map { word, text in
            (text[member: "text"].textValue,
             word.end > word.start ? ((time - word.start) / (word.end - word.start)).clamped01 : (time >= word.start ? 1 : 0))
        }
    }

    /// When each character of a line is sung: a word's time is shared evenly among its
    /// characters; a line-timed line, or a translation, spreads the whole line.
    func glyphTimes(index: Int, text: String) -> [(start: Double, end: Double, word: Int)] {
        guard ranges.indices.contains(index) else { return [] }
        let texts = lines[index][member: "words"].listValue
        if words.indices.contains(index), words[index].count == texts.count, !texts.isEmpty,
           texts.map({ $0[member: "text"].textValue }).joined() == text {
            var result: [(start: Double, end: Double, word: Int)] = []
            for (number, (word, entry)) in zip(words[index], texts).enumerated() {
                let count = entry[member: "text"].textValue.count
                let step = (word.end - word.start) / Double(max(1, count))
                for k in 0..<count { result.append((word.start + step * Double(k), word.start + step * Double(k + 1), number)) }
            }
            return result
        }
        let range = ranges[index], count = text.count
        let step = (range.end - range.start) / Double(max(1, count))
        return (0..<count).map { (range.start + step * Double($0), range.start + step * Double($0 + 1), 0) }
    }

    private static let interludeThreshold = 4.0

    func value(_ key: String, time: Double) -> SkinValue {
        let index = currentIndex(at: time)
        switch key {
        case "lyrics.currentIndex": return .number(Double(index))
        case "lyrics.current": return lines.indices.contains(index) ? lines[index] : .null
        case "lyrics.previous": return lines.indices.contains(index - 1) ? lines[index - 1] : .null
        case "lyrics.next": return lines.indices.contains(index + 1) ? lines[index + 1] : .null
        case "lyrics.upcoming": return .list(Array(lines.dropFirst(max(0, index + 1)).prefix(3)))
        case "lyrics.recent": return .list(index > 0 ? Array(lines[max(0, index - 3)..<index]) : [])
        case "lyrics.lineProgress": return .number(progress(index: index, time: time))
        case "lyrics.wordIndex", "lyrics.wordProgress":
            guard words.indices.contains(index) else { return .number(key == "lyrics.wordIndex" ? -1 : 0) }
            let lineWords = words[index]
            let wordIndex = (lineWords.lastIndex { $0.start <= time }) ?? -1
            if key == "lyrics.wordIndex" { return .number(Double(wordIndex)) }
            guard lineWords.indices.contains(wordIndex) else { return .number(0) }
            let word = lineWords[wordIndex]
            return .number(word.end > word.start ? ((time - word.start) / (word.end - word.start)).clamped01 : 1)
        case "lyrics.isInterlude", "lyrics.interludeProgress":
            let gap = interlude(index: index, time: time)
            if key == "lyrics.isInterlude" { return .boolean(gap != nil) }
            return .number(gap ?? 0)
        case "lyrics.songPart": return .text(songParts.indices.contains(index) ? songParts[index] : "")
        default: return .null
        }
    }

    /// Progress through a long gap between lines, or nil while a line is sung.
    private func interlude(index: Int, time: Double) -> Double? {
        guard !ranges.isEmpty else { return nil }
        let gapStart = index >= 0 ? ranges[index].end : 0
        let gapEnd = ranges.indices.contains(index + 1) ? ranges[index + 1].start : .infinity
        guard time >= gapStart, gapEnd.isFinite, gapEnd - gapStart >= Self.interludeThreshold else { return nil }
        return ((time - gapStart) / (gapEnd - gapStart)).clamped01
    }
}

// MARK: - Audio

/// A lease on the shared analysis Hub and LED provider. The scene holds at most one, only
/// while a visible node reads audio and local playback is running. External sources report
/// that no PCM is available rather than inventing data.
@MainActor
final class SkinSceneAudio {
    enum Availability: String { case inactive, localAudio, externalAudioUnavailable }

    private(set) var availability = Availability.inactive
    private var consumerID: UUID?
    private var ledConsumerID: UUID?
    private var provider: LEDMeterServiceProvider?
    private var generation: UInt64 = 0

    private var magnitudes: [Float] = []
    private var pcm: [Float] = []
    private var sampleRate: Double = 44_100
    private var fftSize = 2048
    private var timestamp: Double = 0
    private var rms: Double = 0, peak: Double = 0, fastRMS: Double = 0, fastPeak: Double = 0
    private var ledLevel: Double = 0
    private var leds: [Double] = []

    private var smoothed: [String: [Double]] = [:]
    private var smoothedAt: [String: Double] = [:]
    private var bassAverage: Double = 0
    private var lastBeat: Double = -10
    private var lastBeatCheck: Double = 0

    static let bands: [String: (low: Double, high: Double)] = [
        "audio.bass": (20, 150), "audio.lowMid": (150, 400), "audio.mid": (400, 1200),
        "audio.vocal": (1000, 3500), "audio.treble": (3500, 16_000),
    ]

    func update(provider: LEDMeterServiceProvider, source: PlaybackSource, active: Bool, isPlaying: Bool, usesLED: Bool) {
        let next: Availability = !active ? .inactive : (source != .local ? .externalAudioUnavailable : (isPlaying ? .localAudio : .inactive))
        let keepsPausedFrame = active && source == .local && !isPlaying
        guard next != availability || (next == .localAudio && usesLED != (ledConsumerID != nil)) else { return }
        release(clear: !keepsPausedFrame)
        availability = next
        guard next == .localAudio else { return }
        self.provider = provider
        provider.acquireSession()
        let expected = generation
        consumerID = AudioAnalysisHub.shared.addConsumer { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, self.availability == .localAudio else { return }
                self.receive(frame)
            }
        }
        if usesLED {
            ledConsumerID = provider.addFrameConsumer { [weak self] metrics, _ in
                guard let self, self.generation == expected else { return }
                self.ledLevel = Double(metrics.level)
                self.leds = metrics.leds.map(Double.init)
            }
        }
    }

    func stop() {
        release(clear: true)
        availability = .inactive
    }

    private func release(clear: Bool) {
        generation &+= 1
        if let consumerID { AudioAnalysisHub.shared.removeConsumer(consumerID) }
        if let ledConsumerID { provider?.removeFrameConsumer(ledConsumerID) }
        consumerID = nil
        ledConsumerID = nil
        provider?.releaseSession()
        provider = nil
        if clear {
            magnitudes = []; pcm = []
            rms = 0; peak = 0; fastRMS = 0; fastPeak = 0; ledLevel = 0; leds = []
        }
    }

    /// Preview hosts feed synthetic frames through the same path.
    func receive(_ frame: AudioAnalysisData) {
        timestamp = Date.timeIntervalSinceReferenceDate
        magnitudes = frame.magnitudes
        pcm = frame.pcmSamples
        sampleRate = Double(frame.sampleRate)
        fftSize = frame.fftSize
        rms = Double(frame.rms); peak = Double(frame.peak)
        fastRMS = Double(frame.fastRMS); fastPeak = Double(frame.fastPeak)
    }

    func receiveSynthetic(magnitudes: [Float], pcm: [Float], level: Double) {
        availability = .localAudio
        self.magnitudes = magnitudes
        self.pcm = pcm
        rms = level * 0.3; peak = level * 0.6; fastRMS = rms; fastPeak = peak
        ledLevel = level
        leds = (0..<12).map { Double($0) / 12 < level ? 1 : 0 }
    }

    func value(_ key: String, now: Double) -> SkinValue {
        switch key {
        case "audio.available": return .boolean(availability == .localAudio)
        case "audio.availability": return .text(availability.rawValue)
        case "audio.rms": return .number(rms)
        case "audio.peak": return .number(peak)
        case "audio.fastRMS": return .number(fastRMS)
        case "audio.fastPeak": return .number(fastPeak)
        case "audio.level": return .number(smooth(key, [Self.loudness(fastRMS)], now: now)[0])
        case "audio.sampleRate": return .number(sampleRate)
        case "audio.pcm": return .list(pcm.map { .number(Double($0)) })
        case "audio.fft": return .list(magnitudes.map { .number(Double($0)) })
        case "audio.windowLength": return .number(Double(pcm.count))
        case "audio.timestamp": return .number(timestamp)
        case "audio.fftSize": return .number(Double(fftSize))
        case "audio.ledLevel": return .number(ledLevel)
        case "audio.leds": return .list(leds.map { .number($0) })
        case "audio.beat": return .number(beat(now: now))
        default:
            guard let range = Self.bands[key] else { return .null }
            return .number(band(lowHz: range.low, highHz: range.high, now: now))
        }
    }

    func band(lowHz: Double, highHz: Double, now: Double) -> Double {
        let key = "band.\(lowHz).\(highHz)"
        return smooth(key, [energy(lowHz, highHz)], now: now)[0]
    }

    func spectrum(count: Int, lowHz: Double, highHz: Double, now: Double) -> [Double] {
        let low = max(10, min(lowHz, highHz - 1)), high = max(low + 1, highHz)
        let ratio = high / low
        let targets = (0..<count).map { index -> Double in
            let start = low * pow(ratio, Double(index) / Double(count))
            let end = low * pow(ratio, Double(index + 1) / Double(count))
            return energy(start, end)
        }
        return smooth("spectrum.\(count).\(low).\(high)", targets, now: now)
    }

    func waveform(count: Int) -> [Double] {
        guard !pcm.isEmpty else { return Array(repeating: 0, count: count) }
        let chunk = max(1, pcm.count / count)
        return (0..<count).map { index in
            let start = index * chunk
            guard start < pcm.count else { return 0 }
            let slice = pcm[start..<min(pcm.count, start + chunk)]
            let extreme = slice.max { abs($0) < abs($1) } ?? 0
            return Double(max(-1, min(1, extreme)))
        }
    }

    /// Band energy in dBFS mapped from -72...-12 to 0...1, as the DSP spectrum card does.
    private func energy(_ lowHz: Double, _ highHz: Double) -> Double {
        guard !magnitudes.isEmpty, sampleRate > 0 else { return 0 }
        let binWidth = sampleRate / Double(fftSize)
        guard binWidth > 0, binWidth.isFinite else { return 0 }
        let first = max(1, Int(min(sampleRate / 2, max(0, lowHz)) / binWidth))
        let last = min(magnitudes.count - 1, max(first, Int(min(sampleRate / 2, max(0, highHz)) / binWidth)))
        guard first <= last else { return 0 }
        var sum: Float = 0
        for index in first...last { sum += magnitudes[index] }
        let decibels = 10 * log10(Double(max(sum, 1e-12))) - 20 * log10(Double(fftSize) / 2)
        return ((decibels + 72) / 60).clamped01
    }

    private static func loudness(_ linear: Double) -> Double {
        let decibels = 20 * log10(max(linear, 1e-6))
        return ((decibels + 54) / 48).clamped01
    }

    /// Fast attack, slower release, advanced once per display frame for each requested shape.
    private func smooth(_ key: String, _ targets: [Double], now: Double) -> [Double] {
        var values = smoothed[key] ?? targets
        if values.count != targets.count { values = targets }
        let last = smoothedAt[key] ?? now
        guard now != last || smoothed[key] == nil else { return values }
        let dt = min(0.1, max(0, now - last))
        for index in values.indices {
            let rate = targets[index] > values[index] ? 28.0 : 9.0
            values[index] += (targets[index] - values[index]) * (1 - exp(-dt * rate))
        }
        smoothed[key] = values
        smoothedAt[key] = now
        return values
    }

    private func beat(now: Double) -> Double {
        if now - lastBeatCheck > 1.0 / 120 {
            let bass = energy(20, 150)
            if bass > bassAverage * 1.25 + 0.06, now - lastBeat > 0.2 { lastBeat = now }
            bassAverage += (bass - bassAverage) * 0.04
            lastBeatCheck = now
        }
        return exp(-(now - lastBeat) * 6)
    }
}

/// Every capability string the host implements, for `has()` and manifest `requires`.
enum SkinHostCapabilities {
    static let nodes: Set<String> = [
        "scene@2", "layout@1", "scroll@1", "text@1", "image@1", "shape@1", "gradient@1", "symbol@1", "repeat@1",
        "visualizer.spectrum@1", "visualizer.waveform@1", "visualizer.meter@1", "lyricLine@1",
        "material@1", "glass@1", "blend@1", "mask@1", "filters@1", "effects@1",
        "shader@1", "particles@1", "video@1", "fonts@1", "animation@1", "keyframes@1",
        "state@1", "events@1", "gestures@1", "actions@1", "components@1", "templates@1",
        "audio.spectrum@1", "lyrics.native@1", "glyphMotion@1", "fog@1", "camera@1", "stroke@1",
    ]

    static var all: Set<String> {
        SkinDataSchema.capabilities.union(nodes).union(SkinComponentContract.capabilities).union(["params@1", "state@1"])
    }
}
