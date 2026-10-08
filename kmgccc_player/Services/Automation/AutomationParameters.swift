import Foundation
import PlayerAutomationProtocol

struct AutomationParameters {
    let values: [String: AutomationJSONValue]

    init(_ request: AutomationRequest) throws {
        switch request.params {
        case nil, .some(.null):
            values = [:]
        case .some(.object(let values)):
            let unknown = AutomationToolCatalog.unknownParameterKeys(
                for: request.method,
                params: .object(values)
            )
            guard unknown.isEmpty else {
                throw AutomationParameterError.unknown(unknown)
            }
            self.values = values
        default:
            throw AutomationParameterError.invalidShape
        }
    }

    func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required {
                throw AutomationParameterError.missing(key)
            }
            return nil
        }
        guard case .string(let string) = value else {
            throw AutomationParameterError.invalidType(key, expected: "string")
        }
        return string
    }

    func uuid(_ key: String, required: Bool = false) throws -> UUID? {
        guard let string = try string(key, required: required) else {
            return nil
        }
        guard let uuid = UUID(uuidString: string) else {
            throw AutomationParameterError.invalidValue(key)
        }
        return uuid
    }

    func uuidArray(
        _ key: String,
        required: Bool = false,
        allowEmpty: Bool = false,
        maximumCount: Int = 5_000
    ) throws -> [UUID] {
        guard let value = values[key] else {
            if required {
                throw AutomationParameterError.missing(key)
            }
            return []
        }
        guard case .array(let values) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array of UUID strings")
        }
        guard (allowEmpty || !values.isEmpty), values.count <= maximumCount else {
            throw AutomationParameterError.outOfRange(key)
        }

        var result: [UUID] = []
        var seen = Set<UUID>()
        for value in values {
            guard case .string(let string) = value,
                  let uuid = UUID(uuidString: string) else {
                throw AutomationParameterError.invalidValue(key)
            }
            if seen.insert(uuid).inserted {
                result.append(uuid)
            }
        }
        return result
    }

    func integer(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = values[key] else {
            return defaultValue
        }
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw AutomationParameterError.invalidType(key, expected: "integer")
        }
        return Int(number)
    }

    func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values[key] else {
            return defaultValue
        }
        guard case .boolean(let boolean) = value else {
            throw AutomationParameterError.invalidType(key, expected: "boolean")
        }
        return boolean
    }

    func double(_ key: String, default defaultValue: Double? = nil) throws -> Double? {
        guard let value = values[key] else { return defaultValue }
        guard case .number(let number) = value, number.isFinite else {
            throw AutomationParameterError.invalidType(key, expected: "number")
        }
        return number
    }

    func object(_ key: String) throws -> [String: AutomationJSONValue]? {
        guard let value = values[key] else { return nil }
        guard case .object(let object) = value else {
            throw AutomationParameterError.invalidType(key, expected: "object")
        }
        return object
    }

    func objectArray(
        _ key: String,
        required: Bool = false
    ) throws -> [[String: AutomationJSONValue]] {
        guard let value = values[key] else {
            if required { throw AutomationParameterError.missing(key) }
            return []
        }
        guard case .array(let array) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array of objects")
        }
        guard !array.isEmpty, array.count <= 5_000 else {
            throw AutomationParameterError.outOfRange(key)
        }
        return try array.map { value in
            guard case .object(let object) = value else {
                throw AutomationParameterError.invalidType(key, expected: "array of objects")
            }
            return object
        }
    }

    func array(_ key: String) throws -> [AutomationJSONValue] {
        guard let value = values[key] else { return [] }
        guard case .array(let array) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array")
        }
        return array
    }

    func date(_ key: String) throws -> Date? {
        guard let string = try string(key) else { return nil }
        guard let date = ISO8601DateFormatter().date(from: string) else {
            throw AutomationParameterError.invalidValue(key)
        }
        return date
    }
}

enum AutomationParameterError: Error, LocalizedError {
    case invalidShape
    case unknown([String])
    case missing(String)
    case missingResource(String)
    case invalidType(String, expected: String)
    case invalidValue(String)
    case outOfRange(String)

    var errorDescription: String? {
        switch self {
        case .invalidShape:
            return "Request parameters must be a JSON object."
        case .unknown(let keys):
            return "Unknown parameter(s): " + keys.joined(separator: ", ") + "."
        case .missing(let key):
            return "Missing required parameter '\(key)'."
        case .missingResource(let key):
            return "The requested \(key) does not exist."
        case .invalidType(let key, let expected):
            return "Parameter '\(key)' must be \(expected)."
        case .invalidValue(let key):
            return "Parameter '\(key)' has an invalid value."
        case .outOfRange(let key):
            return "Parameter '\(key)' is outside the supported range."
        }
    }
}

nonisolated enum AutomationFileOperationError: Error, LocalizedError {
    case referencedLibraryRequired
    case referencedFileRequired(UUID)
    case trackNotFound(UUID)
    case noSourceMembership(UUID)
    case fileUnavailable(UUID)
    case sourceNotAuthorized(UUID)
    case sourceMustBeDirectory(UUID)
    case unsafeRelativePath(String)
    case invalidFileName
    case destinationIsCurrentFile(String)
    case destinationExists(String)
    case duplicateDestination
    case destinationOverlapsSelection
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .referencedLibraryRequired:
            return "Physical file automation currently requires a referenced music library."
        case .referencedFileRequired(let trackID):
            return "Track \(trackID.uuidString) does not point to a referenced external file."
        case .trackNotFound(let trackID):
            return "Track \(trackID.uuidString) was not found in the active Library."
        case .noSourceMembership(let trackID):
            return "Track \(trackID.uuidString) has no authorized Source membership."
        case .fileUnavailable(let trackID):
            return "The current physical file for Track \(trackID.uuidString) is missing or unavailable."
        case .sourceNotAuthorized(let sourceID):
            return "Source \(sourceID.uuidString) is not currently authorized by the App."
        case .sourceMustBeDirectory(let sourceID):
            return "Source \(sourceID.uuidString) is a single-file Source; choose an authorized directory Source for this operation."
        case .unsafeRelativePath(let path):
            return "The destination path is not a safe Source-relative path: \(path)"
        case .invalidFileName:
            return "The new file name must be a single non-empty path component."
        case .destinationIsCurrentFile(let path):
            return "The destination is already the current file: \(path)"
        case .destinationExists(let path):
            return "The destination file already exists: \(path)"
        case .duplicateDestination:
            return "Multiple file operations resolve to the same destination."
        case .destinationOverlapsSelection:
            return "A file operation would overwrite another selected file; no mutation was applied."
        case .operationFailed(let reason):
            return "The physical file operation failed: \(reason)"
        }
    }
}
