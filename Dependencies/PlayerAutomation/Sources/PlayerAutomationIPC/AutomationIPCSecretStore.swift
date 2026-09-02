import Darwin
import Foundation

/// Stores the per-install credential used by the App-owned local endpoint.
/// The credential identifies this installation; it is not an actor or scope
/// grant. The App still derives authorization from its own state.
public enum AutomationIPCSecretStore {
    public static let defaultByteCount = 32
    public static let fileName = "automation.secret"

    public static func url(forSocketPath socketPath: String) throws -> URL {
        try AutomationSocketAddress.validate(path: socketPath)
        return URL(fileURLWithPath: socketPath, isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(
        forSocketPath socketPath: String,
        byteCount: Int = defaultByteCount
    ) throws -> Data {
        guard (1...4_096).contains(byteCount) else {
            throw AutomationIPCError.invalidSharedSecret
        }
        let secretURL = try url(forSocketPath: socketPath)
        var info = stat()
        guard lstat(secretURL.path, &info) == 0 else {
            throw AutomationIPCError.sharedSecretUnavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            throw AutomationIPCError.sharedSecretUnavailable
        }
        if (info.st_mode & mode_t(0o077)) != 0 {
            guard chmod(secretURL.path, mode_t(0o600)) == 0 else {
                throw AutomationIPCError.sharedSecretUnavailable
            }
        }
        guard let data = try? Data(contentsOf: secretURL), data.count == byteCount else {
            throw AutomationIPCError.sharedSecretUnavailable
        }
        return data
    }

    public static func loadOrCreate(
        forSocketPath socketPath: String,
        byteCount: Int = defaultByteCount
    ) throws -> Data {
        guard (1...4_096).contains(byteCount) else {
            throw AutomationIPCError.invalidSharedSecret
        }
        let secretURL = try url(forSocketPath: socketPath)
        try ensurePrivateDirectory(secretURL.deletingLastPathComponent())

        var info = stat()
        if lstat(secretURL.path, &info) == 0 {
            return try load(forSocketPath: socketPath, byteCount: byteCount)
        }
        let missingCode = errno
        guard missingCode == ENOENT else {
            throw AutomationIPCError.sharedSecretUnavailable
        }

        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<byteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
        let fd = open(
            secretURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fd >= 0 else {
            if errno == EEXIST {
                return try load(forSocketPath: socketPath, byteCount: byteCount)
            }
            throw AutomationIPCError.sharedSecretUnavailable
        }
        defer { _ = Darwin.close(fd) }
        do {
            try writeFileData(secret, to: fd)
            guard fchmod(fd, mode_t(0o600)) == 0 else {
                throw AutomationIPCError.sharedSecretUnavailable
            }
        } catch {
            _ = unlink(secretURL.path)
            throw error
        }
        return secret
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw AutomationIPCError.pathOccupied
            }
            guard (info.st_mode & mode_t(0o077)) == 0 else {
                throw AutomationIPCError.insecureSocketDirectory
            }
            return
        }
        let missingCode = errno
        guard missingCode == ENOENT else {
            throw AutomationIPCError.sharedSecretUnavailable
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw AutomationIPCError.sharedSecretUnavailable
        }
    }

    private static func writeFileData(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    throw AutomationIPCError.writeFailed(errno)
                }
            }
        }
    }
}
