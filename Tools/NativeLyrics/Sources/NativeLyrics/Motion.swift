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
    static let position = SpringParameters(mass:0.9,damping:15,stiffness:90)
    static let scale = SpringParameters(mass:2,damping:25,stiffness:100)
    static let background = SpringParameters(mass:1,damping:20,stiffness:50)
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
    private var pending: (time:Double,target:Double,params:SpringParameters)?
    init(_ position: Double, _ params: SpringParameters = .init()) {
        origin = position; target = position; self.params = params
    }
    mutating func resolve(_ time: Double) {
        if let q = pending, time >= q.time {
            pending = nil
            let v = velocity(q.time), x = value(q.time)
            origin = x; initialVelocity = v; start = q.time; target = q.target; params = q.params
        }
    }
    func value(_ time: Double) -> Double {
        origin + params.system.value(target:target-origin,initialVelocity:initialVelocity,time:max(0,time-start))
    }
    func velocity(_ time: Double) -> Double {
        params.system.velocity(target:target-origin,initialVelocity:initialVelocity,time:max(0,time-start))
    }
    mutating func retarget(_ value: Double, at time: Double, delay: Double = 0, parameters: SpringParameters? = nil) {
        resolve(time)
        let p = parameters ?? params
        if let q = pending, abs(q.target-value)<0.00001, q.params == p { return }
        if pending == nil && abs(target-value)<0.00001 && p == params { return }
        if delay > 0 { pending = (time+delay,value,p); return }
        let v = velocity(time), x = self.value(time)
        origin = x; initialVelocity = v; start = time; target = value; params = p; pending = nil
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

/// Keeps a lyric mask moving through short timing stalls while preserving an
/// exact paused/seeked position. AMLL's browser mask is driven by an animation
/// clock between host samples; this small stateful track provides the same
/// continuity without advancing a paused lyric into the future.
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

        let dt = min(0.08, max(0, now - (lastHost ?? now)))
        let targetDelta = target - lastTarget
        let backwardsSnap = target < value - max(1, fadeWidth * 4)
        if backwardsSnap {
            value = target
        } else {
            // AMLL advances the Web Animations mask at playbackRate 1 and
            // only samples the host time on display updates.  The native
            // LyricsClock already predicts that same media time, so this
            // bridge must never trail the word. Only the small forward lead
            // is stateful; normal target motion is applied immediately.
            value = max(value, target)

            // During a very short host/audio stall AMLL's running animation
            // continues by a barely visible amount. Keep that glide bounded so
            // it cannot reveal a future word or survive a pause.
            // A normal slow syllable can move by only a few pixels per frame;
            // do not classify that as a stalled host clock.  The tiny
            // threshold is reserved for repeated, effectively identical
            // samples where AMLL's running browser animation remains visible.
            let stall = abs(targetDelta) <= max(0.0001, fadeWidth * 0.0005)
            if stall {
                let maxLead = max(0.35, fadeWidth * 0.03)
                let glideRate = max(0.12, fadeWidth * 0.02)
                value += max(0,target + maxLead - value) * (1-exp(-glideRate*dt/maxLead))
            }
        }
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
    func sample(_ time: Double, character: Int, fontSize: Double, radiusScale: Double) -> EmphasisSample {
        var du = max(1,duration)
        func shape(_ x: Double) -> Double { x > 1 ? sqrt(x) : pow(x,3) }
        var amount = shape(du/2)*0.6, blur = shape(du/3)*0.5
        if isLast { amount *= 1.6; blur *= 1.5; du *= 1.2 }
        amount = min(1.2,amount); blur = min(0.8,blur)
        let delay = start + du/2.5/Double(max(1,anchorCharacters))*Double(character)
        let e = Curves.sampled((time-delay)/du,value:Curves.emphasis)
        let float = Curves.sampled((time-delay+0.4)/(du*1.4)) { sin($0 * .pi) }
        return EmphasisSample(scale:1+e*0.1*amount,
                              x: -e*0.03*amount*(Double(characters)/2-Double(character))*fontSize,
                              y: -e*0.025*amount*fontSize,
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
