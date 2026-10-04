import Darwin
import Foundation
import PlayerAutomationProtocol

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
    }

    public func send(
        _ request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken? = nil
    ) throws -> AutomationResponse {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationIPCError.connectionFailed(errno) }
        guard cancellation?.attach(fileDescriptor: fd) ?? true else {
            closeSocket(fd)
            throw CancellationError()
        }
        defer {
            cancellation?.detach(fileDescriptor: fd)
            closeSocket(fd)
        }
        setSocketTimeout(fd, seconds: configuration.ioTimeout)
        try connectSocket(
            fd,
            path: socketPath,
            timeout: configuration.ioTimeout,
            cancellation: cancellation
        )
        if cancellation?.isCancelled == true { throw CancellationError() }

        let codec = try AutomationIPCFrameCodec(maximumFrameBytes: configuration.maximumFrameBytes)
        if let sharedSecret = configuration.sharedSecret {
            let hello = AutomationClientHello(
                clientIDHint: clientIDHint,
                displayName: displayName,
                credential: sharedSecret
            )
            let helloData = try AutomationWireCoding.encoder().encode(hello)
            try writeAll(codec.encode(helloData), to: fd)
            if cancellation?.isCancelled == true { throw CancellationError() }
        }
        let requestData = try AutomationWireCoding.encoder().encode(request)
        try writeAll(codec.encode(requestData), to: fd)
        if cancellation?.isCancelled == true { throw CancellationError() }
        let responseData = try readFrame(from: fd, codec: codec)
        if cancellation?.isCancelled == true { throw CancellationError() }
        do {
            return try AutomationWireCoding.decoder().decode(
                AutomationResponse.self,
                from: responseData
            )
        } catch {
            throw AutomationIPCError.malformedResponse(String(describing: error))
        }
    }
}
