import Foundation

public struct LyricInterlude: Equatable, Codable, Sendable {
    public var range: LyricRange
    public var anchor: Int
}

public struct LyricsTimelineSnapshot: Equatable, Codable, Sendable {
    public var time: Double = 0
    public var playing: Set<Int> = []
    public var highlighted: Set<Int> = []
    public var focus: Int = 0
    public var interlude: LyricInterlude?
    public var endOfSong = false
}

/// State transitions are independent of text geometry, display refresh and audio playback.
struct LyricsTimeline {
    var snapshot = LyricsTimelineSnapshot()
    let bounds: [LyricRange]
    let profile: LyricsProfile
    let interludes: [LyricInterlude]
    let preserveParallelHighlight: Bool
    init(bounds: [LyricRange], profile: LyricsProfile, preserveParallelHighlight: Bool = true) {
        self.bounds = bounds; self.profile = profile; self.preserveParallelHighlight = preserveParallelHighlight
        var end = 0.0, gaps: [LyricInterlude] = []
        for i in bounds.indices {
            let gapEnd = max(end,bounds[i].start-(profile == .currentPlayer ? 0.25 : 0))
            if gapEnd-end >= 4 { gaps.append(.init(range:.init(end,gapEnd),anchor:i-1)) }
            // A union avoids phantom interludes inside a long overlapping voice.
            end = max(end,bounds[i].end)
        }
        interludes = gaps
    }
    mutating func update(_ time: Double, seek: Bool = false, hasBottom: Bool = false) -> LyricsTimelineSnapshot {
        let previous = snapshot.playing
        let hot = Set(bounds.indices.filter { bounds[$0].contains(time) })
        let new = hot.subtracting(previous)
        let expired = snapshot.highlighted.subtracting(hot)
        let isSeek = seek || time < snapshot.time
        snapshot.time = time; snapshot.playing = hot
        snapshot.interlude = interludes.first { $0.range.contains(time+(profile == .currentPlayer ? 0.02 : 0)) }
        snapshot.endOfSong = !bounds.isEmpty && time >= (bounds.map(\.end).max() ?? 0)
        if isSeek {
            snapshot.highlighted = hot
            if profile == .upstream {
                if let anchor = bounds.indices.last(where: { bounds[$0].start <= time && bounds[$0].duration>0 }) {
                    snapshot.highlighted = Set((0...anchor).filter { bounds[$0].duration>0 && bounds[$0].end > bounds[anchor].start })
                    snapshot.focus = snapshot.highlighted.min() ?? 0
                } else { snapshot.focus = 0 }
            } else { snapshot.focus = hot.min() ?? bounds.firstIndex(where: { $0.start >= time }) ?? bounds.count }
        } else if !new.isEmpty {
            snapshot.highlighted.formUnion(new)
            snapshot.highlighted.subtract(expired)
            snapshot.focus = snapshot.highlighted.min() ?? snapshot.focus
        } else if profile == .currentPlayer && !expired.isEmpty && expired == snapshot.highlighted {
            snapshot.highlighted.removeAll()
        }
        if !preserveParallelHighlight {
            snapshot.highlighted = hot
            snapshot.focus = hot.min() ?? snapshot.focus
        }
        if profile == .upstream && ((snapshot.interlude != nil && hot.isEmpty) || snapshot.endOfSong) { snapshot.highlighted.removeAll() }
        if snapshot.endOfSong && snapshot.highlighted.isEmpty {
            snapshot.focus = hasBottom ? bounds.count : max(0,bounds.count-1)
        }
        return snapshot
    }
}

struct LyricsInteraction {
    var offset = 0.0
    var suspended = false
    var lastWheel = -Double.infinity
    var frozenFocus = 0
    var frozenInterlude: LyricInterlude?
    mutating func scroll(_ delta: Double, now: Double, timeline: LyricsTimelineSnapshot) {
        if !suspended { frozenFocus = timeline.focus; frozenInterlude = timeline.interlude }
        suspended = true; offset += delta; lastWheel = now
    }
    mutating func resume() { offset = 0; suspended = false; frozenInterlude = nil }
    mutating func update(now: Double, profile: LyricsProfile) -> Bool {
        let delay = profile == .upstream ? 5.15 : 5.0
        if suspended && now-lastWheel >= delay { resume(); return true }; return false
    }
    func dotsHidden(_ time: Double) -> Bool { time-lastWheel < 0.22 }
}

/// Host media samples can arrive at any cadence. Display refresh never integrates media deltas.
public struct LyricsClock: Sendable {
    private var anchorMedia = 0.0
    private var anchorHost = 0.0
    public private(set) var isPlaying = false
    public var rate: Double = 1
    public init() {}
    public func time(at host: Double) -> Double { max(0,anchorMedia + (isPlaying ? max(0,host-anchorHost)*rate : 0)) }
    public mutating func synchronize(time: Double, playing: Bool, host: Double) {
        guard time.isFinite, host.isFinite else { return }
        anchorMedia = max(0,time); anchorHost = host; isPlaying = playing
    }
}
