import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

/// The App-owned read-only automation endpoint used by the Phase 1 CLI spike.
/// It deliberately exposes DTOs only; no repository or sidecar parser crosses
/// the process boundary. Later query/mutation services can reuse this listener
/// without changing the transport contract.
@MainActor
final class AutomationIPCServer {
    private static let socketDirectoryName = "Automation"
    private static let socketFileName = "automation.sock"

    private let listener: AutomationIPCListener
    private weak var appSession: AppSessionHost?
    private(set) var isRunning = false

    init(appSession: AppSessionHost) throws {
        self.appSession = appSession
        let socketPath = Self.defaultSocketURL.path
        let sharedSecret = try AutomationIPCSecretStore.loadOrCreate(
            forSocketPath: socketPath
        )
        let configuration = try AutomationIPCConfiguration(
            maximumFrameBytes: 1_048_576,
            maximumConcurrentConnections: 8,
            ioTimeout: 10,
            sharedSecret: sharedSecret
        )
        listener = try AutomationIPCListener(
            socketPath: socketPath,
            configuration: configuration
        )
    }

    static var defaultSocketURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent(socketDirectoryName, isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
    }

    func start() async throws {
        guard !isRunning else { return }
        try await listener.start { [weak self] request in
            guard let self else {
                return AutomationResponse.failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            return await self.handle(request)
        }
        isRunning = true
        Log.info("[Automation] read-only IPC server started", category: .library)
    }

    func stop() async {
        await listener.stop()
        isRunning = false
        Log.info("[Automation] IPC server stopped", category: .library)
    }

    private func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard AutomationProtocol.supportedVersions.contains(request.protocolVersion) else {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .unsupportedVersion,
                    message: "Unsupported automation protocol version \(request.protocolVersion).",
                    details: .object([
                        "supportedVersions": .array(
                            AutomationProtocol.supportedVersions.map { .number(Double($0)) }
                        )
                    ])
                )
            )
        }

        switch request.method {
        case AutomationMethod.systemPing:
            guard request.params == nil || request.params == .null else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                AutomationPingResult(),
                for: request
            )

        case AutomationMethod.systemInfo:
            guard request.params == nil || request.params == .null else {
                return invalidParameters(for: request)
            }
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? "development"
            let info = AutomationSystemInfo(
                appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "kmgccc_player",
                appVersion: appVersion,
                capabilities: [
                    AutomationMethod.libraryList,
                    AutomationMethod.systemInfo,
                    AutomationMethod.systemPing
                ],
                isReady: appSession?.hasCompletedInitialSetup == true,
                activeLibraryID: appSession?.activeLibraryBinding.context?.id
            )
            return encodeResult(info, for: request)

        case AutomationMethod.libraryList:
            guard request.params == nil || request.params == .null else {
                return invalidParameters(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            let registry = await appSession.musicLibraryRegistrySnapshot()
            let summaries = registry.libraries.map { bookmark in
                AutomationLibrarySummary(
                    id: bookmark.id,
                    displayName: bookmark.displayName,
                    mode: bookmark.modeProjection == .managed ? .managed : .referenced,
                    isActive: bookmark.id == registry.activeLibraryID
                )
            }
            return encodeResult(
                AutomationLibraryListResult(
                    libraries: summaries,
                    activeLibraryID: registry.activeLibraryID
                ),
                for: request
            )

        default:
            return .failure(
                for: request,
                error: AutomationError(
                    code: .methodNotFound,
                    message: "Unsupported automation method: \(request.method)."
                )
            )
        }
    }

    private func invalidParameters(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .invalidRequest,
                message: "This read-only probe does not accept parameters."
            )
        )
    }

    private func encodeResult<Value: Encodable>(
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
}
