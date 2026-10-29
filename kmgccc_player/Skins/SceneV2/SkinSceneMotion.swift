import Foundation
import MotionKit
import Observation

/// What a paused scene does with its free-running motion. `settle` eases `time` to a stop and
/// back, `continue` keeps the wall clock, `stop` holds still at once.
enum SkinScenePauseMode: String, CaseIterable {
    case settle, `continue`, stop
}

/// The scene document's `motion`: the pause behaviour, the spring the playback flow rides, and
/// the skin's own named tokens, each a retuned MotionKit token that the user's motion speed scales.
struct SkinSceneMotion {
    var pause = SkinScenePauseMode.settle
    var flow: SkinValue = .text(MotionToken.gestureSettle.rawValue)
    var tokens: [String: SkinValue] = [:]
}

/// Eases from 1 while playing to 0 while paused on a MotionKit spring, and integrates scene time
/// under that curve. Lyric and playback clocks stay truthful; only free-running motion rides it.
struct SkinPlaybackFlow {
    private var spring: MotionRetargetState?
    private var integrated = 0.0
    private var integratedAt: Double?

    mutating func value(at now: Double) -> Double {
        guard var current = spring else { return 0 }
        var state = current.advance(to: now)
        if current.isAnimating, current.isSettled(at: now) {
            current.snap(to: current.target)
            state = (current.target, 0)
        }
        spring = current
        // A bouncy spring may dip below zero; time never runs backwards.
        return max(0, state.value)
    }

    /// Wall seconds weighted by the flow, integrated at the display rate while it moves.
    mutating func time(at now: Double) -> Double {
        guard let start = integratedAt else { integratedAt = now; return integrated }
        // Nodes evaluated a moment before the latest frame read slightly earlier time.
        guard now > start else { return max(0, integrated - (start - now) * value(at: start)) }
        let span = now - start
        let steps = spring?.isAnimating == true ? min(240, max(1, Int((span * 120).rounded(.up)))) : 1
        let step = span / Double(steps)
        for index in 0..<steps { integrated += step * value(at: start + step * (Double(index) + 0.5)) }
        integratedAt = now
        return integrated
    }

    /// Returns how long the flow takes to settle, or nil when nothing eases. Without a spec the
    /// flow jumps to its target, as on the first call.
    mutating func set(playing: Bool, spec: MotionSpec?, now: Double) -> TimeInterval? {
        let target = playing ? 1.0 : 0
        guard let existing = spring else {
            spring = MotionRetargetState(value: target, spec: spec ?? MotionTokens.standard.gestureSettle)
            integratedAt = now
            return nil
        }
        guard existing.target != target else { return nil }
        _ = time(at: now)
        guard let spec, var current = spring else {
            spring?.snap(to: target)
            return nil
        }
        let state = current.advance(to: now)
        current = MotionRetargetState(value: state.value, velocity: state.velocity, spec: spec)
        current.retarget(to: target, at: now)
        spring = current
        return current.visualCompletionDelay
    }
}

/// The `follow()` springs of one node instance. Each call site keeps a MotionKit spring that
/// retargets, velocity intact, whenever its target changes; the node's display timeline runs
/// only while one of them moves.
@Observable
@MainActor
final class SkinFollowers {
    private(set) var isMoving = false
    @ObservationIgnored private var springs: [Int: MotionRetargetState] = [:]
    @ObservationIgnored private var wanted = false

    func state(site: Int, target: Double, spec: MotionSpec?, now: Double) -> (value: Double, velocity: Double) {
        // Reduced motion lands on the target at once.
        guard let spec else {
            springs[site] = MotionRetargetState(value: target, spec: MotionTokens.standard.control)
            return (target, 0)
        }
        // A paused timeline hands back its last frame date; a retarget starts from the real now.
        let time = max(now, Date.timeIntervalSinceReferenceDate)
        guard var spring = springs[site] else {
            springs[site] = MotionRetargetState(value: target, spec: spec)
            return (target, 0)
        }
        if spring.target != target {
            if spring.spec != spec {
                let current = spring.advance(to: time)
                spring = MotionRetargetState(value: current.value, velocity: current.velocity, spec: spec)
            }
            spring.retarget(to: target, at: time)
            request(true)
        }
        var state = spring.advance(to: now)
        if spring.isAnimating, spring.isSettled(at: now) {
            spring.snap(to: spring.target)
            state = (spring.target, 0)
        }
        springs[site] = spring
        if wanted, !springs.values.contains(where: \.isAnimating) { request(false) }
        return state
    }

    /// Values are read while a view draws, so the observed flag changes on the next turn.
    private func request(_ moving: Bool) {
        guard wanted != moving else { return }
        wanted = moving
        Task { @MainActor [weak self] in
            guard let self, self.wanted == moving, self.isMoving != moving else { return }
            self.isMoving = moving
        }
    }
}

/// Unique ids for `follow()` call sites, handed out as expressions compile.
enum SkinFollowSites {
    @MainActor private static var last = 0
    @MainActor static func next() -> Int { last += 1; return last }
}

/// What keeps a node's display timeline running. Clock, lyric and audio inputs stand still the
/// moment playback pauses; scene time once the playback flow settles; follow springs once they
/// land. Keyframes, pointer idle time, free time and glyph clocks never rest.
struct SkinFrameInputs: Equatable {
    var playback = false
    var time = false
    var follow = false
    var always = false

    init(frame: Set<SkinDataDomain>, always: Bool) {
        self.always = always || !frame.isDisjoint(with: [.host, .wallTime])
        time = frame.contains(.time)
        follow = frame.contains(.follow)
        // A node on the timeline for its type alone (spectrum, lyric line) follows playback.
        playback = !frame.isDisjoint(with: [.clock, .lyricsTimeline, .audio]) || !(self.always || time || follow)
    }

    /// Lazy, so a view observes the flow and follow flags only when its inputs depend on them.
    func isStill(playing: Bool, timeMoves: @autoclosure () -> Bool, following: @autoclosure () -> Bool) -> Bool {
        !always && !(playback && playing) && !(time && timeMoves()) && !(follow && following())
    }
}
