@preconcurrency import CrashReporter
import Darwin
import Foundation

@MainActor
final class CrashReporterBootstrap {
    static let shared = CrashReporterBootstrap()

    private let reporter: PLCrashReporter?
    private var isEnabled = false

    private init() {
        let configuration = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: []
        )
        reporter = PLCrashReporter(configuration: configuration)
    }

    func enable() {
        guard !isEnabled, let reporter else { return }
        guard !Self.isDebuggerAttached() else {
            Log.info(
                "[CrashReporting] PLCrashReporter disabled while a debugger is attached",
                category: .telemetry
            )
            return
        }
        do {
            try reporter.enableAndReturnError()
            isEnabled = true
            Log.info("[CrashReporting] PLCrashReporter enabled", category: .telemetry)
        } catch {
            Log.error(
                "[CrashReporting] Failed to enable PLCrashReporter: \(String(describing: error))",
                category: .telemetry
            )
        }
    }

    func pendingReportData() throws -> Data? {
        guard let reporter, reporter.hasPendingCrashReport() else { return nil }
        return try reporter.loadPendingCrashReportDataAndReturnError()
    }

    func purgePendingReport() {
        guard let reporter else { return }
        if !reporter.purgePendingCrashReport() {
            Log.warning("[CrashReporting] Failed to purge imported pending report", category: .telemetry)
        }
    }

    func setCustomData(_ data: Data) {
        reporter?.customData = data
    }

    /// PLCrashReporter's in-process Mach exception handler conflicts with LLDB.
    /// Detect P_TRACED before enabling it so a normal Xcode Command-R remains
    /// debuggable. Crash-capture testing must be launched without a debugger.
    private static func isDebuggerAttached() -> Bool {
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = name.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &processInfo, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return (processInfo.kp_proc.p_flag & P_TRACED) != 0
    }
}
