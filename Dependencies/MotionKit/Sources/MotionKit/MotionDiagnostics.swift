import Foundation

public enum MotionBackend: String, CaseIterable, Hashable, Sendable {
    case swiftUI
    case coreAnimation
    case displayLinkEvaluator
}

public struct MotionDiagnostic: Hashable, Sendable, CustomStringConvertible {
    public let token: MotionToken?
    public let policy: MotionPolicy
    public let backend: MotionBackend
    public let initialVelocity: Double
    public let enabled: Bool

    public init(
        token: MotionToken? = nil,
        policy: MotionPolicy,
        backend: MotionBackend,
        initialVelocity: Double = 0,
        enabled: Bool
    ) {
        self.token = token
        self.policy = policy
        self.backend = backend
        self.initialVelocity = initialVelocity.isFinite ? initialVelocity : 0
        self.enabled = enabled
    }

    public var usesDynamicInitialVelocity: Bool {
        abs(initialVelocity) > .leastNonzeroMagnitude
    }

    public var description: String {
        let tokenName = token?.rawValue ?? "custom"
        return "MotionDiagnostic(token=\(tokenName), policy=\(policy.rawValue), backend=\(backend.rawValue), enabled=\(enabled), initialVelocity=\(initialVelocity))"
    }
}
