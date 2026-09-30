import SwiftUI

private struct MotionTokensEnvironmentKey: EnvironmentKey {
    static let defaultValue = MotionTokens.standard
}

private struct MotionPolicyEnvironmentKey: EnvironmentKey {
    static let defaultValue = MotionPolicy.full
}

public extension EnvironmentValues {
    var motionTokens: MotionTokens {
        get { self[MotionTokensEnvironmentKey.self] }
        set { self[MotionTokensEnvironmentKey.self] = newValue }
    }

    var motionPolicy: MotionPolicy {
        get { self[MotionPolicyEnvironmentKey.self] }
        set { self[MotionPolicyEnvironmentKey.self] = newValue }
    }
}

public extension View {
    func motionTokens(_ tokens: MotionTokens) -> some View {
        environment(\.motionTokens, tokens)
    }

    func motionPolicy(_ policy: MotionPolicy) -> some View {
        environment(\.motionPolicy, policy)
    }

    func motionEnvironment(
        tokens: MotionTokens = .standard,
        policy: MotionPolicy = .full
    ) -> some View {
        motionTokens(tokens)
            .motionPolicy(policy)
    }

    func motionAnimation<Value: Equatable>(
        _ token: MotionToken,
        value: Value,
        enabled: Bool = true
    ) -> some View {
        modifier(
            MotionTokenAnimationModifier(
                token: token,
                value: value,
                enabled: enabled
            )
        )
    }

    func motionAnimation<Value: Equatable>(
        _ spec: MotionSpec,
        value: Value,
        enabled: Bool = true
    ) -> some View {
        modifier(
            MotionSpecAnimationModifier(
                spec: spec,
                value: value,
                enabled: enabled
            )
        )
    }
}

private struct MotionTokenAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.motionTokens) private var motionTokens

    let token: MotionToken
    let value: Value
    let enabled: Bool

    func body(content: Content) -> some View {
        content.modifier(
            MotionSpecAnimationModifier(
                spec: motionTokens[token],
                value: value,
                enabled: enabled
            )
        )
    }
}

private struct MotionSpecAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let spec: MotionSpec
    let value: Value
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.animation(
                motionPolicy.resolvedAnimation(
                    for: spec,
                    accessibilityReduceMotion: accessibilityReduceMotion
                ),
                value: value
            )
        } else {
            content.animation(nil, value: value)
        }
    }
}
