import Foundation
import SwiftUI

public struct MotionSpringEvaluator {
    public let spring: Spring

    public init(spec: MotionSpec) {
        self.spring = spec.spring
    }

    public func normalizedValue(
        at time: TimeInterval,
        initialVelocity: Double = 0
    ) -> Double {
        spring.value(
            target: 1,
            initialVelocity: initialVelocity,
            time: max(0, time)
        )
    }

    public func normalizedVelocity(
        at time: TimeInterval,
        initialVelocity: Double = 0
    ) -> Double {
        spring.velocity(
            target: 1,
            initialVelocity: initialVelocity,
            time: max(0, time)
        )
    }

    public func value(
        from: Double = 0,
        to: Double = 1,
        at time: TimeInterval,
        initialVelocity: Double = 0
    ) -> Double {
        from + (to - from) * normalizedValue(
            at: time,
            initialVelocity: initialVelocity
        )
    }

    public func velocity(
        from: Double = 0,
        to: Double = 1,
        at time: TimeInterval,
        initialVelocity: Double = 0
    ) -> Double {
        (to - from) * normalizedVelocity(
            at: time,
            initialVelocity: initialVelocity
        )
    }
}
