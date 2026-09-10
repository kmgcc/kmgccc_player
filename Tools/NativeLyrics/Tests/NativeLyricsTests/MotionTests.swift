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
    func testResizeRetargetCanDropInheritedVelocity() {
        var spring = SpringTrack(0)
        spring.retarget(300,at:0)
        let before = spring.value(0.18)
        let resize = SpringParameters(mass:1,damping:22,stiffness:120,soft:true)
        spring.retarget(-120,at:0.18,parameters:resize,preserveVelocity:false)
        XCTAssertEqual(spring.value(0.18),before,accuracy:1e-9)
        XCTAssertEqual(spring.velocity(0.18),0,accuracy:1e-9)
        let first = spring.value(0.24), second = spring.value(0.32), settled = spring.value(2)
        XCTAssertLessThan(first,before)
        XCTAssertLessThan(second,first)
        XCTAssertGreaterThanOrEqual(settled,-120.01)
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
    func testPositionOverrideKeepsReferenceSpringAndShapesBounce() {
        let reference = SpringParameters.positionOverride(duration:0.55,bounce:0.75)
        let expectedStiffness = SpringParameters.position.stiffness * pow(0.5 / 0.55, 2)
        XCTAssertEqual(reference.stiffness, expectedStiffness, accuracy: 1e-12)
        XCTAssertLessThan(reference.damping, 2 * sqrt(reference.mass * reference.stiffness))
        let calm = SpringParameters.positionOverride(duration:0.55,bounce:0.25)
        let bouncy = SpringParameters.positionOverride(duration:0.55,bounce:1.25)
        XCTAssertGreaterThan(calm.damping,reference.damping)
        XCTAssertLessThan(bouncy.damping,reference.damping)
        XCTAssertEqual(calm.stiffness,reference.stiffness,accuracy:1e-12)
        let faster = SpringParameters.positionOverride(duration:0.3,bounce:0.75)
        let speedRatio = 0.55 / 0.3
        XCTAssertEqual(faster.stiffness,reference.stiffness*speedRatio*speedRatio,accuracy:1e-12)
        XCTAssertEqual(faster.damping,reference.damping*speedRatio,accuracy:1e-12)
    }
    func testNonBouncyPositionIsCriticallyDamped() {
        let preview = SpringParameters.nonBouncyPosition(
            from: .init(mass: 0.9, damping: 8, stiffness: 180, soft: false)
        )
        XCTAssertEqual(preview.damping, 2 * sqrt(preview.mass * preview.stiffness), accuracy: 1e-12)
        XCTAssertTrue(preview.soft)
    }
    func testEmphasisStartsAndEndsAtRestWithCharacterStagger() {
        let e = EmphasisEnvelope(start:3,duration:2,characters:5,anchorCharacters:5,isLast:false,isBackground:false)
        XCTAssertEqual(e.sample(2,character:0,fontSize:40,radiusScale:1).scale,1)
        XCTAssertGreaterThan(e.sample(3.5,character:0,fontSize:40,radiusScale:1).glowOpacity,e.sample(3.5,character:4,fontSize:40,radiusScale:1).glowOpacity)
        XCTAssertEqual(e.sample(9,character:4,fontSize:40,radiusScale:1).scale,1)
        XCTAssertEqual(e.sample(4,character:1,fontSize:40,radiusScale:0.6).glowRadius,e.sample(4,character:1,fontSize:40,radiusScale:1).glowRadius*0.6,accuracy:1e-10)
    }
    func testNormalEmphasisBeginsOneSharedSlowFallAtLineEnd() {
        let e = EmphasisEnvelope(
            start: 0,
            duration: 2,
            characters: 5,
            anchorCharacters: 5,
            isLast: false,
            isBackground: false,
            lineEnd: 4
        )
        let beforeApex = abs(e.sample(-0.4,character:0,fontSize:40,radiusScale:1).floatY)
        let held = abs(e.sample(3.5,character:0,fontSize:40,radiusScale:1).floatY)
        let atLineEnd = abs(e.sample(4,character:0,fontSize:40,radiusScale:1).floatY)
        let firstCharacterFall = abs(e.sample(4.3,character:0,fontSize:40,radiusScale:1).floatY)
        let lastCharacterFall = abs(e.sample(4.3,character:4,fontSize:40,radiusScale:1).floatY)
        let afterFall = abs(e.sample(5.5,character:0,fontSize:40,radiusScale:1).floatY)
        let settled = abs(e.sample(7,character:0,fontSize:40,radiusScale:1).floatY)
        let continuedAfterExit = abs(e.sample(4.3,character:0,fontSize:40,radiusScale:1,exitMedia:4,exitElapsed:0.3).floatY)

        XCTAssertLessThan(beforeApex,held)
        XCTAssertEqual(held,atLineEnd,accuracy:0.0001)
        XCTAssertLessThan(firstCharacterFall,atLineEnd)
        XCTAssertEqual(firstCharacterFall,lastCharacterFall,accuracy:0.0001)
        XCTAssertEqual(firstCharacterFall,continuedAfterExit,accuracy:0.0001)
        XCTAssertGreaterThan(firstCharacterFall,afterFall)
        XCTAssertGreaterThan(afterFall,settled)
        XCTAssertEqual(settled,0,accuracy:0.0001)
    }

    func testEveryEmphasisLevelFallsToItsOriginalBaseline() {
        for isLast in [false, true] {
            let e = EmphasisEnvelope(
                start: 0,
                duration: 2,
                characters: 5,
                anchorCharacters: 5,
                isLast: isLast,
                isBackground: false,
                lineEnd: 4
            )

            let apex = e.sample(3.5, character: 2, fontSize: 40, radiusScale: 1)
            let atLineEnd = e.sample(4, character: 2, fontSize: 40, radiusScale: 1)
            let falling = e.sample(5, character: 2, fontSize: 40, radiusScale: 1)
            let settled = e.sample(8, character: 2, fontSize: 40, radiusScale: 1)

            XCTAssertLessThan(apex.floatY, 0)
            XCTAssertEqual(apex.floatY, atLineEnd.floatY, accuracy: 0.0001)
            XCTAssertGreaterThan(falling.floatY, atLineEnd.floatY)
            XCTAssertEqual(settled.floatY, 0, accuracy: 0.0001)
            XCTAssertEqual(settled.y, 0, accuracy: 0.0001)
        }
    }

    func testEarlyExitFallPreservesPartialRiseBeforeDescending() {
        let e = EmphasisEnvelope(
            start: 0,
            duration: 4,
            characters: 5,
            anchorCharacters: 5,
            isLast: true,
            isBackground: false,
            lineEnd: 8
        )

        let beforeExit = e.sample(1, character: 0, fontSize: 40, radiusScale: 1)
        let atExit = e.sample(1, character: 0, fontSize: 40, radiusScale: 1, exitMedia: 1, exitElapsed: 0)
        let afterExit = e.sample(1, character: 0, fontSize: 40, radiusScale: 1, exitMedia: 1, exitElapsed: 0.4)

        XCTAssertEqual(atExit.floatY, beforeExit.floatY, accuracy: 0.0001)
        XCTAssertGreaterThan(afterExit.floatY, atExit.floatY)
        XCTAssertEqual(
            e.sample(1, character: 0, fontSize: 40, radiusScale: 1, exitMedia: 1, exitElapsed: 4).floatY,
            0,
            accuracy: 0.0001
        )
    }
    func testMediaClockDoesNotIntegrateFrameDeltas() {
        var clock = LyricsClock(); clock.synchronize(time:15,playing:true,host:100)
        XCTAssertEqual(clock.time(at:105.125),20.125)
        clock.synchronize(time:20.125,playing:false,host:105.125)
        XCTAssertEqual(clock.time(at:500),20.125)
        clock.synchronize(time:3,playing:true,host:500)
        XCTAssertEqual(clock.time(at:501),4)
    }

    func testMediaClockIgnoresSmallBackwardPresentationJitter() {
        var clock = LyricsClock()
        clock.synchronize(time: 10, playing: true, host: 0)
        XCTAssertEqual(clock.time(at: 0.25), 10.25, accuracy: 0.0001)

        // A presentation callback can contain a value sampled just before the
        // display clock's prediction.  It must not pull the sweep backwards.
        clock.synchronize(time: 10.05, playing: true, host: 0.25)
        XCTAssertEqual(clock.time(at: 0.5), 10.50, accuracy: 0.0001)

        // An explicit rebase remains exact, even when it is a small backward
        // seek rather than a whole-second jump.
        clock.synchronize(time: 9.9, playing: true, host: 0.5, force: true)
        XCTAssertEqual(clock.time(at: 0.5), 9.9, accuracy: 0.0001)
    }

    func testInterludeColorWalkUsesTheMainLyricPalette() {
        let inactive = LyricsColor(0.2,0.3,0.4,alpha:0.7,displayP3:true)
        let active = LyricsColor(0.8,0.7,0.6,alpha:1,displayP3:true)
        XCTAssertEqual(interpolateLyricsColor(inactive,active,0),inactive)
        XCTAssertEqual(interpolateLyricsColor(inactive,active,1),active)
        let middle = interpolateLyricsColor(inactive,active,0.5)
        XCTAssertEqual(middle.red,0.5,accuracy:0.0001)
        XCTAssertEqual(middle.green,0.5,accuracy:0.0001)
        XCTAssertEqual(middle.blue,0.5,accuracy:0.0001)
        XCTAssertEqual(middle.alpha,0.85,accuracy:0.0001)
        XCTAssertTrue(middle.displayP3)
    }
}
