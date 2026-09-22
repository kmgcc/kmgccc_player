import Foundation

public struct MotionRetargetState {
    public let spec: MotionSpec
    public private(set) var value: Double
    public private(set) var velocity: Double
    public private(set) var target: Double

    private var evaluator: MotionSpringEvaluator?
    private var startTime: TimeInterval?
    private var startValue: Double
    private var normalizedInitialVelocity = 0.0

    public init(
        value: Double = 0,
        velocity: Double = 0,
        target: Double? = nil,
        spec: MotionSpec
    ) {
        self.spec = spec
        self.value = value
        self.velocity = velocity
        self.target = target ?? value
        self.startValue = value
    }

    public var isAnimating: Bool {
        startTime != nil
    }

    public var visualCompletionDelay: TimeInterval {
        spec.visualCompletionDelay(initialVelocity: normalizedInitialVelocity)
    }

    public mutating func retarget(to target: Double, at time: TimeInterval) {
        let current = advance(to: time)
        value = current.value
        velocity = current.velocity
        startValue = current.value
        self.target = target
        normalizedInitialVelocity = MotionSpec.clampedInitialVelocity(
            MotionSpec.normalizedInitialVelocity(
                from: current.value,
                to: target,
                velocity: current.velocity
            )
        )
        startTime = time
        evaluator = MotionSpringEvaluator(spec: spec)
    }

    @discardableResult
    public mutating func advance(to time: TimeInterval) -> (value: Double, velocity: Double) {
        guard let startTime, let evaluator else {
            return (value, velocity)
        }

        let elapsed = max(0, time - startTime)
        value = evaluator.value(
            from: startValue,
            to: target,
            at: elapsed,
            initialVelocity: normalizedInitialVelocity
        )
        velocity = evaluator.velocity(
            from: startValue,
            to: target,
            at: elapsed,
            initialVelocity: normalizedInitialVelocity
        )
        return (value, velocity)
    }

    public mutating func isSettled(
        at time: TimeInterval,
        positionEpsilon: Double = 0.001,
        velocityEpsilon: Double = 0.001
    ) -> Bool {
        let state = advance(to: time)
        return abs(state.value - target) <= max(0, positionEpsilon)
            && abs(state.velocity) <= max(0, velocityEpsilon)
    }

    public mutating func snap(to value: Double) {
        self.value = value
        velocity = 0
        target = value
        startValue = value
        evaluator = nil
        startTime = nil
        normalizedInitialVelocity = 0
    }
}
