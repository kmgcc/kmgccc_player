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
            snapshot.highlighted = preserveParallelHighlight ? foregroundSpan(for: hot) : hot
            if profile == .upstream {
                if let anchor = bounds.indices.last(where: { bounds[$0].start <= time && bounds[$0].duration>0 }) {
                    snapshot.highlighted = Set((0...anchor).filter { bounds[$0].duration>0 && bounds[$0].end > bounds[anchor].start })
                    snapshot.focus = snapshot.highlighted.min() ?? 0
                } else { snapshot.focus = 0 }
            } else { snapshot.focus = hot.min() ?? bounds.firstIndex(where: { $0.start >= time }) ?? bounds.count }
        } else if !preserveParallelHighlight {
            snapshot.highlighted = hot
            snapshot.focus = hot.min() ?? snapshot.focus
        } else if !new.isEmpty {
            // AMLL's buffered foreground is the contiguous span between the
            // currently hot endpoints. A parallel voice may finish at the
            // exact instant another starts while the long main line remains
            // hot; the completed middle row stays highlighted in that span.
            // Once the old endpoint is no longer hot, a new transition
            // rebuilds the span and drops rows from the previous group.
            snapshot.highlighted = foregroundSpan(for: hot)
            snapshot.focus = snapshot.highlighted.min() ?? snapshot.focus
        } else if profile == .currentPlayer && !expired.isEmpty && expired == snapshot.highlighted {
            snapshot.highlighted.removeAll()
        }
        if profile == .upstream && ((snapshot.interlude != nil && hot.isEmpty) || snapshot.endOfSong) { snapshot.highlighted.removeAll() }
        if snapshot.endOfSong && snapshot.highlighted.isEmpty {
            snapshot.focus = hasBottom ? bounds.count : max(0,bounds.count-1)
        }
        return snapshot
    }

    private func foregroundSpan(for hot: Set<Int>) -> Set<Int> {
        guard let first = hot.min(), let last = hot.max() else { return [] }
        return Set(first...last)
    }
}

struct LyricsInteraction {
    var offset = 0.0
    var suspended = false
    var lastWheel = -Double.infinity
    private var resumeArmedAt = -Double.infinity
    var frozenFocus = 0
    var frozenInterlude: LyricInterlude?
    mutating func scroll(_ delta: Double, now: Double, timeline: LyricsTimelineSnapshot) {
        if !suspended { frozenFocus = timeline.focus; frozenInterlude = timeline.interlude }
        suspended = true; offset += delta; lastWheel = now; resumeArmedAt = now
    }
    mutating func resume() { offset = 0; suspended = false; frozenInterlude = nil; resumeArmedAt = -Double.infinity }
    mutating func pointerExited(now: Double) {
        guard suspended, now.isFinite else { return }
        // The five-second browsing timeout starts when the pointer leaves the
        // lyric surface, not while the user is still moving over it.
        resumeArmedAt = now
    }
    mutating func update(now: Double, profile: LyricsProfile, allowAutoResume: Bool = true) -> Bool {
        let delay = profile == .upstream ? 5.15 : 5.0
        if allowAutoResume && suspended && now-resumeArmedAt >= delay { resume(); return true }; return false
    }
    func dotsHidden(_ time: Double) -> Bool { time-lastWheel < 0.22 }
}

/// Host media samples can arrive at any cadence. Display refresh never integrates media deltas.
public struct LyricsClock: Sendable {
    /// Presentation updates are intentionally sparse (the player publishes at
    /// 4–10 Hz), while the lyric surface renders on the display clock.  A
    /// delayed presentation sample can therefore be a few hundred
    /// milliseconds behind the time we already predicted locally.  Re-basing
    /// to that stale value makes the highlight visibly slow, then causes it to
    /// catch up on the next sample.  Keep this tolerance below the explicit
    /// seek/discontinuity threshold so ordinary user seeks can still be
    /// applied by the view.
    public static let backwardsJitterTolerance = 0.35

    private var anchorMedia = 0.0
    private var anchorHost = 0.0
    private var hasAnchor = false
    public private(set) var isPlaying = false
    public var rate: Double = 1
    public init() {}
    public func time(at host: Double) -> Double { max(0,anchorMedia + (isPlaying ? max(0,host-anchorHost)*rate : 0)) }
    public mutating func synchronize(time: Double, playing: Bool, host: Double, force: Bool = false) {
        guard time.isFinite, host.isFinite else { return }
        let requested = max(0,time)
        let predicted = self.time(at: host)
        let playbackTransition = hasAnchor && isPlaying != playing
        let staleBacktrack = !playbackTransition && isPlaying && playing && requested < predicted
            && predicted - requested <= Self.backwardsJitterTolerance
        let staleResume = playbackTransition && playing
            && abs(requested - predicted) <= Self.backwardsJitterTolerance

        // A play/pause transition is sampled at the current predicted media
        // time. The last low-frequency playback sample can lag behind the
        // audio clock, so rebasing to it would visibly move lyrics backwards
        // on pause and create a time jump again on resume. A large difference
        // on resume is treated as a real rebase (for example an explicit seek
        // completed while paused); a small difference is just a stale sample.
        // Explicit loads and seeks still pass force and intentionally win over
        // the prediction.
        anchorMedia = force || (!staleBacktrack && !staleResume && !(playbackTransition && !playing))
            ? requested
            : predicted
        anchorHost = host
        isPlaying = playing
        hasAnchor = true
    }
}
