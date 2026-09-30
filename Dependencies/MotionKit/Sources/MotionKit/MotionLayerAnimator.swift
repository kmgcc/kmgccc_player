import QuartzCore

public enum MotionLayerAnimator {
    @discardableResult
    public static func animate(
        layer: CALayer,
        keyPath: String,
        fromValue: Any?,
        toValue: Any?,
        spec: MotionSpec,
        policy: MotionPolicy,
        initialVelocity: Double = 0,
        animationKey: String = "motionKit.spring"
    ) -> TimeInterval {
        layer.removeAnimation(forKey: animationKey)
        layer.setValue(toValue, forKeyPath: keyPath)

        guard let resolvedSpec = policy.resolve(spec) else {
            return 0
        }

        let animation = resolvedSpec.coreAnimation(
            keyPath: keyPath,
            initialVelocity: initialVelocity
        )
        animation.fromValue = fromValue
        animation.toValue = toValue
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: animationKey)
        return resolvedSpec.visualCompletionDelay(initialVelocity: initialVelocity)
    }
}
