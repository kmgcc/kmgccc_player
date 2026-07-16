import AppKit
import Combine
import Foundation

@MainActor
final class CrashReportService: ObservableObject {
    static let shared = CrashReportService()

    @Published private(set) var currentPrompt: CrashReportPromptPresentation?
    @Published private(set) var isPromptFlowActive = false

    private let bootstrap: CrashReporterBootstrap
    private let store: CrashReportStore
    private let uploader: CrashReportUploader
    private let defaults: UserDefaults
    private var hasStarted = false
    private var workerTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var promptQueueDrainedHandler: (() -> Void)?

    private init(
        bootstrap: CrashReporterBootstrap = .shared,
        store: CrashReportStore = .shared,
        uploader: CrashReportUploader = CrashReportUploader(),
        defaults: UserDefaults = .standard
    ) {
        self.bootstrap = bootstrap
        self.store = store
        self.uploader = uploader
        self.defaults = defaults
    }

    var hasPendingPrompt: Bool {
        currentPrompt != nil
    }

    func start(anonymousInstallID: String) async {
        guard !hasStarted else { return }
        hasStarted = true
        installActivationObserverIfNeeded()
        await importPendingReportIfNeeded(anonymousInstallID: anonymousInstallID)
        await normalizeInterruptedStates()
        isPromptFlowActive = await store.records().contains {
            $0.promptState == .pending || $0.promptState == .presenting
        }

        // Start an automatic delivery attempt before publishing the prompt. The
        // request remains asynchronous, so an offline server never delays the UI.
        scheduleDelivery()
        await Task.yield()
        await presentNextPromptIfNeeded()
    }

    func setPromptQueueDrainedHandler(_ handler: @escaping () -> Void) {
        promptQueueDrainedHandler = handler
    }

    func automaticUploadPreferenceDidChange(_ enabled: Bool) {
        if let prompt = currentPrompt {
            currentPrompt = CrashReportPromptPresentation(
                reportID: prompt.reportID,
                occurredAt: prompt.occurredAt,
                appVersion: prompt.appVersion,
                automaticUploadEnabled: enabled
            )
        }
        scheduleDelivery()
    }

    func cancelCurrentPrompt() {
        guard let prompt = currentPrompt else { return }
        currentPrompt = nil
        Task {
            guard var record = await store.record(reportID: prompt.reportID) else {
                await advancePromptQueue()
                return
            }
            if automaticUploadEnabled {
                record.promptState = .cancelled
                record.promptedAt = Date()
                try? await store.save(record)
            } else {
                try? await store.remove(reportID: record.report.reportID)
            }
            scheduleDelivery()
            await advancePromptQueue()
        }
    }

    func sendCurrentPrompt(description: String) {
        guard let prompt = currentPrompt else { return }
        currentPrompt = nil
        Task {
            guard var record = await store.record(reportID: prompt.reportID) else {
                await advancePromptQueue()
                return
            }
            let cleanDescription = sanitizedUserDescription(description, report: record.report)
            let technicalReportAlreadySent = record.technicalUploadState == .uploaded

            record.promptState = .sent
            record.promptedAt = Date()
            record.userContext = cleanDescription
            // Persist explicit user authorization independently from the
            // preference. A later settings change must not cancel a send the
            // user already confirmed in this sheet.
            record.report.uploadMode = .userConfirmed

            if automaticUploadEnabled || technicalReportAlreadySent {
                record.userContextRevisionID = record.userContextRevisionID ?? UUID().uuidString.lowercased()
                record.userContextUploadState = .pending
                record.report.userDescription = nil
            } else {
                record.report.uploadMode = .userConfirmed
                record.report.userDescription = cleanDescription
                record.userContextUploadState = .notNeeded
            }

            do {
                try await store.save(record)
            } catch {
                Log.error("[CrashReporting] Failed to persist prompt response", category: .telemetry)
            }
            scheduleDelivery()
            await advancePromptQueue()
        }
    }

    private var automaticUploadEnabled: Bool {
        CrashReportPreferences.automaticUploadEnabled(defaults: defaults)
    }

