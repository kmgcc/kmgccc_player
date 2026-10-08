import Darwin
import Foundation
import PlayerAutomationProtocol

nonisolated enum AutomationAppIdentity {
    static var bundleIdentifier: String {
        for executablePath in executablePaths {
            if let bundleIdentifier = bundleIdentifier(atExecutablePath: executablePath) {
                return bundleIdentifier
            }
        }
        return Bundle.main.bundleIdentifier ?? "kmgccc.player"
    }

    private static var executablePaths: [String] {
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(getpid(), buffer.baseAddress, UInt32(buffer.count))
        }
        if length > 0 {
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            paths.append(String(decoding: bytes, as: UTF8.self))
        }
        if let argument = ProcessInfo.processInfo.arguments.first,
           !argument.isEmpty {
            paths.append(argument)
        }
        return paths
    }

    private static func bundleIdentifier(atExecutablePath executablePath: String) -> String? {
        let infoURL = URL(fileURLWithPath: executablePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let bundleIdentifier = propertyList["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty
        else {
            return nil
        }
        return bundleIdentifier
    }
}

struct AutomationScopePolicyFile: Codable {
    var schemaVersion = 2
    var grantedScopes: [String]
}

struct AutomationIdempotencyFile: Codable {
    var schemaVersion = 1
    var entries: [String: Entry]

    struct Entry: Codable {
        let fingerprint: String
        let response: AutomationResponse
        let storedAt: Date
    }
}

/// The scope file is deliberately small and App-owned. It is not a second
/// authentication mechanism: the AF_UNIX peer/secret check still gates the
/// process, while this store decides which catalog capabilities the caller may
/// invoke. Dangerous scopes are denied by default until a foreground App
/// confirmation grants them.
final class AutomationScopePolicyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let appSupport = appSupportDirectoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("scopes.json", isDirectory: false)
    }

    var defaultGrantedScopes: Set<AutomationScope> {
        Set(AutomationScope.allCases).subtracting([.filesDelete, .storageWrite, .libraryDelete])
    }

    /// A missing policy is the first-run high-autonomy default. A present but
    /// unreadable policy is different: fail closed to read-only capabilities
    /// rather than silently restoring write access after corruption.
    var readOnlyGrantedScopes: Set<AutomationScope> {
        Set(AutomationScope.allCases.filter { scope in
            scope.rawValue.hasSuffix(".read")
        })
    }

    func load() -> Set<AutomationScope> {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return defaultGrantedScopes
        }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AutomationScopePolicyFile.self, from: data),
              payload.schemaVersion == 1 || payload.schemaVersion == 2 else {
            return readOnlyGrantedScopes
        }
        var scopes = Set(payload.grantedScopes.compactMap(AutomationScope.init(rawValue:)))
        // Schema 1 predates the explicit lifecycle scope. It was not possible
        // to deny library lifecycle separately in that schema, so migrate the
        // new non-destructive management scope while keeping the new delete
        // scope denied by default.
        if payload.schemaVersion == 1 {
            scopes.insert(.libraryManage)
        }
        return scopes
    }

    func save(_ scopes: Set<AutomationScope>) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = AutomationScopePolicyFile(
            grantedScopes: scopes.map(\.rawValue).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }
}

/// Successful mutation responses are small enough to make idempotency useful
/// across an App restart. The response is stored in App-owned private support
/// storage, never in the public audit log, and is evicted with the same bound
/// as the in-memory cache.
final class AutomationIdempotencyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let appSupport = appSupportDirectoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("idempotency.json", isDirectory: false)
    }

    func load() -> [(key: String, fingerprint: String, response: AutomationResponse)] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AutomationIdempotencyFile.self, from: data),
              payload.schemaVersion == 1 else {
            return []
        }
        return payload.entries.map { key, entry in
            (key: key, fingerprint: entry.fingerprint, response: entry.response)
        }
    }

    func save(
        _ entries: [String: (fingerprint: String, response: AutomationResponse)],
        order: [String]
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let orderedKeys = order.reversed().filter { entries[$0] != nil }
        var stored: [String: AutomationIdempotencyFile.Entry] = [:]
        for key in orderedKeys {
            guard let entry = entries[key] else { continue }
            stored[key] = AutomationIdempotencyFile.Entry(
                fingerprint: entry.fingerprint,
                response: entry.response,
                storedAt: entry.response.serverTime
            )
        }
        let payload = AutomationIdempotencyFile(entries: stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }
}

/// Selection snapshots retain only ordered Track IDs and a content revision.
/// They are bounded per Library and contain no names, paths, or media data.
