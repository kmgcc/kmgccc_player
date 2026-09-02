import Foundation

public enum AutomationProtocol {
    public static let currentVersion = 1
    public static let supportedVersions = [currentVersion]
    public static let schemaVersion = 1
}

/// JSON values are kept deliberately small and Foundation-only so the wire
/// contract does not expose an App model or a third-party JSON library.
public enum AutomationJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([AutomationJSONValue])
    case object([String: AutomationJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw AutomationCodingError.nonFiniteNumber
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AutomationJSONValue].self) {
            self = .object(value)
        } else {
            throw AutomationCodingError.invalidJSONValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw AutomationCodingError.nonFiniteNumber
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum AutomationCodingError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSONValue
    case nonFiniteNumber

    public var errorDescription: String? {
        switch self {
        case .invalidJSONValue:
            return "The payload is not a supported JSON value."
        case .nonFiniteNumber:
            return "JSON numbers must be finite."
        }
    }
}

public struct AutomationClientHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let clientIDHint: String
    public let displayName: String
    public let credential: Data?

    public init(
        clientIDHint: String,
        displayName: String,
        credential: Data? = nil,
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.clientIDHint = clientIDHint
        self.displayName = displayName
        self.credential = credential
    }
}

public struct AutomationRequestContext: Codable, Equatable, Sendable {
    public let principalSessionID: UUID?
    public let libraryID: UUID?
    public let idempotencyKey: String?
    public let deadline: Date?

    public init(
        principalSessionID: UUID? = nil,
        libraryID: UUID? = nil,
        idempotencyKey: String? = nil,
        deadline: Date? = nil
    ) {
        self.principalSessionID = principalSessionID
        self.libraryID = libraryID
        self.idempotencyKey = idempotencyKey
        self.deadline = deadline
    }
}

/// Versioned request envelope shared by the CLI, future MCP adapter and App.
/// Unknown JSON fields are intentionally ignored by Codable for forward
/// compatibility; unknown methods are rejected by the App service.
public struct AutomationRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let method: String
    public let context: AutomationRequestContext
    public let params: AutomationJSONValue?

    public init(
        method: String,
        params: AutomationJSONValue? = nil,
        context: AutomationRequestContext = AutomationRequestContext(),
        requestID: UUID = UUID(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.method = method
        self.context = context
        self.params = params
    }
}

public enum AutomationErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedVersion
    case invalidRequest
    case methodNotFound
    case serverUnavailable
    case libraryNotActive
    case interactionRequired
    case authorizationRequired
    case conflict
    case internalError
}

public struct AutomationError: Codable, Equatable, Sendable {
    public let code: AutomationErrorCode
    public let message: String
    public let retryable: Bool
    public let details: AutomationJSONValue?

    public init(
        code: AutomationErrorCode,
        message: String,
        retryable: Bool = false,
        details: AutomationJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

public struct AutomationResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let result: AutomationJSONValue?
    public let error: AutomationError?
    public let serverTime: Date

    public init(
        requestID: UUID,
        result: AutomationJSONValue? = nil,
        error: AutomationError? = nil,
        serverTime: Date = Date(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.error = error
        self.serverTime = serverTime
    }

    public static func success(
        for request: AutomationRequest,
        result: AutomationJSONValue
    ) -> Self {
        Self(requestID: request.requestID, result: result)
    }

    public static func failure(
        for request: AutomationRequest,
        error: AutomationError
    ) -> Self {
        Self(requestID: request.requestID, error: error)
    }
}

public enum AutomationMethod {
    public static let systemPing = "system.ping"
    public static let systemInfo = "system.info"
    public static let libraryList = "library.list"
}

public struct AutomationPingResult: Codable, Equatable, Sendable {
    public let serverTime: Date
    public let protocolVersion: Int

    public init(
        serverTime: Date = Date(),
        protocolVersion: Int = AutomationProtocol.currentVersion
    ) {
        self.serverTime = serverTime
        self.protocolVersion = protocolVersion
    }
}

public struct AutomationSystemInfo: Codable, Equatable, Sendable {
    public let appName: String
    public let appVersion: String
    public let protocolVersion: Int
    public let capabilities: [String]
    public let isReady: Bool
    public let activeLibraryID: UUID?

    public init(
        appName: String,
        appVersion: String,
        protocolVersion: Int = AutomationProtocol.currentVersion,
        capabilities: [String],
        isReady: Bool,
        activeLibraryID: UUID?
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities.sorted()
        self.isReady = isReady
        self.activeLibraryID = activeLibraryID
    }
}

public enum AutomationLibraryMode: String, Codable, Equatable, Sendable {
    case managed
    case referenced
}

public struct AutomationLibrarySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let mode: AutomationLibraryMode
    public let isActive: Bool

    public init(id: UUID, displayName: String, mode: AutomationLibraryMode, isActive: Bool) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.isActive = isActive
    }
}

public struct AutomationLibraryListResult: Codable, Equatable, Sendable {
    public let libraries: [AutomationLibrarySummary]
    public let activeLibraryID: UUID?

    public init(libraries: [AutomationLibrarySummary], activeLibraryID: UUID?) {
        self.libraries = libraries.sorted { lhs, rhs in
            switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        self.activeLibraryID = activeLibraryID
    }
}

public enum AutomationWireCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
