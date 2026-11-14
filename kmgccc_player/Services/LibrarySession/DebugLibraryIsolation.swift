#if DEBUG
import Foundation

/// Keeps main-App acceptance runs on their own registry and factory library.
nonisolated enum DebugLibraryIsolation {
    static var rootURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["KMGCCC_DEBUG_LIBRARY_ROOT"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
#endif
