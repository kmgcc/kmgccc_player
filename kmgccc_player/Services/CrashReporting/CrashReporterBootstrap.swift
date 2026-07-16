@preconcurrency import CrashReporter
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
}
