import Foundation

public struct AutomationIPCFrameCodec: Sendable {
    public static let defaultMaximumFrameBytes = 1_048_576

    public let maximumFrameBytes: Int

    public init(maximumFrameBytes: Int = Self.defaultMaximumFrameBytes) throws {
        guard (1...Int(UInt32.max)).contains(maximumFrameBytes) else {
            throw AutomationIPCError.invalidFrameLimit(maximumFrameBytes)
        }
        self.maximumFrameBytes = maximumFrameBytes
    }

    public func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumFrameBytes else {
            throw AutomationIPCError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    /// Incrementally decodes one length-prefixed payload. Partial input is
    /// retained in `buffer`; malformed or oversized frames fail closed.
    public func decodeNext(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= MemoryLayout<UInt32>.size else { return nil }
        let header = buffer.prefix(MemoryLayout<UInt32>.size)
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let bodyLength = Int(length)
        guard bodyLength <= maximumFrameBytes else {
            throw AutomationIPCError.frameTooLarge(bodyLength)
        }
        let frameLength = MemoryLayout<UInt32>.size + bodyLength
        guard buffer.count >= frameLength else { return nil }
        let payload = buffer.subdata(in: MemoryLayout<UInt32>.size..<frameLength)
        buffer.removeSubrange(0..<frameLength)
        return payload
    }
}