    private func importPendingReportIfNeeded(anonymousInstallID: String) async {
        let pendingData: Data
        do {
            guard let data = try bootstrap.pendingReportData() else { return }
            pendingData = data
        } catch {
            Log.warning("[CrashReporting] Failed to inspect pending report", category: .telemetry)
            return
        }

        let libraryRootURL = LocalLibraryPaths.libraryRootURL
        let appDataRootURL = CrashReportPaths.applicationSupport
        do {
            let converted = try await Task.detached(priority: .utility) {
                let envelope = try PLCrashReportConverter.convert(
                    data: pendingData,
                    anonymousInstallID: anonymousInstallID
                )
                return CrashReportSanitizer(
                    libraryRootURL: libraryRootURL,
                    appDataRootURL: appDataRootURL
                ).sanitize(envelope)
            }.value
            try await store.save(.pending(report: converted))
            bootstrap.purgePendingReport()
            Log.info(
                "[CrashReporting] Imported pending report id=\(converted.reportID.prefix(8))",
                category: .telemetry
            )
        } catch {
            Log.error("[CrashReporting] Pending report import failed", category: .telemetry)
        }
    }

    private func normalizeInterruptedStates() async {
        for var record in await store.records() {
            var changed = false
            if record.technicalUploadState == .uploading {
                record.technicalUploadState = .failed
                record.nextRetryAt = nil
                changed = true
            }
            if record.promptState == .presenting {
                record.promptState = .pending
                changed = true
            }
            if changed {
                try? await store.save(record)
            }
        }
    }

