import SwiftUI

public enum MotionPolicy: String, CaseIterable, Hashable, Sendable {
    case full
    case reduced
    case disabled

    public static func system(accessibilityReduceMotion: Bool) -> MotionPolicy {
        MotionPolicy.full.resolving(accessibilityReduceMotion: accessibilityReduceMotion)
    }

    public func resolving(accessibilityReduceMotion: Bool) -> MotionPolicy {
        guard self != .disabled else { return .disabled }
        return accessibilityReduceMotion ? .reduced : self
    }

    public func resolve(_ spec: MotionSpec) -> MotionSpec? {
        switch self {
        case .full:
            spec
        case .reduced:
            spec.reducedMotionSpec()
        case .disabled:
            nil
        }
    }

    public func animation(
        for spec: MotionSpec,
        initialVelocity: Double = 0
    ) -> Animation? {
        resolve(spec)?.swiftUIAnimation(initialVelocity: initialVelocity)
    }

    public func resolvedAnimation(
        for spec: MotionSpec,
        accessibilityReduceMotion: Bool,
        initialVelocity: Double = 0
    ) -> Animation? {
        resolving(accessibilityReduceMotion: accessibilityReduceMotion)
            .animation(for: spec, initialVelocity: initialVelocity)
    }

    /// Returns a visual cleanup window for the policy-resolved spring.
    ///
    /// A disabled policy returns zero so callers can clear transient render
    /// state immediately. This helper must not gate business state changes.
    public func visualCompletionDelay(
        for spec: MotionSpec,
        initialVelocity: Double = 0
    ) -> TimeInterval {
        resolve(spec)?.visualCompletionDelay(initialVelocity: initialVelocity) ?? 0
    }
}
