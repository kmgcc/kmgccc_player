import Foundation
import SwiftUI

public struct SpringParameters: Equatable, Sendable {
    public var mass: Double
    public var damping: Double
    public var stiffness: Double
    public var soft: Bool
    public init(mass: Double = 1, damping: Double = 10, stiffness: Double = 100, soft: Bool = false) {
        self.mass = mass; self.damping = damping; self.stiffness = stiffness; self.soft = soft
    }
    var system: Spring {
        Spring(mass:mass,stiffness:stiffness,damping:soft ? 2*sqrt(mass*stiffness) : damping,allowOverDamping:false)
    }
    public static let position = SpringParameters(mass:0.9,damping:15,stiffness:90)
    public static let scale = SpringParameters(mass:2,damping:25,stiffness:100)
    public static let background = SpringParameters(mass:1,damping:20,stiffness:50)
    /// A seek preview follows the same position solver family, but is always
    /// critically damped. Scrubbing must accelerate/decelerate naturally
    /// without overshooting the lyric target on every pointer sample.
    public static func nonBouncyPosition(from parameters: Self = .position) -> Self {
        let mass = max(0.01, parameters.mass.isFinite ? parameters.mass : Self.position.mass)
        let stiffness = max(0.01, parameters.stiffness.isFinite ? parameters.stiffness : Self.position.stiffness)
        return Self(
            mass: mass,
            damping: 2 * sqrt(mass * stiffness),
            stiffness: stiffness,
            soft: true
        )
    }
    /// Maps the player's duration/bounce controls relative to the native
    /// position spring while preserving its damping ratio before bounce
    /// shaping. The default pair is mapped explicitly too, so the value shown
    /// in settings and the value used by the renderer cannot take different
    /// solver paths.
    public static func positionOverride(
        duration: Double,
        bounce: Double,
        // Keep these solver reference values aligned with the public AMLL
        // implementation. They are not the settings defaults: the public
        // defaults may change independently, while the control mapping must
        // continue to produce the same physical curve for the same values.
        referenceDuration: Double = 0.5,
        referenceBounce: Double = 0.3
    ) -> Self {
        let resolvedDuration = min(1.2,max(0.3,duration.isFinite ? duration : referenceDuration))
        let resolvedBounce = min(3.25,max(-0.25,bounce.isFinite ? bounce : referenceBounce))
        let speedRatio = referenceDuration/resolvedDuration
        let base = Self.position
        let stiffness = min(5_000,max(8,base.stiffness*speedRatio*speedRatio))
        var damping = base.damping*speedRatio
        let bounceOffset = resolvedBounce-referenceBounce
        if bounceOffset > 0 {
            let primary = min(1,bounceOffset)
            // AMLL compresses the primary bounce range quadratically. A cubic
            // here made the new 0.55/0.75 default almost critically damped,
            // which looked like a plain translation and removed the settle
            // back that the settings promise.
            damping *= 1-pow(primary,2)*0.55
            let extraRange = max(0.001,3.25-referenceBounce-1)
            let extra = min(1,max(0,bounceOffset-1)/extraRange)
            damping *= 1-extra*0.35
        } else if bounceOffset < 0 {
            let range = max(0.001,referenceBounce-(-0.25))
            damping *= 1+sqrt(min(1,-bounceOffset/range))*1.15
        }
        return Self(mass:base.mass,damping:min(260,max(0.8,damping)),stiffness:stiffness,soft:false)
    }
    static func position(interval: Double?, slow: Bool, end: Bool, profile: LyricsProfile) -> Self {
        if slow || interval == nil { return .position }
        if end && profile == .upstream { return Self(mass:0.9,damping:22,stiffness:140) }
        let ratio = pow(max(0,1 - (min(800,max(100,interval!*1000))-100)/700),0.2)
        let k = 170 + ratio*50
        return Self(mass:0.9,damping:2.2*sqrt(k),stiffness:k)
    }
}

