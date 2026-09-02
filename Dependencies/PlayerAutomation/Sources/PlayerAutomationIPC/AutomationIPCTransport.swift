import Darwin
import Foundation
import PlayerAutomationProtocol

public enum AutomationIPCError: Error, Equatable, LocalizedError, Sendable {
    case invalidSocketPath
    case socketPathTooLong
    case pathOccupied
    case insecureSocketDirectory
    case addressInUse
    case listenerNotRunning
    case connectionFailed(Int32)
    case peerCredentialsUnavailable(Int32)
    case peerUserMismatch(UInt32)
    case invalidSharedSecret
    case sharedSecretUnavailable
    case readFailed(Int32)
    case writeFailed(Int32)
    case peerClosed
    case timeout
    case invalidFrameLimit(Int)
    case invalidConcurrencyLimit(Int)
    case invalidTimeout(TimeInterval)
    case frameTooLarge(Int)
    case malformedRequest(String)
    case malformedResponse(String)
    case tooManyConnections

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            return "The automation socket path is invalid."
        case .socketPathTooLong:
            return "The automation socket path is too long for AF_UNIX."
        case .pathOccupied:
            return "The automation socket path is occupied by a non-socket file."
        case .insecureSocketDirectory:
            return "The automation socket directory must be private to the current user."
        case .addressInUse:
            return "Another automation server is already listening on this socket."
        case .listenerNotRunning:
            return "The automation listener is not running."
        case .connectionFailed(let code):
            return "The automation socket connection failed (errno \(code))."
        case .peerCredentialsUnavailable(let code):
            return "The automation peer credentials could not be verified (errno \(code))."
        case .peerUserMismatch(let uid):
            return "The automation peer belongs to a different user (uid \(uid))."
        case .invalidSharedSecret:
            return "The automation shared secret is invalid."
        case .sharedSecretUnavailable:
            return "The automation shared secret is unavailable."
        case .readFailed(let code):
            return "The automation socket read failed (errno \(code))."
        case .writeFailed(let code):
            return "The automation socket write failed (errno \(code))."
        case .peerClosed:
            return "The automation peer closed the connection."
        case .timeout:
            return "The automation socket operation timed out."
        case .invalidFrameLimit(let bytes):
            return "The automation frame limit is invalid: \(bytes)."
        case .invalidConcurrencyLimit(let limit):
            return "The automation connection limit is invalid: \(limit)."
        case .invalidTimeout(let seconds):
            return "The automation I/O timeout is invalid: \(seconds)."
        case .frameTooLarge(let bytes):
            return "The automation frame is too large: \(bytes) bytes."
        case .malformedRequest(let reason):
            return "The automation request is malformed: \(reason)."
        case .malformedResponse(let reason):
            return "The automation response is malformed: \(reason)."
        case .tooManyConnections:
            return "The automation server reached its connection limit."
        }
    }
}

public struct AutomationIPCConfiguration: Sendable, Equatable {
    public let maximumFrameBytes: Int
    public let maximumConcurrentConnections: Int
    public let ioTimeout: TimeInterval
    public let sharedSecret: Data?

    public init(
        maximumFrameBytes: Int = AutomationIPCFrameCodec.defaultMaximumFrameBytes,
        maximumConcurrentConnections: Int = 8,
        ioTimeout: TimeInterval = 10,
        sharedSecret: Data? = nil
    ) throws {
        guard maximumConcurrentConnections > 0 else {
            throw AutomationIPCError.invalidConcurrencyLimit(maximumConcurrentConnections)
        }
        guard ioTimeout.isFinite, ioTimeout > 0 else {
            throw AutomationIPCError.invalidTimeout(ioTimeout)
        }
        if let sharedSecret {
            guard !sharedSecret.isEmpty, sharedSecret.count <= 4_096 else {
                throw AutomationIPCError.invalidSharedSecret
            }
        }
        _ = try AutomationIPCFrameCodec(maximumFrameBytes: maximumFrameBytes)
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumConcurrentConnections = maximumConcurrentConnections
        self.ioTimeout = ioTimeout
        self.sharedSecret = sharedSecret
    }
}

public enum AutomationSocketAddress {
    public static let maximumPathBytes = 103

