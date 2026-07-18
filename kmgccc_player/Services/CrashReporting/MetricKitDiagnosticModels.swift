import Foundation

nonisolated enum MetricKitDiagnosticKind: String, Codable, Sendable {
    case crash
    case hang
    case cpuException = "cpu_exception"
}

nonisolated struct MetricKitDiagnosticEnvelope: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var reportID: String
    var anonymousInstallID: String
    var diagnosticKind: MetricKitDiagnosticKind
    var intervalBegin: Date
    var intervalEnd: Date
    var appVersion: String
    var buildNumber: String
    var architecture: String
    var osVersion: String
    var deviceType: String?
    var payloadJSON: String
    var clientRedactionVersion: String
    var clientRedactionCounts: [String: Int]
    var uploadMode: String
}

nonisolated struct MetricKitDiagnosticRecord: Codable, Sendable, Identifiable, Equatable {
    var id: String { envelope.reportID }
    var envelope: MetricKitDiagnosticEnvelope
    var attemptCount: Int
    var nextRetryAt: Date?
    var lastErrorCategory: String?
}

nonisolated struct CapturedMetricKitDiagnostic: Sendable {
    var kind: MetricKitDiagnosticKind
    var intervalBegin: Date
    var intervalEnd: Date
    var appVersion: String
    var buildNumber: String
    var architecture: String
    var osVersion: String
    var deviceType: String?
    var payload: Data
}