/// A target/delay track, backed entirely by Apple's Spring value/velocity solver.
/// During a delay the previous spring keeps moving, then its current velocity is inherited.
struct SpringTrack {
    private var origin: Double
    private var initialVelocity = 0.0
    private var start = 0.0
    private(set) var target: Double
    private var params: SpringParameters
    private var solver: Spring
    private var pending: (time:Double,target:Double,params:SpringParameters)?
    init(_ position: Double, _ params: SpringParameters = .init()) {
        origin = position; target = position; self.params = params; solver = params.system
    }
    mutating func resolve(_ time: Double) {
        if let q = pending, time >= q.time {
            pending = nil
            let v = velocity(q.time), x = value(q.time)
            origin = x; initialVelocity = v; start = q.time; target = q.target; params = q.params; solver = q.params.system
        }
    }
    func value(_ time: Double) -> Double {
        if origin == target && initialVelocity == 0 { return origin }
        return origin + solver.value(target:target-origin,initialVelocity:initialVelocity,time:max(0,time-start))
    }
    func velocity(_ time: Double) -> Double {
        if origin == target && initialVelocity == 0 { return 0 }
        return solver.velocity(target:target-origin,initialVelocity:initialVelocity,time:max(0,time-start))
    }
    mutating func retarget(_ value: Double, at time: Double, delay: Double = 0, parameters: SpringParameters? = nil, preserveVelocity: Bool = true) {
        resolve(time)
        let p = parameters ?? params
        if let q = pending, abs(q.target-value)<0.00001, q.params == p { return }
        if pending == nil && abs(target-value)<0.00001 && p == params { return }
        if delay > 0 { pending = (time+delay,value,p); return }
        let v = preserveVelocity ? velocity(time) : 0, x = self.value(time)
        origin = x; initialVelocity = v; start = time; target = value; params = p; solver = p.system; pending = nil
    }
    mutating func snap(_ value: Double, at time: Double) {
        origin = value; target = value; initialVelocity = 0; start = time; pending = nil
    }
    mutating func translate(_ delta: Double) {
        origin += delta; target += delta
        if let q = pending { pending = (q.time,q.target+delta,q.params) }
    }
    func settled(_ time: Double) -> Bool { pending == nil && abs(value(time)-target)<0.01 && abs(velocity(time))<0.01 }
}

enum Curves {
    static let ease = UnitCurve.bezier(startControlPoint:UnitPoint(x:0.25,y:0.1),endControlPoint:UnitPoint(x:0.25,y:1))
    static let easeOut = UnitCurve.bezier(startControlPoint:UnitPoint(x:0,y:0),endControlPoint:UnitPoint(x:0.58,y:1))
    static let emphasisIn = UnitCurve.bezier(startControlPoint:UnitPoint(x:0.2,y:0.4),endControlPoint:UnitPoint(x:0.58,y:1))
    static let emphasisOut = UnitCurve.bezier(startControlPoint:UnitPoint(x:0.3,y:0),endControlPoint:UnitPoint(x:0.58,y:1))
    static func clamp(_ x: Double) -> Double { min(1,max(0,x)) }
    static func emphasis(_ x: Double) -> Double {
        let p = clamp(x)
        return p < 0.5 ? emphasisIn.value(at:p*2) : 1-emphasisOut.value(at:(p-0.5)*2)
    }
    /// WAAPI's 32 linearly interpolated keyframes, including its implicit zero baseline.
    static func sampled(_ x: Double, count: Int = 32, value: (Double)->Double) -> Double {
        let p = clamp(x)*Double(count), lo = floor(p), hi = min(Double(count),lo+1)
        return value(lo/Double(count)) + (value(hi/Double(count))-value(lo/Double(count)))*(p-lo)
    }
}

/// Normal emphasis rises are intentionally staggered per character, but the
/// return to the baseline is one slow, shared line motion. Keep the duration
/// here so the regular word float and the emphasis float cannot drift apart.
let lyricLineFallDuration = 2.4

/// Returns the shared fall multiplier after the authored line highlight has
/// finished. A nil result means the line is still in its per-character rise
/// phase. `exitMedia`/`exitElapsed` let a line that leaves the foreground
/// continue the same media-time fall on the host clock without snapping.
func lyricLineFallMultiplier(
    time: Double,
    lineEnd: Double,
    exitMedia: Double? = nil,
    exitElapsed: Double? = nil
) -> Double? {
    guard lineEnd.isFinite else { return nil }
    let elapsed: Double
    if let exitElapsed {
        let mediaElapsed = max(0, (exitMedia ?? lineEnd) - lineEnd)
        elapsed = mediaElapsed + max(0, exitElapsed)
    } else {
        elapsed = time - lineEnd
    }
    // At the exact boundary the line is still at its rise apex. Returning
    // 1 here makes the fall continuous; returning nil made callers switch
    // from their per-word rise to a full-amplitude line fall one frame later.
    guard elapsed >= 0 else { return nil }
    let progress = Curves.clamp(elapsed / lyricLineFallDuration)
    return 1 - Curves.ease.value(at: progress)
}

/// The media instant at which a line's float begins descending. A line that
/// leaves the foreground early starts from its current per-word amplitude;
/// otherwise it waits for the authored end of the last word.
func lyricLineFallStartMedia(lineEnd: Double, exitMedia: Double?) -> Double? {
    guard lineEnd.isFinite else { return nil }
    guard let exitMedia, exitMedia.isFinite else { return lineEnd }
    return min(lineEnd, exitMedia)
}