    public static func validate(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw AutomationIPCError.invalidSocketPath
        }
        guard path.utf8.count <= maximumPathBytes else {
            throw AutomationIPCError.socketPathTooLong
        }
    }

    static func makeSockaddr(path: String) throws -> sockaddr_un {
        try validate(path: path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(
                    from: UnsafeRawBufferPointer(
                        start: source,
                        count: min(path.utf8.count + 1, destination.count)
                    )
                )
            }
        }
        return address
    }

    static func length(of address: sockaddr_un) -> socklen_t {
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
        let pathLength = withUnsafeBytes(of: address.sun_path) { bytes in
            bytes.prefix { $0 != 0 }.count + 1
        }
        return socklen_t(pathOffset + pathLength)
    }

}

func setSocketTimeout(_ fd: Int32, seconds: TimeInterval) {
    var timeout = timeval(
        tv_sec: Int(seconds.rounded(.down)),
        tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000).rounded())
    )
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}

func connectSocket(_ fd: Int32, path: String, timeout: TimeInterval) throws {
    var address = try AutomationSocketAddress.makeSockaddr(path: path)
    let addressLength = AutomationSocketAddress.length(of: address)
    let originalFlags = fcntl(fd, F_GETFL, 0)
    guard originalFlags >= 0 else {
        throw AutomationIPCError.connectionFailed(errno)
    }
    _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
    defer { _ = fcntl(fd, F_SETFL, originalFlags) }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, addressLength)
        }
    }
    if result == 0 { return }
    guard errno == EINPROGRESS else {
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK {
            throw AutomationIPCError.timeout
        }
        throw AutomationIPCError.connectionFailed(code)
    }

    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let milliseconds = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))
    guard Darwin.poll(&descriptor, 1, milliseconds) > 0 else {
        throw AutomationIPCError.timeout
    }
    var socketError: Int32 = 0
    var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
    let getsockoptResult = withUnsafeMutablePointer(to: &socketError) { pointer in
        getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            pointer,
            &socketErrorLength
        )
    }
    guard getsockoptResult == 0 else {
        throw AutomationIPCError.connectionFailed(errno)
    }
    guard socketError == 0 else {
        throw AutomationIPCError.connectionFailed(socketError)
    }
}

func closeSocket(_ fd: Int32) {
    _ = Darwin.close(fd)
}

func unlinkOwnedSocket(path: String, fd: Int32) {
    var pathInfo = stat()
    guard lstat(path, &pathInfo) == 0 else { return }
    var descriptorInfo = stat()
    guard fstat(fd, &descriptorInfo) == 0,
          pathInfo.st_dev == descriptorInfo.st_dev,
          pathInfo.st_ino == descriptorInfo.st_ino else {
        return
    }
    _ = unlink(path)
}

func verifySameUser(_ fd: Int32) throws {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
        throw AutomationIPCError.peerCredentialsUnavailable(errno)
    }
    guard peerUID == getuid() else {
        throw AutomationIPCError.peerUserMismatch(peerUID)
    }
}

func secureDataEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}

func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            #if os(macOS)
            let written = Darwin.send(fd, baseAddress.advanced(by: offset), bytes.count - offset, MSG_NOSIGNAL)
            #else
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), bytes.count - offset)
            #endif
            if written > 0 {
                offset += written
            } else if written == -1, errno == EINTR {
                continue
            } else if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                throw AutomationIPCError.timeout
            } else {
                throw AutomationIPCError.writeFailed(errno)
            }
        }
    }
}

func readExact(_ count: Int, from fd: Int32) throws -> Data {
    guard count >= 0 else { throw AutomationIPCError.peerClosed }
    var result = Data()
    result.reserveCapacity(count)
    var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 64 * 1024))
    while result.count < count {
        let requested = min(buffer.count, count - result.count)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.recv(fd, bytes.baseAddress, requested, 0)
        }
        if readCount > 0 {
            result.append(buffer, count: readCount)
        } else if readCount == 0 {
            throw AutomationIPCError.peerClosed
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            throw AutomationIPCError.timeout
        } else {
            throw AutomationIPCError.readFailed(errno)
        }
    }
    return result
}

