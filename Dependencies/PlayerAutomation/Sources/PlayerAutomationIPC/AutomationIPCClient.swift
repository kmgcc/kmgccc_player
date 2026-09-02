import Darwin
import Foundation
import PlayerAutomationProtocol

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

    public func send(_ request: AutomationRequest) throws -> AutomationResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationIPCError.connectionFailed(errno) }
        defer { closeSocket(fd) }
        setSocketTimeout(fd, seconds: configuration.ioTimeout)
        try connectSocket(fd, path: socketPath, timeout: configuration.ioTimeout)

        let codec = try AutomationIPCFrameCodec(maximumFrameBytes: configuration.maximumFrameBytes)
        if let sharedSecret = configuration.sharedSecret {
            let hello = AutomationClientHello(
                clientIDHint: clientIDHint,
                displayName: displayName,
                credential: sharedSecret
            )
            let helloData = try AutomationWireCoding.encoder().encode(hello)
            try writeAll(codec.encode(helloData), to: fd)
        }
        let requestData = try AutomationWireCoding.encoder().encode(request)
        try writeAll(codec.encode(requestData), to: fd)
        let responseData = try readFrame(from: fd, codec: codec)
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
