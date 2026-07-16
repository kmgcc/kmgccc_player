#if DEBUG
import Darwin
import Foundation

enum DebugCrashTrigger {
    private static var didSchedule = false

    @MainActor
    static func scheduleIfRequested() {
        guard !didSchedule,
              let mode = ProcessInfo.processInfo.environment["KMGCCC_CRASH_TEST_MODE"],
              ["main-abort", "background-abort", "main-segv"].contains(mode)
        else { return }
        didSchedule = true
        Log.warning(
            "[CrashReporting] DEBUG controlled crash scheduled mode=\(mode)",
            category: .telemetry
        )

        switch mode {
        case "background-abort":
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                raise(SIGABRT)
            }
        case "main-segv":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                raise(SIGSEGV)
            }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                raise(SIGABRT)
            }
        }
    }
}
#endif
