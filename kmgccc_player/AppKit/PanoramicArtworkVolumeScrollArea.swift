import AppKit
import SwiftUI

// MARK: - Panoramic artwork volume input

/// AppKit bridge for scroll-wheel input that does not become the hit-test target
/// for clicks. SwiftUI continues to own and render the volume state and HUD.
struct PanoramicArtworkVolumeScrollArea: NSViewRepresentable {
    @Binding var volume: Double
    let isEnabled: Bool
    let onAdjustment: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            volume: $volume,
            isEnabled: isEnabled,
            onAdjustment: onAdjustment
        )
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.installMonitor(for: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.update(
            volume: $volume,
            isEnabled: isEnabled,
            onAdjustment: onAdjustment
        )
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        private static let preciseDetentDistance: CGFloat = 24
        private static let preciseVolumeStep = 0.005
        private static let wheelVolumeStep = 0.005
        private static let maximumVolumeAdjustmentPerEvent = 0.02
        private static let maximumAccelerationMultiplier = 2.0
        private static let preciseAccelerationStartVelocity: CGFloat = 500
        private static let preciseAccelerationFullVelocity: CGFloat = 2_200
        private static let wheelAccelerationStartRate = 14.0
        private static let wheelAccelerationFullRate = 36.0

        private var volume: Binding<Double>
        private var isEnabled: Bool
        private var onAdjustment: (Double) -> Void
        private weak var monitoredView: PassthroughView?
        private var eventMonitor: Any?
        private var preciseAccumulator: CGFloat = 0
        private var smoothedPreciseVelocity: CGFloat = 0
        private var lastPreciseEventTimestamp: TimeInterval?
        private var lastWheelEventTimestamp: TimeInterval?

        init(
            volume: Binding<Double>,
            isEnabled: Bool,
            onAdjustment: @escaping (Double) -> Void
        ) {
            self.volume = volume
            self.isEnabled = isEnabled
            self.onAdjustment = onAdjustment
        }

        func update(
            volume: Binding<Double>,
            isEnabled: Bool,
            onAdjustment: @escaping (Double) -> Void
        ) {
            self.volume = volume
            self.isEnabled = isEnabled
            self.onAdjustment = onAdjustment
        }

        func installMonitor(for view: PassthroughView) {
            monitoredView = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self, weak view] event in
                guard let self, let view else { return event }
                self.handle(event, in: view)
                return event
            }
        }

        func removeMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            resetScrollMotion()
        }

        private func handle(_ event: NSEvent, in view: PassthroughView) {
            let point = view.convert(event.locationInWindow, from: nil)
            guard isEnabled,
                  event.window === view.window,
                  Self.centralInteractionRect(in: view.bounds).contains(point)
            else {
                return
            }

            let delta = event.scrollingDeltaY
            guard delta.isFinite, abs(delta) > 0.001 else { return }

            if event.hasPreciseScrollingDeltas {
                if event.phase == .began {
                    resetPreciseMotion()
                }
                if !event.momentumPhase.isEmpty {
                    return
                }

                if preciseAccumulator != 0,
                   preciseAccumulator.sign != delta.sign
                {
                    resetPreciseMotion()
                }

                let accelerationMultiplier = preciseAccelerationMultiplier(
                    delta: delta,
                    timestamp: event.timestamp
                )
                preciseAccumulator += delta
                let detentCount = Int(abs(preciseAccumulator) / Self.preciseDetentDistance)
                guard detentCount > 0 else { return }

                let inputDirection = preciseAccumulator.sign == .minus ? -1.0 : 1.0
                let volumeDirection = -inputDirection
                preciseAccumulator -= CGFloat(detentCount) * Self.preciseDetentDistance
                    * CGFloat(inputDirection)
                apply(
                    adjustment: acceleratedAdjustment(
                        direction: volumeDirection,
                        detentCount: min(detentCount, 6),
                        baseStep: Self.preciseVolumeStep,
                        multiplier: accelerationMultiplier
                    ),
                    performsHapticFeedback: true
                )

                if event.phase == .ended || event.phase == .cancelled {
                    resetPreciseMotion()
                }
            } else {
                let volumeDirection = delta.sign == .minus ? 1.0 : -1.0
                let detentCount = min(3, max(1, Int(abs(delta).rounded(.up))))
                apply(
                    adjustment: acceleratedAdjustment(
                        direction: volumeDirection,
                        detentCount: detentCount,
                        baseStep: Self.wheelVolumeStep,
                        multiplier: wheelAccelerationMultiplier(timestamp: event.timestamp)
                    ),
                    performsHapticFeedback: false
                )
            }
        }

        private func preciseAccelerationMultiplier(
            delta: CGFloat,
            timestamp: TimeInterval
        ) -> Double {
            let elapsed: TimeInterval
            if let lastPreciseEventTimestamp {
                elapsed = timestamp - lastPreciseEventTimestamp
            } else {
                elapsed = 1.0 / 60.0
            }
            lastPreciseEventTimestamp = timestamp

            let clampedElapsed = max(1.0 / 240.0, min(elapsed, 0.12))
            let instantaneousVelocity = abs(delta) / CGFloat(clampedElapsed)
            if elapsed <= 0 || elapsed > 0.12 || smoothedPreciseVelocity == 0 {
                smoothedPreciseVelocity = instantaneousVelocity
            } else {
                smoothedPreciseVelocity =
                    smoothedPreciseVelocity * 0.65
                    + instantaneousVelocity * 0.35
            }

            return Self.accelerationMultiplier(
                value: Double(smoothedPreciseVelocity),
                start: Double(Self.preciseAccelerationStartVelocity),
                full: Double(Self.preciseAccelerationFullVelocity)
            )
        }

        private func wheelAccelerationMultiplier(timestamp: TimeInterval) -> Double {
            defer { lastWheelEventTimestamp = timestamp }
            guard let lastWheelEventTimestamp else { return 1 }

            let elapsed = timestamp - lastWheelEventTimestamp
            guard elapsed > 0, elapsed < 0.24 else { return 1 }

            return Self.accelerationMultiplier(
                value: 1.0 / elapsed,
                start: Self.wheelAccelerationStartRate,
                full: Self.wheelAccelerationFullRate
            )
        }

        private static func accelerationMultiplier(
            value: Double,
            start: Double,
            full: Double
        ) -> Double {
            let progress = min(1, max(0, (value - start) / (full - start)))
            let easedProgress = progress * progress * (3 - 2 * progress)
            return 1 + easedProgress * (maximumAccelerationMultiplier - 1)
        }

        private func acceleratedAdjustment(
            direction: Double,
            detentCount: Int,
            baseStep: Double,
            multiplier: Double
        ) -> Double {
            let magnitude = min(
                Self.maximumVolumeAdjustmentPerEvent,
                Double(detentCount) * baseStep * multiplier
            )
            return direction * magnitude
        }

        private func resetPreciseMotion() {
            preciseAccumulator = 0
            smoothedPreciseVelocity = 0
            lastPreciseEventTimestamp = nil
        }

        private func resetScrollMotion() {
            resetPreciseMotion()
            lastWheelEventTimestamp = nil
        }

        private func apply(
            adjustment: Double,
                performsHapticFeedback: Bool
            ) {
            let currentVolume = volume.wrappedValue
            let proposedVolume = VolumeControlBehavior.clamped(currentVolume + adjustment)
            guard abs(proposedVolume - currentVolume) > 0.0001 else { return }

            onAdjustment(proposedVolume - currentVolume)
            if performsHapticFeedback {
                VolumeControlBehavior.performDefaultSnapFeedback()
            }
        }

        /// Keep wheel volume control inside the visual center of the cover.
        /// The AppKit monitor is intentionally pass-through, so using the
        /// whole artwork frame here made a wheel gesture that finished beside
        /// the lyrics or over another control still adjust volume.
        private static func centralInteractionRect(in bounds: CGRect) -> CGRect {
            let width = max(1, bounds.width * 0.68)
            let height = max(1, bounds.height * 0.68)
            return CGRect(
                x: bounds.midX - width * 0.5,
                y: bounds.midY - height * 0.5,
                width: width,
                height: height
            )
        }
    }
}
