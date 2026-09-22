import Foundation
import QuartzCore
import SwiftUI

public struct MotionPhysicalParameters: Hashable, Sendable {
    public var mass: Double
    public var stiffness: Double
    public var damping: Double
    public var allowOverDamping: Bool

    public init(
        mass: Double = 1,
        stiffness: Double,
        damping: Double,
        allowOverDamping: Bool = false
    ) {
        self.mass = max(0.0001, mass)
        self.stiffness = max(0, stiffness)
        self.damping = max(0, damping)
        self.allowOverDamping = allowOverDamping
    }
}

public struct MotionSpec: Hashable, Sendable {
    public enum Representation: Hashable, Sendable {
        case perceptual
        case physical(MotionPhysicalParameters)
    }

    public let duration: Double
    public let bounce: Double
    public let blendDuration: Double
    public let representation: Representation

    public init(
        duration: Double,
        bounce: Double = 0,
        blendDuration: Double = 0
    ) {
        self.duration = max(0, duration)
        self.bounce = min(max(bounce, -1), 1)
        self.blendDuration = max(0, blendDuration)
        self.representation = .perceptual
    }

    public init(
        physical parameters: MotionPhysicalParameters,
        blendDuration: Double = 0
    ) {
        self.duration = 0
        self.bounce = 0
        self.blendDuration = max(0, blendDuration)
        self.representation = .physical(parameters)
    }

    public static func normalizedInitialVelocity(
        from: Double,
        to: Double,
        velocity: Double
    ) -> Double {
        let distance = to - from
        guard abs(distance) > .leastNonzeroMagnitude else { return 0 }
        return velocity / distance
    }

    public static func clampedInitialVelocity(
        _ velocity: Double,
        maximumMagnitude: Double = 8
    ) -> Double {
        let limit = max(0, maximumMagnitude)
        guard velocity.isFinite else { return 0 }
        return min(max(velocity, -limit), limit)
    }

    public var spring: Spring {
        switch representation {
        case .perceptual:
            Spring(duration: duration, bounce: bounce)
        case let .physical(parameters):
            Spring(
                mass: parameters.mass,
                stiffness: parameters.stiffness,
                damping: parameters.damping,
                allowOverDamping: parameters.allowOverDamping
            )
        }
    }

    public func swiftUIAnimation(initialVelocity: Double = 0) -> Animation {
        switch representation {
        case .perceptual:
            if abs(initialVelocity) > .leastNonzeroMagnitude {
                .interpolatingSpring(
                    spring,
                    initialVelocity: initialVelocity
                )
            } else {
                .spring(
                    spring,
                    blendDuration: blendDuration
                )
            }
        case let .physical(parameters):
            .interpolatingSpring(
                mass: parameters.mass,
                stiffness: parameters.stiffness,
                damping: parameters.damping,
                initialVelocity: initialVelocity
            )
        }
    }

    public func coreAnimation(
        keyPath: String? = nil,
        initialVelocity: Double = 0
    ) -> CASpringAnimation {
        let animation: CASpringAnimation

        switch representation {
        case .perceptual:
            animation = CASpringAnimation(
                perceptualDuration: duration,
                bounce: bounce
            )
        case let .physical(parameters):
            animation = CASpringAnimation()
            animation.mass = parameters.mass
            animation.stiffness = parameters.stiffness
            animation.damping = parameters.damping
        }

        animation.keyPath = keyPath
        animation.initialVelocity = initialVelocity
        animation.duration = animation.settlingDuration
        return animation
    }

    /// Returns the settling window for visual cleanup work only.
    ///
    /// This is not a business-operation completion time. Use an explicit
    /// state transition or completion callback when the result of an
    /// operation depends on completion.
    public func visualCompletionDelay(initialVelocity: Double = 0) -> TimeInterval {
        let animation = coreAnimation(initialVelocity: initialVelocity)
        let delay = animation.settlingDuration
        return delay.isFinite ? max(0, delay) : max(0, duration)
    }

    public func reducedMotionSpec() -> MotionSpec {
        MotionSpec(
            duration: min(max(duration == 0 ? 0.18 : duration, 0.12), 0.20),
            bounce: 0,
            blendDuration: 0
        )
    }
}