struct Tween {
    var from: Double
    var target: Double
    var start = 0.0
    var duration = 0.4
    init(_ value: Double) { from = value; target = value }
    func value(_ time: Double) -> Double { from+(target-from)*Curves.ease.value(at:Curves.clamp((time-start)/max(0.0001,duration))) }
    mutating func set(_ target: Double, at time: Double, duration: Double = 0.4) {
        guard self.target != target else { return }
        from = value(time); self.target = target; start = time; self.duration = duration
    }
    mutating func snap(_ value: Double) {
        from = value; target = value; start = 0; duration = 0
    }
    func settled(_ time: Double) -> Bool { time >= start+duration || from == target }
}

/// Exit-only time warp: initial derivative is the normal playback rate, then
/// acceleration increases continuously. The live media clock is never changed.
func exitCatchUpTime(start: Double, end: Double, elapsed: Double, duration: Double) -> Double {
    let remaining = max(0,end-start), d = max(0.001,min(duration,remaining))
    let t = min(d,max(0,elapsed))
    return min(end,start+t+max(0,remaining-d)*pow(t/d,2))
}

/// Samples the karaoke mask without adding a trailing filter.  The host clock
/// is already authoritative; smoothing the sampled position makes imprecise
/// LDDC line timing look late and can leave a word visibly stuck behind audio.
/// Anticipation through authored gaps is handled by `MaskPath`, before this
/// sampler, and remains bounded to the source timing.
struct HighlightSmoother {
    private(set) var value = 0.0
    private var lastTarget = 0.0
    private var lastHost: Double?
    private var initialized = false

    mutating func reset(_ target: Double) {
        value = target; lastTarget = target; lastHost = nil; initialized = true
    }

    mutating func sample(target: Double, now: Double, playing: Bool, reset: Bool, fadeWidth: Double) -> Double {
        guard target.isFinite else { return value }
        if reset || !playing || !initialized || lastHost == nil {
            value = target; lastTarget = target; lastHost = now; initialized = true
            return value
        }
        // A real media sample is not something to ease toward.  Applying it
        // directly keeps both forward and backward seeks exact and leaves no
        // synthetic lead/lag when the display link receives repeated samples.
        value = target
        lastTarget = target; lastHost = now
        return value
    }
}

public struct EmphasisSample: Codable, Sendable {
    public var scale: Double = 1
    public var x: Double = 0
    public var y: Double = 0
    public var floatY: Double = 0
    public var glowOpacity: Double = 0
    public var glowRadius: Double = 0
}

struct EmphasisEnvelope {
    let start: Double
    let duration: Double
    let characters: Int
    let anchorCharacters: Int
    let isLast: Bool
    let isBackground: Bool
    /// The emphasis float keeps its per-character rise, but its descent is a
    /// line-level motion.  The old native path started a separate exit clock
    /// for every character when the row lost focus, which made the line fall
    /// in a visibly staggered, granular way.
    let lineEnd: Double?

    init(
        start: Double,
        duration: Double,
        characters: Int,
        anchorCharacters: Int,
        isLast: Bool,
        isBackground: Bool,
        lineEnd: Double? = nil
    ) {
        self.start = start
        self.duration = duration
        self.characters = characters
        self.anchorCharacters = anchorCharacters
        self.isLast = isLast
        self.isBackground = isBackground
        self.lineEnd = lineEnd
    }

    private func safeDuration() -> Double { max(1,duration.isFinite ? duration : 1) }
    private func effectiveLineEnd() -> Double {
        let fallback = start + safeDuration()
        guard let lineEnd, lineEnd.isFinite else { return fallback }
        return max(start,lineEnd)
    }
    private func floatProgress(_ time: Double, character: Int, duration du: Double) -> Double {
        let delay = start + du/2.5/Double(max(1,anchorCharacters))*Double(character)
        return (time-delay+0.4)/(du*1.4)
    }
    private func heldFloatValue(_ time: Double, character: Int, duration du: Double) -> Double {
        let progress = Curves.clamp(floatProgress(time,character:character,duration:du))
        // The normal float animation reaches its apex well before the
        // word/line ends. Keep that apex stable until the shared line fall
        // boundary; sampling the full sine after 0.5 would otherwise make it
        // fall back to zero while the line is still being sung.
        let rising = min(0.5,progress)
        return Curves.sampled(rising) { sin($0 * .pi) }
    }
    private func floatValue(
        at time: Double,
        character: Int,
        duration du: Double,
        exitMedia: Double?,
        exitElapsed: Double?
    ) -> Double {
        let lineEnd = effectiveLineEnd()
        let fallStart = lyricLineFallStartMedia(lineEnd: lineEnd, exitMedia: exitMedia) ?? lineEnd
        let current = heldFloatValue(time,character:character,duration:du)
        // Every emphasis level uses the same line-level descent. The amount
        // captured at the fall boundary remains character-specific, so an
        // early exit cannot replace a partially-risen word with a full-height
        // jump before it starts falling.
        let atFallStart = heldFloatValue(fallStart,character:character,duration:du)
        if let fall = lyricLineFallMultiplier(
            time: time,
            lineEnd: lineEnd,
            exitMedia: exitMedia,
            exitElapsed: exitElapsed
        ) {
            return atFallStart * fall
        }
        return current
    }

