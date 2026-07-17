import Foundation

nonisolated enum CrashReportUploadMode: String, Codable, Sendable {
    case automatic
    case userConfirmed = "user_confirmed"
}

nonisolated enum CrashTechnicalUploadState: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
    case permanentlyFailed = "permanently_failed"
    case declined
}

nonisolated enum CrashPromptState: String, Codable, Sendable {
    case pending
    case presenting
    case sent
    case cancelled
}

nonisolated enum CrashUserContextUploadState: String, Codable, Sendable {
    case notNeeded = "not_needed"
    case pending
    case uploaded
    case failed
}

nonisolated enum CrashDiagnosticValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

nonisolated struct CrashAppInfo: Codable, Sendable, Equatable {
    var bundleID: String
    var version: String
    var build: String
    var architecture: String
    var executableUUID: String
}

nonisolated struct CrashSystemInfo: Codable, Sendable, Equatable {
    var osVersion: String
    var modelIdentifier: String?
    var locale: String?
}

nonisolated struct CrashProcessInfo: Codable, Sendable, Equatable {
    var uptimeSeconds: Double?
}

nonisolated struct CrashExceptionInfo: Codable, Sendable, Equatable {
    var signal: String?
    var machType: String?
    var machCode: String?
    var machSubcode: String?
    var name: String?
    var reason: String?
}

nonisolated struct CrashFrame: Codable, Sendable, Equatable {
    var instructionAddress: String
    var imageUUID: String?
    var imageName: String?
    var imageBaseAddress: String?
    var imageRelativeAddress: String?
    var symbolName: String?
    var symbolOffset: Int?
}

nonisolated struct CrashThread: Codable, Sendable, Equatable {
    var index: Int
    var id: String?
    var name: String?
    var queueName: String?
    var isCrashed: Bool
    var frames: [CrashFrame]
}

nonisolated struct CrashRegisterSet: Codable, Sendable, Equatable {
    var threadIndex: Int
    var values: [String: String]
}

nonisolated struct CrashBinaryImage: Codable, Sendable, Equatable {
    var uuid: String
    var basename: String
    var architecture: String?
    var loadAddress: String
    var size: Int64
    var version: String?
}

nonisolated struct CrashAppContext: Codable, Sendable, Equatable {
    var playbackSourceCategory: String?
    var isPlaying: Bool?
    var visibleSurface: String?
    var isFullScreen: Bool?
    var selectedSkinIdentifier: String?
    var lastOperationCategory: String?
}

nonisolated enum CrashVisibleSurface: String, Sendable {
    case home
    case library
    case nowPlaying = "now_playing"
    case settings
    case fullScreen = "full_screen"
    case miniPlayer = "mini_player"
    case unknown

    static func canonicalValue(for value: String?) -> String? {
        switch value {
        case "fullscreen_player":
            CrashVisibleSurface.fullScreen.rawValue
        case "now_playing_window":
            CrashVisibleSurface.nowPlaying.rawValue
        case "main_window":
            CrashVisibleSurface.unknown.rawValue
        default:
            value
        }
    }
}

nonisolated struct CrashBreadcrumb: Codable, Sendable, Equatable {
    var occurredAt: Date?
    var category: String
    var action: String
    var metadata: [String: CrashDiagnosticValue]
}

nonisolated struct CrashRedactionInfo: Codable, Sendable, Equatable {
    var version: String
    var replacementCounts: [String: Int]
}

nonisolated struct CrashReportEnvelope: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var reportID: String
    var anonymousInstallID: String
    var sessionID: String?
    var occurredAt: Date
    var importedAt: Date
    var app: CrashAppInfo
    var system: CrashSystemInfo
    var process: CrashProcessInfo
    var exception: CrashExceptionInfo
    var threads: [CrashThread]
    var crashedThread: CrashRegisterSet?
    var binaryImages: [CrashBinaryImage]
    var appContext: CrashAppContext?
    var breadcrumbs: [CrashBreadcrumb]
    var clientRedaction: CrashRedactionInfo
    var uploadMode: CrashReportUploadMode
    var userDescription: String?
}

nonisolated struct CrashReportRecord: Codable, Sendable, Identifiable, Equatable {
    var id: String { report.reportID }

    var report: CrashReportEnvelope
    var technicalUploadState: CrashTechnicalUploadState
    var technicalUploadedAt: Date?
    var promptState: CrashPromptState
    var promptedAt: Date?
    var userContext: String?
    var userContextRevisionID: String?
    var userContextUploadState: CrashUserContextUploadState
    var attemptCount: Int
    var nextRetryAt: Date?
    var lastErrorCategory: String?

    static func pending(report: CrashReportEnvelope) -> CrashReportRecord {
        CrashReportRecord(
            report: report,
            technicalUploadState: .pending,
            technicalUploadedAt: nil,
            promptState: .pending,
            promptedAt: nil,
            userContext: nil,
            userContextRevisionID: nil,
            userContextUploadState: .notNeeded,
            attemptCount: 0,
            nextRetryAt: nil,
            lastErrorCategory: nil
        )
    }
}

nonisolated struct CrashCaptureSnapshot: Codable, Sendable, Equatable {
    var sessionID: String?
    var appContext: CrashAppContext?
    var breadcrumbs: [CrashBreadcrumb]
}

nonisolated struct CrashReportPromptPresentation: Identifiable, Sendable, Equatable {
    var id: String { reportID }

    let reportID: String
    let occurredAt: Date
    let appVersion: String
    let automaticUploadEnabled: Bool
}

nonisolated struct CrashReportExportPayload: Sendable, Equatable {
    let suggestedFilename: String
    let data: Data

    static func make(
        report: CrashReportEnvelope,
        userDescription: String?
    ) throws -> CrashReportExportPayload {
        var exportedReport = report
        exportedReport.userDescription = userDescription?.isEmpty == false ? userDescription : nil

        let encoder = JSONEncoder.crashReportEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return CrashReportExportPayload(
            suggestedFilename: "\(report.reportID.lowercased()).crash-report.json",
            data: try encoder.encode(exportedReport)
        )
    }
}

nonisolated enum CrashReportPreferences {
    static let automaticUploadKey = "telemetry.automaticCrashReportUploadEnabled"

    static func automaticUploadEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: automaticUploadKey) != nil else { return true }
        return defaults.bool(forKey: automaticUploadKey)
    }
}

nonisolated enum CrashRetryPolicy {
    static func nextRetryDate(
        reportID: String,
        attemptCount: Int,
        now: Date = Date()
    ) -> Date {
        let exponent = min(max(0, attemptCount - 1), 10)
        let baseDelay = min(21_600.0, 30.0 * pow(2.0, Double(exponent)))
        let stableSeed = reportID.utf8.reduce(UInt64(attemptCount)) {
            (($0 &* 1_099_511_628_211) ^ UInt64($1)) & 0xFFFF_FFFF
        }
        let jitter = Double(stableSeed % 1_001) / 1_000.0 * min(30.0, baseDelay * 0.2)
        return now.addingTimeInterval(baseDelay + jitter)
    }
}

extension JSONEncoder {
    nonisolated static func crashReportEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static func crashReportDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
