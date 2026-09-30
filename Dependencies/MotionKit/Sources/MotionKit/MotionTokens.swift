import Foundation

public enum MotionToken: String, CaseIterable, Hashable, Sendable {
    case microInteraction
    case control
    case layout
    case navigation
    case gestureSettle
    case emphasis
    case contentReplacement
    case backgroundTransition
}

public struct MotionTokens: Hashable, Sendable {
    public var microInteraction: MotionSpec
    public var control: MotionSpec
    public var layout: MotionSpec
    public var navigation: MotionSpec
    public var gestureSettle: MotionSpec
    public var emphasis: MotionSpec
    public var contentReplacement: MotionSpec
    public var backgroundTransition: MotionSpec

    public init(
        microInteraction: MotionSpec,
        control: MotionSpec,
        layout: MotionSpec,
        navigation: MotionSpec,
        gestureSettle: MotionSpec,
        emphasis: MotionSpec,
        contentReplacement: MotionSpec,
        backgroundTransition: MotionSpec
    ) {
        self.microInteraction = microInteraction
        self.control = control
        self.layout = layout
        self.navigation = navigation
        self.gestureSettle = gestureSettle
        self.emphasis = emphasis
        self.contentReplacement = contentReplacement
        self.backgroundTransition = backgroundTransition
    }

    public static let standard = MotionTokens(
        microInteraction: MotionSpec(
            duration: 0.18,
            bounce: 0,
            blendDuration: 0.03
        ),
        control: MotionSpec(
            duration: 0.30,
            bounce: 0.04,
            blendDuration: 0.05
        ),
        layout: MotionSpec(
            duration: 0.46,
            bounce: 0.06,
            blendDuration: 0.08
        ),
        navigation: MotionSpec(
            duration: 0.56,
            bounce: 0.05,
            blendDuration: 0.10
        ),
        gestureSettle: MotionSpec(
            duration: 0.40,
            bounce: 0.14,
            blendDuration: 0.08
        ),
        emphasis: MotionSpec(
            duration: 0.40,
            bounce: 0.18,
            blendDuration: 0.08
        ),
        contentReplacement: MotionSpec(
            duration: 0.24,
            bounce: 0,
            blendDuration: 0.04
        ),
        backgroundTransition: MotionSpec(
            duration: 0.68,
            bounce: 0,
            blendDuration: 0.12
        )
    )

    public subscript(token: MotionToken) -> MotionSpec {
        get {
            switch token {
            case .microInteraction:
                microInteraction
            case .control:
                control
            case .layout:
                layout
            case .navigation:
                navigation
            case .gestureSettle:
                gestureSettle
            case .emphasis:
                emphasis
            case .contentReplacement:
                contentReplacement
            case .backgroundTransition:
                backgroundTransition
            }
        }
        set {
            switch token {
            case .microInteraction:
                microInteraction = newValue
            case .control:
                control = newValue
            case .layout:
                layout = newValue
            case .navigation:
                navigation = newValue
            case .gestureSettle:
                gestureSettle = newValue
            case .emphasis:
                emphasis = newValue
            case .contentReplacement:
                contentReplacement = newValue
            case .backgroundTransition:
                backgroundTransition = newValue
            }
        }
    }

    public func replacing(_ token: MotionToken, with spec: MotionSpec) -> MotionTokens {
        var copy = self
        copy[token] = spec
        return copy
    }

    public func phaseSpec(
        for token: MotionToken,
        duration: Double,
        bounce: Double? = nil,
        blendDuration: Double? = nil
    ) -> MotionSpec {
        let base = self[token]
        guard case .perceptual = base.representation else { return base }

        let standard = MotionTokens.standard[token]
        let durationScale = standard.duration > 0 ? base.duration / standard.duration : 1
        return MotionSpec(
            duration: max(0, duration) * durationScale,
            bounce: bounce ?? base.bounce,
            blendDuration: blendDuration ?? base.blendDuration
        )
    }

    public func diagnostic(
        for token: MotionToken,
        policy: MotionPolicy,
        backend: MotionBackend,
        initialVelocity: Double = 0
    ) -> MotionDiagnostic {
        MotionDiagnostic(
            token: token,
            policy: policy,
            backend: backend,
            initialVelocity: initialVelocity,
            enabled: policy.resolve(self[token]) != nil
        )
    }
}
