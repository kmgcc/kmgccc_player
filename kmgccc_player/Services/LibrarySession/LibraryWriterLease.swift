import Darwin
import Foundation
import os

nonisolated enum LibraryWriterLeaseError: Error, Equatable, LocalizedError, Sendable {
    case libraryInUse(URL)
    case writerLeaseUnsupported(URL)
    case cannotPrepareLockDirectory(String)
    case cannotOpenLockFile(String, Int32)
    case cannotWriteDiagnostic(String)

    var errorDescription: String? {
        switch self {
        case .libraryInUse:
            return "这个资料库已由另一个 App 进程打开，无法同时写入。"
        case .writerLeaseUnsupported:
            return "当前磁盘无法证明资料库写锁可靠，已拒绝以可写方式打开。"
        case .cannotPrepareLockDirectory(let reason):
            return "无法准备资料库写锁目录：\(reason)"
        case .cannotOpenLockFile(let path, let code):
            return "无法打开资料库写锁（\(path)，错误码 \(code)）。"
        case .cannotWriteDiagnostic(let reason):
            return "无法写入资料库锁诊断信息：\(reason)"
        }
    }
}

/// Session-lifetime, cross-process single-writer lease for one Library root.
///
/// The file content is diagnostic only. Exclusivity comes exclusively from
/// a kernel-managed BSD advisory lock, which is released automatically if the
/// process exits and explicitly after every runtime owner has closed.
nonisolated final class LibraryWriterLease: @unchecked Sendable {
    private struct State {
        var descriptor: Int32
        var isReleased = false
    }

    /// POSIX record locks are process-associated. Keep an in-process registry
    /// as well so a second session in this App process cannot accidentally
    /// merge with the already-held kernel lock.
    private nonisolated static let activeLockPaths = OSAllocatedUnfairLock(
        initialState: Set<String>()
    )

    let lockURL: URL
    private let registryKey: String

    private let state: OSAllocatedUnfairLock<State>

    var isReleased: Bool {
        state.withLock { $0.isReleased }
    }

    private init(lockURL: URL, registryKey: String, descriptor: Int32) {
        self.lockURL = lockURL
        self.registryKey = registryKey
        state = OSAllocatedUnfairLock(initialState: State(descriptor: descriptor))
    }

    static func acquire(
        paths: LibraryPaths,
        fileManager: FileManager = .default,
        processID: Int32 = getpid()
    ) throws -> LibraryWriterLease {
        do {
            try fileManager.createDirectory(
                at: paths.settingsRootURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw LibraryWriterLeaseError.cannotPrepareLockDirectory(
                error.localizedDescription
            )
        }

        let path = paths.writerLockURL.path
        let registryKey = paths.writerLockURL.resolvingSymlinksInPath().standardizedFileURL.path
        let alreadyActive = activeLockPaths.withLock { $0.contains(registryKey) }
        guard !alreadyActive else {
            throw LibraryWriterLeaseError.libraryInUse(paths.writerLockURL)
        }
        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw LibraryWriterLeaseError.cannotOpenLockFile(path, errno)
        }

        do {
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw LibraryWriterLeaseError.cannotOpenLockFile(path, errno)
            }
            // The kernel-managed BSD lock is the authoritative single-writer
            // boundary. Do not fork a probe from this multithreaded app during
            // startup: Xcode's injected debug runtime can make that probe
            // fail or hang even when the lock itself works correctly.
            try acquireExclusiveLock(descriptor: descriptor, lockURL: paths.writerLockURL)
            activeLockPaths.withLock { _ = $0.insert(registryKey) }
            try writeDiagnostic(
                descriptor: descriptor,
                libraryRoot: paths.rootURL,
                processID: processID
            )
            return LibraryWriterLease(
                lockURL: paths.writerLockURL,
                registryKey: registryKey,
                descriptor: descriptor
            )
        } catch {
            activeLockPaths.withLock { _ = $0.remove(registryKey) }
            unlock(descriptor: descriptor)
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func release() {
        let descriptor = state.withLock { state -> Int32? in
            guard !state.isReleased else { return nil }
            state.isReleased = true
            let descriptor = state.descriptor
            state.descriptor = -1
            return descriptor
        }
        guard let descriptor else { return }
        Self.activeLockPaths.withLock { _ = $0.remove(registryKey) }
        Self.unlock(descriptor: descriptor)
        _ = Darwin.close(descriptor)
    }

    deinit {
        release()
    }

    private static func acquireExclusiveLock(
        descriptor: Int32,
        lockURL: URL
    ) throws {
        guard kmgccc_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw LibraryWriterLeaseError.libraryInUse(lockURL)
            }
            if code == ENOTSUP || code == EOPNOTSUPP {
                throw LibraryWriterLeaseError.writerLeaseUnsupported(lockURL)
            }
            throw LibraryWriterLeaseError.cannotOpenLockFile(lockURL.path, code)
        }
    }

    nonisolated private static func unlock(descriptor: Int32) {
        _ = kmgccc_flock(descriptor, LOCK_UN)
    }

    private static func writeDiagnostic(
        descriptor: Int32,
        libraryRoot: URL,
        processID: Int32
    ) throws {
        let diagnostic = "schema=1\npid=\(processID)\nroot=\(libraryRoot.path)\nacquiredAt=\(Date().timeIntervalSince1970)\n"
        let data = Data(diagnostic.utf8)

        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw LibraryWriterLeaseError.cannotWriteDiagnostic(
                String(cString: strerror(errno))
            )
        }

        let didWriteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard didWriteAll, Darwin.fsync(descriptor) == 0 else {
            throw LibraryWriterLeaseError.cannotWriteDiagnostic(
                String(cString: strerror(errno))
            )
        }
    }
}
