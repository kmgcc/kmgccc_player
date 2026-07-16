import CryptoKit
import Foundation
import MetricKit

@MainActor
final class MetricKitDiagnosticService: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitDiagnosticService()

    private let store = MetricKitDiagnosticStore.shared
    private let uploader = CrashReportUploader()
    private var anonymousInstallID: String?
    private var hasStarted = false
    private var workerTask: Task<Void, Never>?

    func start(anonymousInstallID: String) {
        guard !hasStarted else { return }
        hasStarted = true
        self.anonymousInstallID = anonymousInstallID
        MXMetricManager.shared.add(self)
        importCaptured(Self.capture(MXMetricManager.shared.pastDiagnosticPayloads))
        scheduleDelivery()
    }

    func automaticUploadPreferenceDidChange(_ enabled: Bool) {
        if enabled { scheduleDelivery() }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let captured = Self.capture(payloads)
        Task { @MainActor in
            MetricKitDiagnosticService.shared.importCaptured(captured)
        }
    }

    nonisolated private static func capture(
        _ payloads: [MXDiagnosticPayload]
    ) -> [CapturedMetricKitDiagnostic] {
        payloads.flatMap { payload in
            var result: [CapturedMetricKitDiagnostic] = []
            func append(_ diagnostic: MXDiagnostic, kind: MetricKitDiagnosticKind) {
                let metadata = diagnostic.metaData
                result.append(
                    CapturedMetricKitDiagnostic(
                        kind: kind,
                        intervalBegin: payload.timeStampBegin,
                        intervalEnd: payload.timeStampEnd,
                        appVersion: diagnostic.applicationVersion,
                        buildNumber: metadata.applicationBuildVersion,
                        architecture: metadata.platformArchitecture,
                        osVersion: metadata.osVersion,
                        deviceType: metadata.deviceType,
                        payload: diagnostic.jsonRepresentation()
                    )
                )
            }
            payload.crashDiagnostics?.forEach { append($0, kind: .crash) }
            payload.hangDiagnostics?.forEach { append($0, kind: .hang) }
            payload.cpuExceptionDiagnostics?.forEach { append($0, kind: .cpuException) }
            return result
        }
    }

    private func importCaptured(_ captured: [CapturedMetricKitDiagnostic]) {
        guard let anonymousInstallID else { return }
        Task {
            for diagnostic in captured {
                do {
                    let sanitized = try await Task.detached(priority: .utility) {
                        try MetricKitDiagnosticSanitizer.sanitize(diagnostic.payload)
                    }.value
                    let reportID = Self.stableReportID(
                        kind: diagnostic.kind,
                        buildNumber: diagnostic.buildNumber,
                        payloadJSON: sanitized.json
                    )
                    try await store.insertIfNeeded(
                        MetricKitDiagnosticRecord(
                            envelope: MetricKitDiagnosticEnvelope(
                                schemaVersion: 1,
                                reportID: reportID,
                                anonymousInstallID: anonymousInstallID,
                                diagnosticKind: diagnostic.kind,
                                intervalBegin: diagnostic.intervalBegin,
                                intervalEnd: diagnostic.intervalEnd,
                                appVersion: diagnostic.appVersion,
                                buildNumber: diagnostic.buildNumber,
                                architecture: diagnostic.architecture,
                                osVersion: diagnostic.osVersion,
                                deviceType: diagnostic.deviceType,
                                payloadJSON: sanitized.json,
                                clientRedactionVersion: MetricKitDiagnosticSanitizer.version,
                                clientRedactionCounts: sanitized.counts,
                                uploadMode: "automatic"
                            ),
                            attemptCount: 0,
                            nextRetryAt: nil,
                            lastErrorCategory: nil
                        )
                    )
                } catch {
                    Log.warning("[MetricKit] Diagnostic import failed", category: .telemetry)
                }
            }
            scheduleDelivery()
        }
    }

    private func scheduleDelivery() {
        workerTask?.cancel()
        guard CrashReportPreferences.automaticUploadEnabled() else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await deliverReadyRecords()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    private func deliverReadyRecords() async {
        for var record in await store.records() {
            guard !Task.isCancelled else { return }
            if let nextRetryAt = record.nextRetryAt, nextRetryAt > Date() { continue }
            do {
                try await uploader.uploadMetricKitDiagnostic(record.envelope)
                try await store.remove(reportID: record.id)
            } catch let error as CrashReportDeliveryError {
                switch error {
                case .permanent:
                    try? await store.remove(reportID: record.id)
                case .retryable(let statusCode):
                    record.attemptCount += 1
                    record.nextRetryAt = CrashRetryPolicy.nextRetryDate(
                        reportID: record.id,
                        attemptCount: record.attemptCount
                    )
                    record.lastErrorCategory = statusCode.map { "http_\($0)" } ?? "transport"
                    try? await store.save(record)
                case .invalidRequest:
                    record.lastErrorCategory = "signing_unavailable"
                    record.nextRetryAt = Date().addingTimeInterval(300)
                    try? await store.save(record)
                }
            } catch {
                record.attemptCount += 1
                record.nextRetryAt = CrashRetryPolicy.nextRetryDate(
                    reportID: record.id,
                    attemptCount: record.attemptCount
                )
                record.lastErrorCategory = "transport"
                try? await store.save(record)
            }
        }
    }

    nonisolated private static func stableReportID(
        kind: MetricKitDiagnosticKind,
        buildNumber: String,
        payloadJSON: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data("\(kind.rawValue)\n\(buildNumber)\n\(payloadJSON)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
