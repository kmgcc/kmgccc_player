import XCTest
@testable import NativeLyrics

final class MotionTests: XCTestCase {
    // Independent closed-form reference from AMLL's pushkine MIT solver, not the implementation.
    private func oracle(_ t: Double, mass: Double, damping: Double, stiffness: Double, delta: Double, velocity: Double) -> Double {
        if damping/(2*sqrt(stiffness*mass)) >= 1 {
            let omega = -sqrt(stiffness/mass)
            return delta-(delta+t*(-omega*delta-velocity))*exp(t*omega)
        }
        let f = sqrt(4*mass*stiffness-damping*damping)
        return delta-(cos(t*f/(2*mass))*delta+sin(t*f/(2*mass))*(damping*delta-2*mass*velocity)/f)*exp(-t*damping/(2*mass))
    }
    func testSystemSpringMatchesAMLLAcrossDampingRegimes() {
        for damping in [10.0,15,2*sqrt(170*0.9),80] {
            let spring = SpringParameters(mass:0.9,damping:damping,stiffness:170).system
            for tick in 0...240 {
                let t = Double(tick)/120
                XCTAssertEqual(spring.value(target:200,initialVelocity:75,time:t),oracle(t,mass:0.9,damping:damping,stiffness:170,delta:200,velocity:75),accuracy:1e-9)
            }
        }
    }
    func testRetargetPreservesPositionAndVelocity() {
        var spring = SpringTrack(0); spring.retarget(300,at:0)
        let x = spring.value(0.14), v = spring.velocity(0.14)
        spring.retarget(-20,at:0.14)
        XCTAssertEqual(spring.value(0.14),x,accuracy:1e-9); XCTAssertEqual(spring.velocity(0.14),v,accuracy:1e-9)
        XCTAssertEqual(spring.value(6),-20,accuracy:0.01)
    }
    func testDelayedRetargetKeepsMovingBeforeDeadline() {
        var spring = SpringTrack(0); spring.retarget(300,at:0)
        var uninterrupted = spring
        spring.retarget(-20,at:0.1,delay:0.3)
        XCTAssertEqual(spring.value(0.3),uninterrupted.value(0.3),accuracy:1e-9)
        let x = uninterrupted.value(0.4), v = uninterrupted.velocity(0.4)
        spring.resolve(0.4); uninterrupted.resolve(0.4)
        XCTAssertEqual(spring.value(0.4),x,accuracy:1e-9); XCTAssertEqual(spring.velocity(0.4),v,accuracy:1e-9)
        XCTAssertEqual(spring.value(6),-20,accuracy:0.01)
    }
    func testPositionPolicyEndpointIsFinite() {
        for interval in [0.0,0.1,0.4,0.8,8,100] {
            let p = SpringParameters.position(interval:interval,slow:false,end:false,profile:.currentPlayer)
            XCTAssertTrue(p.stiffness.isFinite); XCTAssertTrue((170...220).contains(p.stiffness))
        }
    }
    func testEmphasisStartsAndEndsAtRestWithCharacterStagger() {
        let e = EmphasisEnvelope(start:3,duration:2,characters:5,anchorCharacters:5,isLast:false,isBackground:false)
        XCTAssertEqual(e.sample(2,character:0,fontSize:40,radiusScale:1).scale,1)
        XCTAssertGreaterThan(e.sample(3.5,character:0,fontSize:40,radiusScale:1).glowOpacity,e.sample(3.5,character:4,fontSize:40,radiusScale:1).glowOpacity)
        XCTAssertEqual(e.sample(9,character:4,fontSize:40,radiusScale:1).scale,1)
        XCTAssertEqual(e.sample(4,character:1,fontSize:40,radiusScale:0.6).glowRadius,e.sample(4,character:1,fontSize:40,radiusScale:1).glowRadius*0.6,accuracy:1e-10)
    }
    func testMediaClockDoesNotIntegrateFrameDeltas() {
        var clock = LyricsClock(); clock.synchronize(time:15,playing:true,host:100)
        XCTAssertEqual(clock.time(at:105.125),20.125)
        clock.synchronize(time:20.125,playing:false,host:105.125)
        XCTAssertEqual(clock.time(at:500),20.125)
        clock.synchronize(time:3,playing:true,host:500)
        XCTAssertEqual(clock.time(at:501),4)
    }
}
