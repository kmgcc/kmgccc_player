//
//  FullscreenHostLifecycleInvariant.swift
//  kmgccc_player
//
//  DEBUG-only invariant for the fullscreen host release list.
//

#if DEBUG
import Foundation

/// `handleFullscreenDisappear` releases roughly forty registrations, tasks and caches by
/// hand. Forgetting one still compiles and no test mounts this host, so the leak only
/// shows up as a lingering audio consumer or meter lease at runtime.
///
/// Capture the shared counters when the host appears, compare them after teardown, and
/// report growth. This never blocks playback: it logs, and only traps when
/// `KMGCCC_FULLSCREEN_INVARIANT_STRICT=1` is set for a deliberate run.
@MainActor
enum FullscreenHostLifecycleInvariant {
    struct Snapshot: Equatable {
        let audioConsumers: Int
        let meterSessions: Int
    }

    static func capture(meter: LEDMeterServiceProvider) -> Snapshot {
        Snapshot(
            audioConsumers: AudioAnalysisHub.shared.skinDebugConsumerCount,
            meterSessions: meter.skinDebugSessionCount
        )
    }

    /// Child views release their own sessions during their `onDisappear`, which can run
    /// after the host handler, so the comparison waits for teardown to settle.
    static func verify(
        baseline: Snapshot,
        context: String,
        meter: LEDMeterServiceProvider,
        after delay: Duration = .milliseconds(800)
    ) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }

        let current = capture(meter: meter)
        var violations: [String] = []
        if current.audioConsumers > baseline.audioConsumers {
            violations.append("audio consumers \(baseline.audioConsumers) → \(current.audioConsumers)")
        }
        if current.meterSessions > baseline.meterSessions {
            violations.append("meter sessions \(baseline.meterSessions) → \(current.meterSessions)")
        }
        if NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)?.isRenderingActive == true {
            violations.append("fullscreen lyrics surface still rendering")
        }
        guard !violations.isEmpty else { return }

        let message = "[FullscreenInvariant] teardown left resources behind context=\(context): \(violations.joined(separator: "; "))"
        Log.error(message, category: .ui)
        if ProcessInfo.processInfo.environment["KMGCCC_FULLSCREEN_INVARIANT_STRICT"] == "1" {
            assertionFailure(message)
        }
    }
}
#endif
