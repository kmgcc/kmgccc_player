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
        let delay = requestedDelaySeconds
        Log.warning(
            "[CrashReporting] DEBUG controlled crash scheduled mode=\(mode) delay=\(delay)s",
            category: .telemetry
        )

        switch mode {
        case "background-abort":
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                raise(SIGABRT)
            }
        case "main-segv":
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                triggerInvalidMemoryAccess()
            }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                raise(SIGABRT)
            }
        }
    }

    private static var requestedDelaySeconds: Double {
        guard let rawValue = ProcessInfo.processInfo.environment["KMGCCC_CRASH_TEST_DELAY_SECONDS"],
              let value = Double(rawValue),
              value.isFinite else {
            return 3
        }
        return min(max(value, 1), 300)
    }

    /// Produces a real EXC_BAD_ACCESS instead of merely sending SIGSEGV to the
    /// process. The PLCrashReporter Mach handler observes memory-access Mach
    /// exceptions; `raise(SIGSEGV)` only exercises the BSD signal path.
    @inline(never)
    private static func triggerInvalidMemoryAccess() -> Never {
        let invalidAddress = UnsafeMutableRawPointer(bitPattern: 0x1)!
        invalidAddress.storeBytes(of: UInt8(0xA5), as: UInt8.self)
        fatalError("Invalid memory access unexpectedly returned")
    }
}
#endif
