import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationSessionAccess {
    private weak var appSession: AppSessionHost?

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func activeSession(for request: AutomationRequest) -> LibrarySession? {
        guard let session = appSession?.activeLibraryBinding.activeSession else {
            return nil
        }
        guard request.context.libraryID == nil
            || request.context.libraryID == session.context.id else {
            return nil
        }
        return session
    }

    func noActiveLibraryResponse(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: appSession == nil ? .serverUnavailable : .libraryNotActive,
                message: appSession == nil
                    ? "The player App is no longer available."
                    : "The requested library is not active.",
                retryable: true
            )
        )
    }
}