func readFrame(
    from fd: Int32,
    codec: AutomationIPCFrameCodec
) throws -> Data {
    let header = try readExact(MemoryLayout<UInt32>.size, from: fd)
    let encodedLength = header.reduce(UInt32(0)) { partial, byte in
        (partial << 8) | UInt32(byte)
    }
    let bodyLength = Int(encodedLength)
    guard bodyLength <= codec.maximumFrameBytes else {
        throw AutomationIPCError.frameTooLarge(bodyLength)
    }
    return try readExact(bodyLength, from: fd)
}

fileprivate func prepareSocketPath(_ path: String) throws {
    try AutomationSocketAddress.validate(path: path)
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw AutomationIPCError.pathOccupied
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw AutomationIPCError.pathOccupied
        }
        let probeFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { throw AutomationIPCError.addressInUse }
        defer { closeSocket(probeFD) }
        var address = try AutomationSocketAddress.makeSockaddr(path: path)
        let addressLength = AutomationSocketAddress.length(of: address)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probeFD, $0, addressLength)
            }
        }
        if connected == 0 {
            throw AutomationIPCError.addressInUse
        }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw AutomationIPCError.addressInUse
        }
        guard unlink(path) == 0 else { throw AutomationIPCError.pathOccupied }
    }
}

public actor AutomationIPCListener {
    public typealias RequestHandler = @MainActor @Sendable (AutomationRequest) async -> AutomationResponse

    private let socketPath: String
    private let configuration: AutomationIPCConfiguration
    private var listenerFD: Int32?
    private var acceptTask: Task<Void, Never>?
    private var ownsSocketPath = false
    private var connectionRegistry: AutomationConnectionRegistry?

    public init(socketPath: String, configuration: AutomationIPCConfiguration? = nil) throws {
        try AutomationSocketAddress.validate(path: socketPath)
        self.socketPath = socketPath
        self.configuration = try configuration ?? AutomationIPCConfiguration()
    }

    public func start(handler: @escaping RequestHandler) throws {
        guard listenerFD == nil else { return }
        let parentURL = URL(fileURLWithPath: socketPath, isDirectory: false)
            .deletingLastPathComponent()
        let parentPath = parentURL.path
        var parentInfo = stat()
        if lstat(parentPath, &parentInfo) == 0 {
            guard (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw AutomationIPCError.pathOccupied
            }
            guard (parentInfo.st_mode & mode_t(0o077)) == 0 else {
                throw AutomationIPCError.insecureSocketDirectory
            }
        } else {
            let code = errno
            guard code == ENOENT else {
                throw AutomationIPCError.connectionFailed(code)
            }
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            guard chmod(parentPath, mode_t(0o700)) == 0 else {
                throw AutomationIPCError.connectionFailed(errno)
            }
        }
        try prepareSocketPath(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationIPCError.connectionFailed(errno) }
        do {
            var address = try AutomationSocketAddress.makeSockaddr(path: socketPath)
            let addressLength = AutomationSocketAddress.length(of: address)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, addressLength)
                }
            }
            guard bound == 0 else {
                let code = errno
                closeSocket(fd)
                if code == EADDRINUSE { throw AutomationIPCError.addressInUse }
                throw AutomationIPCError.connectionFailed(code)
            }
            guard Darwin.listen(fd, Int32(configuration.maximumConcurrentConnections)) == 0 else {
                let code = errno
                closeSocket(fd)
                unlink(socketPath)
                throw AutomationIPCError.connectionFailed(code)
            }
            guard chmod(socketPath, mode_t(0o600)) == 0 else {
                let code = errno
                closeSocket(fd)
                unlink(socketPath)
                throw AutomationIPCError.connectionFailed(code)
            }
            listenerFD = fd
            ownsSocketPath = true
            let configuration = self.configuration
            let registry = AutomationConnectionRegistry()
            connectionRegistry = registry
            acceptTask = Task.detached(priority: .utility) { [fd, handler] in
                let limiter = AutomationConnectionLimiter(
                    maximum: configuration.maximumConcurrentConnections
                )
                while !Task.isCancelled {
                    var address = sockaddr_storage()
                    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.accept(fd, $0, &length)
                        }
                    }
                    guard clientFD >= 0 else {
                        if errno == EINTR { continue }
                        break
                    }
                    guard registry.register(clientFD) else {
                        closeSocket(clientFD)
                        break
                    }
                    do {
                        try verifySameUser(clientFD)
                    } catch {
                        registry.finish(clientFD)
                        continue
                    }
                    guard limiter.tryAcquire() else {
                        registry.finish(clientFD)
                        continue
                    }
                    Task.detached(priority: .utility) {
                        defer {
                            limiter.release()
                            registry.finish(clientFD)
                        }
                        setSocketTimeout(clientFD, seconds: configuration.ioTimeout)
                        do {
                            let codec = try AutomationIPCFrameCodec(
                                maximumFrameBytes: configuration.maximumFrameBytes
                            )
                            if let expectedSecret = configuration.sharedSecret {
                                let helloData = try readFrame(from: clientFD, codec: codec)
                                let hello: AutomationClientHello
                                do {
                                    hello = try AutomationWireCoding.decoder().decode(
                                        AutomationClientHello.self,
                                        from: helloData
                                    )
                                } catch {
                                    let response = AutomationResponse(
                                        requestID: UUID(),
                                        error: AutomationError(
                                            code: .authorizationRequired,
                                            message: "The automation client handshake is invalid."
                                        )
                                    )
                                    try? writeResponse(response, to: clientFD, codec: codec)
                                    return
                                }
                                guard AutomationProtocol.supportedVersions.contains(hello.protocolVersion),
                                      let credential = hello.credential,
                                      secureDataEqual(credential, expectedSecret) else {
                                    let response = AutomationResponse(
                                        requestID: UUID(),
                                        error: AutomationError(
                                            code: .authorizationRequired,
                                            message: "The automation client is not authorized."
                                        )
                                    )
                                    try? writeResponse(response, to: clientFD, codec: codec)
                                    return
                                }
                            }
                            let requestData = try readFrame(from: clientFD, codec: codec)
                            let request: AutomationRequest
                            do {
                                request = try AutomationWireCoding.decoder().decode(
                                    AutomationRequest.self,
                                    from: requestData
                                )
                            } catch {
                                let fallbackID = UUID()
                                let response = AutomationResponse.failure(
                                    for: AutomationRequest(
                                        method: "unknown",
                                        requestID: fallbackID
                                    ),
                                    error: AutomationError(
                                        code: .invalidRequest,
                                        message: String(describing: error)
                                    )
                                )
                                try writeResponse(response, to: clientFD, codec: codec)
                                return
                            }
                            let response = await handler(request)
                            try writeResponse(response, to: clientFD, codec: codec)
                        } catch {
                            // A disconnected or malformed client is isolated to
                            // this connection; the listener remains available.
                        }
                    }
                }
            }
        } catch {
            closeSocket(fd)
            throw error
        }
    }

    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        connectionRegistry?.closeAll()
        connectionRegistry = nil
        if let listenerFD {
            if ownsSocketPath {
                // Unlink before closing so a new listener cannot bind between
                // our close and cleanup. Compare device/inode first so a
                // replacement pathname owned by another process is preserved.
                unlinkOwnedSocket(path: socketPath, fd: listenerFD)
            }
            closeSocket(listenerFD)
            self.listenerFD = nil
            ownsSocketPath = false
        }
    }

    public var isRunning: Bool { listenerFD != nil }
}

private final class AutomationConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var active = 0

    init(maximum: Int) {
        self.maximum = maximum
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maximum else { return false }
        active += 1
        return true
    }

    func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

private final class AutomationConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptors: Set<Int32> = []
    private var isStopping = false

    func register(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopping else { return false }
        fileDescriptors.insert(fd)
        return true
    }

    func finish(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptors.remove(fd) != nil else { return }
        closeSocket(fd)
    }

    func closeAll() {
        lock.lock()
        isStopping = true
        let descriptors = fileDescriptors
        fileDescriptors.removeAll()
        for fd in descriptors {
            closeSocket(fd)
        }
        lock.unlock()
    }
}

private func writeResponse(
    _ response: AutomationResponse,
    to fd: Int32,
    codec: AutomationIPCFrameCodec
) throws {
    let data = try AutomationWireCoding.encoder().encode(response)
    try writeAll(codec.encode(data), to: fd)
}
