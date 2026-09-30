import MotionKit
import SwiftUI

@main
struct MotionKitDemoApp: App {
    var body: some Scene {
        WindowGroup("MotionKit Demo") {
            MotionKitDemoRoot()
                .frame(minWidth: 560, minHeight: 520)
        }
    }
}

private struct MotionKitDemoRoot: View {
    @State private var policy: MotionPolicy = .full
    @State private var usesCustomLayoutToken = false

    private var tokens: MotionTokens {
        guard usesCustomLayoutToken else { return .standard }
        return .standard.replacing(
            .layout,
            with: MotionSpec(duration: 0.62, bounce: 0.10, blendDuration: 0.10)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MotionKit")
                    .font(.title2.weight(.semibold))

                Text("统一验证 token、Reduce Motion、连续 retarget 和拖拽初速度。")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Picker("Policy", selection: $policy) {
                        ForEach(MotionPolicy.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized)
                                .tag(value)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("自定义 layout token", isOn: $usesCustomLayoutToken)
                        .toggleStyle(.checkbox)
                }
            }

            MotionKitDemoContent()
        }
        .padding(28)
        .motionEnvironment(tokens: tokens, policy: policy)
    }
}

private struct MotionKitDemoContent: View {
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false
    @State private var dragOffset: CGFloat = 0
    @State private var retargetedValue = 0
    @State private var lastInitialVelocity = 0.0

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Button(isExpanded ? "收起面板" : "展开面板") {
                    withAnimation(motionPolicy.animation(for: motionTokens[.layout])) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("连续 retarget") {
                    withAnimation(motionPolicy.animation(for: motionTokens[.emphasis])) {
                        retargetedValue = retargetedValue == 0 ? 1 : 0
                    }
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("布局与内容状态")
                    .font(.headline)

                RoundedRectangle(cornerRadius: 14)
                    .fill(.blue.opacity(0.18))
                    .frame(height: isExpanded ? 130 : 52)
                    .overlay {
                        Text(isExpanded ? "Layout token" : "Collapsed")
                            .foregroundStyle(.blue)
                    }
                    .motionAnimation(.layout, value: isExpanded)

                Text(retargetedValue == 0 ? "等待 retarget" : "已重新目标化")
                    .foregroundStyle(.secondary)
                    .motionAnimation(.contentReplacement, value: retargetedValue)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("拖拽 settle")
                    .font(.headline)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.gray.opacity(0.12))
                        .frame(height: 90)

                    Circle()
                        .fill(.orange.gradient)
                        .frame(width: 56, height: 56)
                        .offset(x: dragOffset)
                        .gesture(dragGesture)
                }

                Text("释放时把测得的速度归一化后传给 gestureSettle token。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    motionTokens.diagnostic(
                        for: .gestureSettle,
                        policy: motionPolicy,
                        backend: .swiftUI,
                        initialVelocity: lastInitialVelocity
                    ).description
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                let target = value.translation.width >= 0 ? 170.0 : -170.0
                let initialVelocity = MotionSpec.clampedInitialVelocity(
                    MotionSpec.normalizedInitialVelocity(
                        from: Double(value.translation.width),
                        to: target,
                        velocity: Double(value.velocity.width)
                    )
                )
                lastInitialVelocity = initialVelocity

                withAnimation(
                    motionPolicy.animation(
                        for: motionTokens[.gestureSettle],
                        initialVelocity: initialVelocity
                    )
                ) {
                    dragOffset = target
                }
            }
    }
}