    private func heldEmphasisValue(_ time: Double, character: Int, duration du: Double) -> Double {
        let delay = start + du/2.5/Double(max(1,anchorCharacters))*Double(character)
        let progress = Curves.clamp((time-delay)/du)
        // Keep the per-character rise, but hold its apex until the shared
        // line fall starts. The old full emphasis curve returned to zero per
        // character and was the remaining source of granular vertical motion.
        return Curves.sampled(min(0.5,progress),value:Curves.emphasis)
    }

    private func emphasisYValue(
        at time: Double,
        character: Int,
        duration du: Double,
        exitMedia: Double?,
        exitElapsed: Double?
    ) -> Double {
        let lineEnd = effectiveLineEnd()
        let current = heldEmphasisValue(time,character:character,duration:du)
        let fallStart = lyricLineFallStartMedia(lineEnd: lineEnd, exitMedia: exitMedia) ?? lineEnd
        let atFallStart = heldEmphasisValue(fallStart,character:character,duration:du)
        if let fall = lyricLineFallMultiplier(
            time: time,
            lineEnd: lineEnd,
            exitMedia: exitMedia,
            exitElapsed: exitElapsed
        ) {
            return atFallStart * fall
        }
        return current
    }

    func sample(
        _ time: Double,
        character: Int,
        fontSize: Double,
        radiusScale: Double,
        exitMedia: Double? = nil,
        exitElapsed: Double? = nil
    ) -> EmphasisSample {
        let du = safeDuration()
        func shape(_ x: Double) -> Double { x > 1 ? sqrt(x) : pow(x,3) }
        var animatedDuration = du
        var amount = shape(du/2)*0.6, blur = shape(du/3)*0.5
        if isLast { amount *= 1.6; blur *= 1.5; animatedDuration *= 1.2 }
        amount = min(1.2,amount); blur = min(0.8,blur)
        let delay = start + animatedDuration/2.5/Double(max(1,anchorCharacters))*Double(character)
        let e = Curves.sampled((time-delay)/animatedDuration,value:Curves.emphasis)
        let yEmphasis = emphasisYValue(
            at: time,
            character: character,
            duration: animatedDuration,
            exitMedia: exitMedia,
            exitElapsed: exitElapsed
        )
        let float = floatValue(
            at: time,
            character: character,
            duration: animatedDuration,
            exitMedia: exitMedia,
            exitElapsed: exitElapsed
        )
        return EmphasisSample(scale:1+e*0.1*amount,
                              x: -e*0.03*amount*(Double(characters)/2-Double(character))*fontSize,
                              y: -yEmphasis*0.025*amount*fontSize,
                              floatY: -float*0.05*fontSize*(isBackground ? 2 : 1),
                              glowOpacity:e*blur,glowRadius:min(0.3,blur*0.3)*fontSize*radiusScale)
    }
}

public struct InterludeSample: Codable, Sendable {
    public var scale: Double
    public var opacity: Double
    public var walk: [Double]
}

func interludeSample(elapsed: Double, duration: Double, profile: LyricsProfile) -> InterludeSample {
    guard duration > 0, elapsed >= 0, elapsed <= duration else { return .init(scale:0,opacity:0,walk:[0,0,0]) }
    let breathe = duration/ceil(duration/(profile == .upstream ? 4.5 : 1.5))
    var scale = sin(1.5 * .pi - elapsed/breathe*2*(profile == .upstream ? .pi : 1))/20 + 1
    if elapsed < 2 { scale *= 1-pow(2,-10*elapsed/2) }
    var opacity = Curves.clamp((elapsed-0.5)/0.5)
    let remaining = duration-elapsed
    if remaining < 0.75 {
        let x = (0.75-remaining)/0.75/2, c2 = 1.70158*1.525
        let ease = pow(2*x,2)*((c2+1)*2*x-c2)/2
        scale *= 1-ease
    }
    if remaining < 0.375 { opacity *= Curves.clamp(remaining/0.375) }
    let d = duration-0.75
    let walk = (0..<3).map { i in d > 0 ? max(0.25,min(1,(elapsed-Double(i)*d/3)*3/d*0.75)) : 0.25 }
    return .init(scale:max(0,scale)*0.7,opacity:opacity,walk:walk)
}
