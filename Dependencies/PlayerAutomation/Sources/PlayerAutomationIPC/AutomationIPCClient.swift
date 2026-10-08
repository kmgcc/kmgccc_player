import Darwin
import Foundation
import PlayerAutomationProtocol

/// Describes whether a request could have reached the App when an IPC call fails.
/// Callers may retry `notSent`; `outcomeUnknown` must be inspected before retrying
/// because the App may have completed the operation and lost only its response.
public enum AutomationIPCRequestError: Error, Equatable, LocalizedError, Sendable {
    case notSent(AutomationIPCError)
    case outcomeUnknown(AutomationIPCError)

    public var isDefinitelyNotSent: Bool {
        if case .notSent = self { return true }
        return false
    }

    public var underlyingError: AutomationIPCError {
        switch self {
        case .notSent(let error), .outcomeUnknown(let error): return error
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notSent(let error):
            return "The player App did not receive the automation request. \(error.localizedDescription) Start or reopen kmgccc_player, then retry."
        case .outcomeUnknown(let error):
            return "The player App may have received the automation request, but no response arrived. \(error.localizedDescription) Check the relevant job or state before retrying; repeating a mutation may duplicate work."
        }
    }
}

/// Cancels an in-flight AF_UNIX request by shutting down its owned socket.
/// The request's server-side handler observes the peer disconnect and receives
/// cooperative Task cancellation from `AutomationIPCListener`.
public final class AutomationIPCCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var activeFileDescriptor: Int32?
    private var cancellationHandlers: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func attach(fileDescriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        activeFileDescriptor = fileDescriptor
        return true
    }

    fileprivate func detach(fileDescriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard activeFileDescriptor == fileDescriptor else { return }
        activeFileDescriptor = nil
    }

    public func cancel() {
        lock.lock()
        guard !completed, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        if let activeFileDescriptor {
            _ = Darwin.shutdown(activeFileDescriptor, SHUT_RDWR)
        }
        let handlers = cancellationHandlers
        cancellationHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else if completed {
            lock.unlock()
        } else {
            cancellationHandlers.append(handler)
            lock.unlock()
        }
    }

    public func finish() {
        lock.lock()
        completed = true
        cancellationHandlers.removeAll()
        lock.unlock()
    }
}

public final class AutomationIPCClient: @unchecked Sendable {
    public let socketPath: String
    public let configuration: AutomationIPCConfiguration
    public let clientIDHint: String
    public let displayName: String
    private let credentialLock = NSLock()
    private var currentSharedSecret: Data?

    public init(
        socketPath: String,
        configuration: AutomationIPCConfiguration? = nil,
        clientIDHint: String = "player-automation-cli",
        displayName: String = "kmgccc_player automation CLI"
    ) throws {
        try AutomationSocketAddress.validate(path: socketPath)
        self.socketPath = socketPath
        self.configuration = try configuration ?? AutomationIPCConfiguration()
        self.clientIDHint = clientIDHint
        self.displayName = displayName
        self.currentSharedSecret = self.configuration.sharedSecret
    }

    public func send(
        _ request: AutomationRequest,
        timeout: TimeInterval? = nil,
        connectionTimeout: TimeInterval? = nil,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationResponse {
        do {
            return try sendClassified(
                request,
                timeout: timeout,
                connectionTimeout: connectionTimeout,
                cancellation: cancellation
            )
        } catch let error as AutomationIPCRequestError {
            if case .notSent(.invalidSharedSecret) = error {
                return AutomationResponse(
                    requestID: request.requestID,
                    error: AutomationError(
                        code: .authorizationRequired,
                        message: "The automation client is not authorized."
                    )
                )
            }
            throw error.underlyingError
        }
    }

    /// Sends one request while preserving whether transport failure occurred
    /// before request delivery or after the App may have received it.
    public func sendClassified(
        _ request: AutomationRequest,
        timeout: TimeInterval? = nil,
        connectionTimeout: TimeInterval? = nil,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationResponse {
        let ioTimeout = timeout ?? configuration.ioTimeout
        let connectTimeout = connectionTimeout ?? ioTimeout
        guard ioTimeout.isFinite, ioTimeout > 0,
              connectTimeout.isFinite, connectTimeout > 0 else {
            throw AutomationIPCError.invalidTimeout(
                !ioTimeout.isFinite || ioTimeout <= 0 ? ioTimeout : connectTimeout
            )
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let operationDeadline = Date().addingTimeInterval(ioTimeout)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AutomationIPCRequestError.notSent(.connectionFailed(errno))
        }
        guard cancellation?.attach(fileDescriptor: fd) ?? true else {
            closeSocket(fd)
            throw CancellationError()
        }
        defer {
            cancellation?.detach(fileDescriptor: fd)
            closeSocket(fd)
        }
        setSocketTimeout(fd, seconds: ioTimeout)
        let remainingBeforeConnect = operationDeadline.timeIntervalSinceNow
        guard remainingBeforeConnect > 0 else {
            throw AutomationIPCRequestError.notSent(.timeout)
        }
        do {
            try connectSocket(
                fd,
                path: socketPath,
                timeout: min(connectTimeout, remainingBeforeConnect),
                cancellation: cancellation
            )
        } catch let error as AutomationIPCError {
            throw AutomationIPCRequestError.notSent(error)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }

        let codec = try AutomationIPCFrameCodec(maximumFrameBytes: configuration.maximumFrameBytes)
        if let sharedSecret = activeSharedSecret() {
            let hello = AutomationClientHello(
                clientIDHint: clientIDHint,
                displayName: displayName,
                credential: sharedSecret
            )
            let helloData = try AutomationWireCoding.encoder().encode(hello)
            do {
                try writeAll(codec.encode(helloData), to: fd, deadline: operationDeadline)
            } catch let error as AutomationIPCError {
                throw AutomationIPCRequestError.notSent(error)
            }
            if cancellation?.isCancelled == true { throw CancellationError() }
        }
        let requestData = try AutomationWireCoding.encoder().encode(request)
        let requestFrame: Data
        do {
            requestFrame = try codec.encode(requestData)
        } catch let error as AutomationIPCError {
            throw AutomationIPCRequestError.notSent(error)
        }
        do {
            try writeAll(requestFrame, to: fd, deadline: operationDeadline)
        } catch let error as AutomationIPCError {
            throw AutomationIPCRequestError.outcomeUnknown(error)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let responseData: Data
        do {
            responseData = try readFrame(from: fd, codec: codec, deadline: operationDeadline)
        } catch let error as AutomationIPCError {
            throw AutomationIPCRequestError.outcomeUnknown(error)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        do {
            let response = try AutomationWireCoding.decoder().decode(
                AutomationResponse.self,
                from: responseData
            )
            guard response.requestID == request.requestID else {
                if response.error?.code == .authorizationRequired {
                    refreshSharedSecretFromStore()
                    throw AutomationIPCRequestError.notSent(.invalidSharedSecret)
                }
                throw AutomationIPCRequestError.outcomeUnknown(
                    .malformedResponse("The response request ID did not match the sent request.")
                )
            }
            return response
        } catch let error as AutomationIPCRequestError {
            throw error
        } catch {
            throw AutomationIPCRequestError.outcomeUnknown(
                .malformedResponse(String(describing: error))
            )
        }
    }

    private func activeSharedSecret() -> Data? {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return currentSharedSecret
    }

    private func refreshSharedSecretFromStore() {
        guard let refreshed = try? AutomationIPCSecretStore.load(forSocketPath: socketPath) else {
            return
        }
        credentialLock.lock()
        currentSharedSecret = refreshed
        credentialLock.unlock()
    }
}