    private func scheduleDelivery() {
        workerTask?.cancel()
        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await deliverReadyRecords()
                guard !Task.isCancelled else { return }
                let delay = await nextWorkerDelay()
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func deliverReadyRecords() async {
        let now = Date()
        let records = await store.records()
        for record in records {
            guard !Task.isCancelled else { return }
            if let nextRetryAt = record.nextRetryAt, nextRetryAt > now { continue }
            await deliver(record)
        }
    }

    private func deliver(_ source: CrashReportRecord) async {
        var record = source
        if record.technicalUploadState == .pending || record.technicalUploadState == .failed {
            let isUserAuthorized = record.report.uploadMode == .userConfirmed
            guard automaticUploadEnabled || isUserAuthorized else { return }

            record.technicalUploadState = .uploading
            record.nextRetryAt = nil
            try? await store.save(record)
            do {
                try await uploader.uploadTechnicalReport(record.report)
                record.technicalUploadState = .uploaded
                record.technicalUploadedAt = Date()
                record.attemptCount = 0
                record.nextRetryAt = nil
                record.lastErrorCategory = nil
                try await store.save(record)
                Log.info(
                    "[CrashReporting] Technical report uploaded id=\(record.id.prefix(8))",
                    category: .telemetry
                )
            } catch is CancellationError {
                // The prompt may have deleted the record while this request
                // was being cancelled. Only reset a record that still exists;
                // otherwise an old worker could resurrect a declined report.
                if var latest = await store.record(reportID: record.report.reportID) {
                    latest.technicalUploadState = .pending
                    latest.nextRetryAt = nil
                    try? await store.save(latest)
                }
                return
            } catch let error as CrashReportDeliveryError {
                if error == .unauthorized,
                   await recoverDiagnosticAuthorization(for: &record, userContext: false) {
                    try? await store.save(record)
                    return
                }
                applyDeliveryFailure(error, to: &record)
                try? await store.save(record)
                return
            } catch {
                applyRetryableFailure(to: &record, category: "transport")
                try? await store.save(record)
                return
            }
        }

        guard record.technicalUploadState == .uploaded else { return }
        if record.userContextUploadState == .pending,
           let revisionID = record.userContextRevisionID,
           let description = record.userContext {
            do {
                try await uploader.uploadUserContext(
                    reportID: record.report.reportID,
                    anonymousInstallID: record.report.anonymousInstallID,
                    revisionID: revisionID,
                    description: description
                )
                record.userContextUploadState = .uploaded
                record.attemptCount = 0
                record.nextRetryAt = nil
                record.lastErrorCategory = nil
                try await store.save(record)
            } catch is CancellationError {
                return
            } catch let error as CrashReportDeliveryError {
                if error == .unauthorized,
                   await recoverDiagnosticAuthorization(for: &record, userContext: true) {
                    try? await store.save(record)
                    return
                }
                applyDeliveryFailure(error, to: &record, userContext: true)
                try? await store.save(record)
                return
            } catch {
                applyRetryableFailure(to: &record, category: "context_transport")
                try? await store.save(record)
                return
            }
        }

        let promptFinished = record.promptState == .sent || record.promptState == .cancelled
        let contextFinished = record.userContextUploadState == .uploaded
            || record.userContextUploadState == .notNeeded
        if promptFinished && contextFinished {
            try? await store.remove(reportID: record.report.reportID)
        }
    }

    private func applyDeliveryFailure(
        _ error: CrashReportDeliveryError,
        to record: inout CrashReportRecord,
        userContext: Bool = false
    ) {
        switch error {
        case .unauthorized:
            applyRetryableFailure(to: &record, category: "http_401_after_reregistration")
        case .permanent(let statusCode):
            if userContext {
                record.userContextUploadState = .failed
            } else {
                record.technicalUploadState = .permanentlyFailed
            }
            record.nextRetryAt = nil
            record.lastErrorCategory = "http_\(statusCode)_permanent"
        case .retryable(let statusCode):
            applyRetryableFailure(
                to: &record,
                category: statusCode.map { "http_\($0)" } ?? "transport"
            )
        case .invalidRequest:
            applyRetryableFailure(to: &record, category: "signing_unavailable")
        }
    }

    /// Attempts one immediate registration repair for an HTTP 401. If the
    /// registration flow rotates the anonymous install ID after a key conflict,
    /// unsent technical reports are rebound to the new ID before retrying.
    /// A second consecutive 401 falls back to the normal backoff policy.
    private func recoverDiagnosticAuthorization(
        for record: inout CrashReportRecord,
        userContext: Bool
    ) async -> Bool {
        guard record.lastErrorCategory != "signing_reregistered" else { return false }
        guard let currentInstallID = await TelemetryService.shared
            .recoverDiagnosticSigningRegistrationAfterUnauthorized()
        else {
            return false
        }

        if !userContext, record.technicalUploadState != .uploaded {
            record.report.anonymousInstallID = currentInstallID
            record.technicalUploadState = .pending
        } else {
            record.userContextUploadState = .pending
        }
        record.nextRetryAt = Date()
        record.lastErrorCategory = "signing_reregistered"
        Log.info(
            "[CrashReporting] Re-registered diagnostic signing key; retrying id=\(record.id.prefix(8))",
            category: .telemetry
        )
        return true
    }

    private func applyRetryableFailure(
        to record: inout CrashReportRecord,
        category: String
    ) {
        record.technicalUploadState = record.technicalUploadState == .uploaded ? .uploaded : .failed
        record.attemptCount += 1
        record.nextRetryAt = CrashRetryPolicy.nextRetryDate(
            reportID: record.report.reportID,
            attemptCount: record.attemptCount
        )
        record.lastErrorCategory = category
    }

    private func nextWorkerDelay() async -> TimeInterval {
        let records = await store.records()
        let next = records.compactMap(\.nextRetryAt).min()
        guard let next else { return 300 }
        return min(300, max(1, next.timeIntervalSinceNow))
    }

    private func presentNextPromptIfNeeded() async {
        guard currentPrompt == nil else { return }
        let pending = await store.records()
            .filter { $0.promptState == .pending }
            .min { $0.report.occurredAt < $1.report.occurredAt }
        guard var record = pending else {
            isPromptFlowActive = false
            notifyPromptQueueDrained()
            return
        }
        isPromptFlowActive = true
        record.promptState = .presenting
        record.promptedAt = Date()
        do {
            try await store.save(record)
            currentPrompt = CrashReportPromptPresentation(
                reportID: record.report.reportID,
                occurredAt: record.report.occurredAt,
                appVersion: record.report.app.version,
                automaticUploadEnabled: automaticUploadEnabled
            )
        } catch {
            Log.error("[CrashReporting] Failed to persist prompt state", category: .telemetry)
        }
    }

    private func advancePromptQueue() async {
        // Let SwiftUI finish detaching the current sheet before publishing the
        // next item. This remains asynchronous and does not block the window.
        try? await Task.sleep(for: .milliseconds(250))
        await presentNextPromptIfNeeded()
    }

    private func notifyPromptQueueDrained() {
        guard let handler = promptQueueDrainedHandler else { return }
        promptQueueDrainedHandler = nil
        handler()
    }

    private func sanitizedUserDescription(
        _ description: String,
        report: CrashReportEnvelope
    ) -> String {
        var candidate = report
        candidate.userDescription = String(description.prefix(1_000))
        let sanitized = CrashReportSanitizer(
            libraryRootURL: LocalLibraryPaths.libraryRootURL,
            appDataRootURL: CrashReportPaths.applicationSupport
        ).sanitize(candidate)
        return sanitized.userDescription ?? ""
    }

    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDelivery()
            }
        }
    }
}
