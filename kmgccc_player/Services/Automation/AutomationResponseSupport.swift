import Foundation
import PlayerAutomationProtocol

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
