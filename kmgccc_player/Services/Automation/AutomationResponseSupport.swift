import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
enum AutomationResponseSupport {

    static func responseForRequest(
        _ response: AutomationResponse,
        requestID: UUID
    ) -> AutomationResponse {
        AutomationResponse(
            requestID: requestID,
            result: response.result,
            error: response.error,
            serverTime: response.serverTime,
            protocolVersion: response.protocolVersion
        )
    }

    static func interactionCancelled(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .interactionRequired,
                message: "The App interaction was cancelled or is not available; no mutation was applied.",
                retryable: false
            )
        )
    }

    static func permissionDenied(
        for request: AutomationRequest,
        path: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .permissionDenied,
                message: "The selected Source could not be authorized; no import Job was started.",
                retryable: false,
                details: .object([
                    "path": .string(path),
                    "reason": .string("securityScopedAccess")
                ])
            )
        )
    }

    static func libraryPermissionDenied(
        for request: AutomationRequest,
        path: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .permissionDenied,
                message: "The selected library location could not be authorized; no library lifecycle mutation was applied.",
                retryable: false,
                details: .object([
                    "path": .string(path),
                    "reason": .string("securityScopedAccess")
                ])
            )
        )
    }

    static func confirmationRequired(
        for request: AutomationRequest,
        message: String = "此操作需要 dryRun=false，并提供 confirm=true。",
        details: AutomationJSONValue? = nil
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .authorizationRequired,
                message: message,
                details: details ?? .object([
                    "required": .array([.string("dryRun=false"), .string("confirm=true")])
                ])
            )
        )
    }

    static func revisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The playlist changed since it was queried.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    static func mutationFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        if error is AutomationParameterError || error is AutomationFileOperationError {
            return invalidParameters(for: request, error: error)
        }
        if let error = error as? LibraryAutomationMutationError {
            switch error {
            case .sessionQuiescing:
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .conflict,
                        message: error.localizedDescription,
                        retryable: true
                    )
                )
            case .revisionConflict(let expected, let actual):
                return revisionConflict(
                    for: request,
                    expected: expected,
                    actual: actual
                )
            case .playlistNotFound(let playlistID):
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .invalidRequest,
                        message: error.localizedDescription,
                        details: .object(["playlistID": .string(playlistID.uuidString)])
                    )
                )
            case .resultUnavailable:
                break
            }
        }
        return .failure(
            for: request,
            error: AutomationError(
                code: .internalError,
                message: "The playlist mutation failed.",
                details: .object(["reason": .string(String(describing: error))])
            )
        )
    }

    static func libraryLifecycleFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        if error is AutomationParameterError || error is AutomationFileOperationError {
            return invalidParameters(for: request, error: error)
        }

        let reason = String(describing: error)
        func failure(
            _ code: AutomationErrorCode,
            _ message: String,
            retryable: Bool = false
        ) -> AutomationResponse {
            .failure(
                for: request,
                error: AutomationError(
                    code: code,
                    message: message,
                    retryable: retryable,
                    details: .object(["reason": .string(reason)])
                )
            )
        }

        switch error {
        case let error as RegisteredLibraryActivationError:
            switch error {
            case .notRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .reconnectRequired(let libraryID):
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .interactionRequired,
                        message: "The registered library is unavailable at its last known path. Call library.open and select its current folder before switching again.",
                        details: .object([
                            "libraryID": .string(libraryID.uuidString),
                            "nextAction": .string(AutomationMethod.libraryOpen),
                            "reason": .string(reason)
                        ])
                    )
                )
            }

        case let error as LibraryCreationError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .destinationContainsUnknownItems, .invalidExistingLibrary:
                return failure(.conflict, "The selected library location already queries.contains data that cannot be safely reused.")
            case .stagingFailed, .validationFailed:
                return failure(.internalError, "The new library could not be staged or validated.", retryable: true)
            case .registryCommitFailed, .sessionActivationFailed, .recoveryFailed:
                return failure(.internalError, "The new library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryOpenError:
            switch error {
            case .libraryNotFound, .invalidManifest, .libraryNotRegistered,
                 .reconnectIdentifierMismatch, .reconnectModeMismatch:
                return failure(.invalidRequest, "The selected location is not a usable registered music library.")
            case .pathConflict:
                return failure(.conflict, "The selected library path is already registered to another library.")
            case .bookmarkFailed, .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the selected library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .activationFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRelocationError:
            switch error {
            case .libraryNotRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .destinationExists:
                return failure(.conflict, "The destination already queries.contains a library or other data.")
            case .validationFailed:
                return failure(.invalidRequest, "The registered library failed validation and was not moved.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library or destination location.")
            case .transactionInProgress, .pendingRepair, .recoveryConflict:
                return failure(.conflict, "The library has an unfinished lifecycle transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .copyFailed, .publicationFailed, .newSessionFailed,
                 .registryCommitFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be relocated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRemovalError:
            switch error {
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress, .pendingRepair:
                return failure(.conflict, "The library has an unfinished removal transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .recycleFailed, .intentWriteFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be moved to the macOS Trash safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryDisplayNameUpdateError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .manifestWriteFailed, .registryWriteFailedRolledBack,
                 .registryWriteFailedRollbackFailed:
                return failure(.internalError, "The library name could not be updated safely.", retryable: true)
            }

        default:
            return failure(.internalError, "The library lifecycle operation failed.", retryable: true)
        }
    }

    static func trackRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The Track changed while the lyrics candidate was being prepared.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    static func selectionStoreFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .internalError,
                message: "The saved selection state could not be read or written.",
                details: .object(["reason": .string(String(describing: error))])
            )
        )
    }

    static func libraryTracksRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The Library changed while the Track results were being paginated.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    static func metadataProviderUnavailable(
        _ error: Error,
        provider: String,
        for request: AutomationRequest
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .serverUnavailable,
                message: "The \(provider) metadata provider could not complete the request.",
                retryable: true,
                details: .object(["reason": .string(error.localizedDescription)])
            )
        )
    }

    static func requestDeadlineExpired(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .serverUnavailable,
                message: "The request deadline expired before the Job was accepted.",
                retryable: true,
                details: .object(["deadlineReached": .boolean(true)])
            )
        )
    }

    static func invalidParameters(
        for request: AutomationRequest,
        error: Error? = nil
    ) -> AutomationResponse {
        if let error = error as? LibraryOperationError,
           error == .sessionQuiescing {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .conflict,
                    message: "The active library is changing; retry after the operation completes.",
                    retryable: true
                )
            )
        }
        guard error == nil
            || error is AutomationParameterError
            || error is AutomationFileOperationError else {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .internalError,
                    message: "The automation operation failed.",
                    details: .object(["reason": .string(String(describing: error!))])
                )
            )
        }
        return .failure(
            for: request,
            error: AutomationError(
                code: .invalidRequest,
                message: error?.localizedDescription ?? "The request parameters are invalid.",
                details: error.flatMap { error in
                    guard case let AutomationParameterError.unknown(keys) = error else {
                        return nil
                    }
                    return .object([
                        "unknownParameters": .array(keys.map { .string($0) })
                    ])
                }
            )
        )
    }

    static func encodeResult<Value: Encodable>(
        _ value: Value,
        for request: AutomationRequest
    ) -> AutomationResponse {
        do {
            let data = try AutomationWireCoding.encoder().encode(value)
            let json = try AutomationWireCoding.decoder().decode(
                AutomationJSONValue.self,
                from: data
            )
            return .success(for: request, result: json)
        } catch {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .internalError,
                    message: "Failed to encode automation response.",
                    details: .object(["reason": .string(String(describing: error))])
                )
            )
        }
    }

    static func jsonValue<Value: Encodable>(for value: Value) -> AutomationJSONValue? {
        guard let data = try? AutomationWireCoding.encoder().encode(value) else { return nil }
        return try? AutomationWireCoding.decoder().decode(AutomationJSONValue.self, from: data)
    }

    static func isObject(_ value: AutomationJSONValue?) -> Bool {
        guard let value else { return false }
        if case .object = value { return true }
        return false
    }

    /// CLI requests commonly omit params while MCP tools/call conventionally
    /// supplies an empty arguments object. Both represent a no-argument call.
    static func isEmptyParameters(_ value: AutomationJSONValue?) -> Bool {
        guard let value else { return true }
        switch value {
        case .null:
            return true
        case .object(let values):
            return values.isEmpty
        default:
            return false
        }
    }

    static func unsupportedMethod(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .methodNotFound,
                message: "Unsupported automation method: \(request.method)."
            )
        )
    }
}
