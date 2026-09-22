import QuartzCore
import SwiftUI
import XCTest
@testable import MotionKit

final class MotionKitTests: XCTestCase {
    func testStandardTokensAreSemanticAndBounded() {
        let tokens = MotionTokens.standard

        XCTAssertEqual(tokens[.microInteraction].duration, 0.18, accuracy: 0.0001)
        XCTAssertEqual(tokens[.control].bounce, 0.04, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(tokens[.emphasis].bounce, 0.4)
        XCTAssertGreaterThan(tokens[.backgroundTransition].duration, tokens[.control].duration)
    }

    func testSystemPolicyMapsAccessibilityReduceMotionWithoutDisablingMotion() {
        XCTAssertEqual(
            MotionPolicy.system(accessibilityReduceMotion: false),
            .full
        )
        XCTAssertEqual(
            MotionPolicy.system(accessibilityReduceMotion: true),
            .reduced
        )
    }

    func testStandardTokensStayWithinThePlanRanges() {
        let tokens = MotionTokens.standard
        let ranges: [(MotionToken, ClosedRange<Double>, ClosedRange<Double>)] = [
            (.microInteraction, 0.14...0.20, 0...0.03),
            (.control, 0.24...0.36, 0...0.08),
            (.layout, 0.38...0.56, 0...0.12),
            (.navigation, 0.45...0.68, 0...0.12),
            (.gestureSettle, 0.30...0.50, 0.06...0.20),
            (.emphasis, 0.32...0.52, 0.08...0.28),
            (.contentReplacement, 0.16...0.32, 0...0.06),
            (.backgroundTransition, 0.50...0.85, 0...0.08)
        ]

        for (token, durationRange, bounceRange) in ranges {
            let spec = tokens[token]
            XCTAssertTrue(durationRange.contains(spec.duration), "Unexpected duration for \(token)")
            XCTAssertTrue(bounceRange.contains(spec.bounce), "Unexpected bounce for \(token)")
        }
    }

    func testPhaseSpecScalesDurationFromItsSemanticToken() {
        let tokens = MotionTokens.standard.replacing(
            .contentReplacement,
            with: MotionSpec(duration: 0.48, bounce: 0.12, blendDuration: 0.09)
        )

        let phase = tokens.phaseSpec(
            for: .contentReplacement,
            duration: 0.32
        )

        XCTAssertEqual(phase.duration, 0.64, accuracy: 0.0001)
        XCTAssertEqual(phase.bounce, 0.12, accuracy: 0.0001)
        XCTAssertEqual(phase.blendDuration, 0.09, accuracy: 0.0001)
    }

    func testPhaseSpecCanOverrideBounceWithoutLosingTokenBlendDuration() {
        let tokens = MotionTokens.standard

        let phase = tokens.phaseSpec(
            for: .backgroundTransition,
            duration: 0.34,
            bounce: 0
        )

        XCTAssertEqual(phase.duration, 0.34, accuracy: 0.0001)
        XCTAssertEqual(phase.bounce, 0, accuracy: 0.0001)
        XCTAssertEqual(phase.blendDuration, tokens[.backgroundTransition].blendDuration, accuracy: 0.0001)
    }

    func testPerceptualSpecUsesAppleSpringModel() {
        let spec = MotionSpec(duration: 0.4, bounce: 0.12)
        let evaluator = MotionSpringEvaluator(spec: spec)

        XCTAssertEqual(evaluator.normalizedValue(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(evaluator.value(from: 20, to: 80, at: 0), 20, accuracy: 0.0001)
        XCTAssertGreaterThan(evaluator.normalizedValue(at: 0.2), 0)
    }

    func testPhysicalSpecPreservesInitialVelocityAcrossAdapters() {
        let spec = MotionSpec(
            physical: MotionPhysicalParameters(
                stiffness: 120,
                damping: 14
            )
        )

        let animation = spec.swiftUIAnimation(initialVelocity: 2.5)
        let layerAnimation = spec.coreAnimation(
            keyPath: "position.x",
            initialVelocity: 2.5
        )

        XCTAssertNotNil(animation)
        XCTAssertEqual(layerAnimation.keyPath, "position.x")
        XCTAssertEqual(layerAnimation.initialVelocity, 2.5, accuracy: 0.0001)
        XCTAssertGreaterThan(layerAnimation.duration, 0)
    }

    func testLayerAnimatorUsesResolvedSpringAndUpdatesModelValue() {
        let layer = CALayer()
        layer.opacity = 0
        let delay = MotionLayerAnimator.animate(
            layer: layer,
            keyPath: "opacity",
            fromValue: 0,
            toValue: 1,
            spec: MotionTokens.standard[.contentReplacement],
            policy: .full,
            animationKey: "test.opacity"
        )

        XCTAssertEqual(layer.opacity, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(delay, 0)
        let animation = layer.animation(forKey: "test.opacity") as? CASpringAnimation
        XCTAssertEqual(animation?.keyPath, "opacity")
        XCTAssertEqual(animation?.fromValue as? Int, 0)
        XCTAssertEqual(animation?.toValue as? Int, 1)
        XCTAssertTrue(animation?.isRemovedOnCompletion == true)
    }

    func testLayerAnimatorDisabledPolicySnapsAndDoesNotInstallAnimation() {
        let layer = CALayer()
        layer.opacity = 0

        let delay = MotionLayerAnimator.animate(
            layer: layer,
            keyPath: "opacity",
            fromValue: 0,
            toValue: 1,
            spec: MotionTokens.standard[.contentReplacement],
            policy: .disabled,
            animationKey: "test.opacity"
        )

        XCTAssertEqual(delay, 0)
        XCTAssertEqual(layer.opacity, 1, accuracy: 0.0001)
        XCTAssertNil(layer.animation(forKey: "test.opacity"))
    }

    func testLayerAnimatorReducedPolicyRemovesBounceWithoutDisablingMotion() {
        let layer = CALayer()
        layer.opacity = 0

        let delay = MotionLayerAnimator.animate(
            layer: layer,
            keyPath: "opacity",
            fromValue: 0,
            toValue: 1,
            spec: MotionTokens.standard[.emphasis],
            policy: .reduced,
            animationKey: "test.opacity"
        )

        let animation = layer.animation(forKey: "test.opacity") as? CASpringAnimation
        XCTAssertGreaterThan(delay, 0)
        XCTAssertEqual(animation?.settlingDuration ?? 0, delay, accuracy: 0.0001)
        XCTAssertEqual(Double(animation?.initialVelocity ?? 0), 0, accuracy: 0.0001)
        XCTAssertTrue(animation?.isRemovedOnCompletion == true)
    }

    func testEvaluatorConvergesWithinCoreAnimationSettlingWindow() {
        let specs = [
            MotionSpec(duration: 0.30, bounce: 0),
            MotionSpec(duration: 0.42, bounce: 0.14),
            MotionSpec(
                physical: MotionPhysicalParameters(
                    stiffness: 120,
                    damping: 14
                )
            )
        ]

        for spec in specs {
            let initialVelocity = 0.75
            let layerAnimation = spec.coreAnimation(initialVelocity: initialVelocity)
            let evaluator = MotionSpringEvaluator(spec: spec)
            let value = evaluator.normalizedValue(
                at: layerAnimation.settlingDuration,
                initialVelocity: initialVelocity
            )

            XCTAssertEqual(value, 1, accuracy: 0.02)
            XCTAssertGreaterThan(layerAnimation.settlingDuration, 0)
        }
    }

    func testCoreAnimationAdapterLeavesLayerLifecycleWithSystemDefaults() {
        let animation = MotionSpec(duration: 0.4, bounce: 0.08)
            .coreAnimation(keyPath: "opacity")

        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertTrue(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.fillMode, .removed)
    }

    func testPerceptualAnimationSupportsRuntimeInitialVelocity() {
        let spec = MotionSpec(duration: 0.4, bounce: 0.12, blendDuration: 0.08)

        XCTAssertNotNil(spec.swiftUIAnimation())
        XCTAssertNotNil(spec.swiftUIAnimation(initialVelocity: 2.5))
        XCTAssertNotNil(
            MotionPolicy.full.animation(
                for: spec,
                initialVelocity: -1.25
            )
        )
    }

    func testVisualCompletionDelayFollowsResolvedPolicy() {
        let spec = MotionSpec(duration: 0.4, bounce: 0.12)

        let fullDelay = MotionPolicy.full.visualCompletionDelay(
            for: spec,
            initialVelocity: 2
        )
        let reducedDelay = MotionPolicy.reduced.visualCompletionDelay(for: spec)

        XCTAssertGreaterThan(fullDelay, 0)
        XCTAssertGreaterThan(reducedDelay, 0)
        XCTAssertEqual(
            MotionPolicy.disabled.visualCompletionDelay(for: spec),
            0,
            accuracy: 0.0001
        )
    }

    func testInitialVelocityNormalizesAgainstTravelDistance() {
        XCTAssertEqual(
            MotionSpec.normalizedInitialVelocity(from: 20, to: 80, velocity: 120),
            2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MotionSpec.normalizedInitialVelocity(from: 80, to: 20, velocity: 120),
            -2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MotionSpec.normalizedInitialVelocity(from: 20, to: 20, velocity: 120),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MotionSpec.clampedInitialVelocity(12),
            8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MotionSpec.clampedInitialVelocity(-12, maximumMagnitude: 4),
            -4,
            accuracy: 0.0001
        )
    }

    func testPerceptualSpecClampsBounceAndPreservesBlendDuration() {
        let spec = MotionSpec(duration: 0.4, bounce: 2, blendDuration: 0.08)
        let negative = MotionSpec(duration: 0.4, bounce: -2)

        XCTAssertEqual(spec.bounce, 1, accuracy: 0.0001)
        XCTAssertEqual(spec.blendDuration, 0.08, accuracy: 0.0001)
        XCTAssertEqual(negative.bounce, -1, accuracy: 0.0001)
    }

    func testPhysicalSpecPreservesOverDampingOptIn() throws {
        let spec = MotionSpec(
            physical: MotionPhysicalParameters(
                stiffness: 120,
                damping: 40,
                allowOverDamping: true
            )
        )

        guard case let .physical(parameters) = spec.representation else {
            return XCTFail("Expected a physical motion representation")
        }

        XCTAssertTrue(parameters.allowOverDamping)
        XCTAssertEqual(parameters.stiffness, 120, accuracy: 0.0001)
        XCTAssertEqual(parameters.damping, 40, accuracy: 0.0001)
    }

    func testRetargetStartsAtTheCurrentValueWithRuntimeVelocity() {
        let spec = MotionSpec(duration: 0.42, bounce: 0.08)
        let evaluator = MotionSpringEvaluator(spec: spec)
        let current = evaluator.normalizedValue(at: 0.18)
        let retargeted = evaluator.value(
            from: current,
            to: 2,
            at: 0,
            initialVelocity: -0.75
        )

        XCTAssertEqual(retargeted, current, accuracy: 0.0001)
        XCTAssertNotEqual(
            evaluator.value(
                from: current,
                to: 2,
                at: 0.12,
                initialVelocity: -0.75
            ),
            current,
            accuracy: 0.0001
        )
    }

    func testRetargetStateCarriesPositionAndVelocityAcrossRetargets() {
        let spec = MotionSpec(duration: 0.42, bounce: 0.08)
        var state = MotionRetargetState(value: 0, spec: spec)

        state.retarget(to: 100, at: 0)
        let first = state.advance(to: 0.18)
        XCTAssertGreaterThan(first.value, 0)
        XCTAssertNotEqual(first.velocity, 0, accuracy: 0.0001)

        state.retarget(to: -40, at: 0.18)
        let second = state.advance(to: 0.18)
        XCTAssertEqual(second.value, first.value, accuracy: 0.0001)
        XCTAssertEqual(second.velocity, first.velocity, accuracy: 0.0001)

        let settled = state.advance(to: 0.18 + state.visualCompletionDelay)
        XCTAssertEqual(settled.value, -40, accuracy: 0.1)
    }

    func testRetargetStateCanSnapImmediately() {
        var state = MotionRetargetState(
            value: 10,
            velocity: 40,
            spec: MotionTokens.standard[.layout]
        )
        state.retarget(to: 80, at: 1)
        state.snap(to: 24)

        XCTAssertEqual(state.value, 24, accuracy: 0.0001)
        XCTAssertEqual(state.velocity, 0, accuracy: 0.0001)
        XCTAssertEqual(state.target, 24, accuracy: 0.0001)
        XCTAssertFalse(state.isAnimating)
    }

    func testMotionPolicyReducesBounceAndCanDisableAnimation() throws {
        let spec = MotionSpec(duration: 0.8, bounce: 0.3, blendDuration: 0.1)

        let reduced = try XCTUnwrap(MotionPolicy.reduced.resolve(spec))
        XCTAssertEqual(reduced.bounce, 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(reduced.duration, 0.20)
        XCTAssertNil(MotionPolicy.disabled.resolve(spec))
        XCTAssertNil(MotionPolicy.disabled.animation(for: spec))
    }

    func testAccessibilityReductionDoesNotOverrideExplicitDisable() {
        XCTAssertEqual(
            MotionPolicy.disabled.resolving(accessibilityReduceMotion: true),
            .disabled
        )
        XCTAssertEqual(
            MotionPolicy.full.resolving(accessibilityReduceMotion: true),
            .reduced
        )
    }

    func testResolvedAnimationAppliesAccessibilityPolicy() {
        let spec = MotionSpec(duration: 0.8, bounce: 0.3)

        XCTAssertNotNil(
            MotionPolicy.full.resolvedAnimation(
                for: spec,
                accessibilityReduceMotion: false
            )
        )
        XCTAssertNotNil(
            MotionPolicy.full.resolvedAnimation(
                for: spec,
                accessibilityReduceMotion: true
            )
        )
        XCTAssertNil(
            MotionPolicy.disabled.resolvedAnimation(
                for: spec,
                accessibilityReduceMotion: false
            )
        )
    }

    func testTokensCanBeOverriddenWithoutMutatingDefaults() {
        let customSpec = MotionSpec(duration: 0.52, bounce: 0.1)
        let customTokens = MotionTokens.standard.replacing(.layout, with: customSpec)

        XCTAssertEqual(customTokens[.layout], customSpec)
        XCTAssertNotEqual(MotionTokens.standard[.layout], customSpec)
    }

    func testDiagnosticsCaptureTokenPolicyBackendAndVelocity() {
        let diagnostic = MotionTokens.standard.diagnostic(
            for: .gestureSettle,
            policy: .full,
            backend: .swiftUI,
            initialVelocity: -1.25
        )

        XCTAssertEqual(diagnostic.token, .gestureSettle)
        XCTAssertEqual(diagnostic.policy, .full)
        XCTAssertEqual(diagnostic.backend, .swiftUI)
        XCTAssertTrue(diagnostic.enabled)
        XCTAssertTrue(diagnostic.usesDynamicInitialVelocity)
        XCTAssertTrue(diagnostic.description.contains("gestureSettle"))

        let disabled = MotionTokens.standard.diagnostic(
            for: .control,
            policy: .disabled,
            backend: .coreAnimation
        )
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(disabled.usesDynamicInitialVelocity)
    }

}
