import CryptoKit
import Foundation

/// Installs the bundled Agent skill into local agent skill directories.
///
/// The App and the CLI share one exported copy under Application Support.
/// Install targets are copies of that directory, so the installed skill and
/// the shipped one can be compared by content hash.
public enum AutomationSkillInstaller {
    public static let skillName = "kmgccc-player-automation"
    public static let recordName = ".kmgccc-install.json"
    public static let fallbackBundleIdentifier = "kmgccc.player"

    public struct Target: Identifiable, Sendable, Hashable {
        public let id: String
        public let displayName: String
        public let skillsDirectory: URL

        public var skillDirectory: URL {
            skillsDirectory.appendingPathComponent(
                AutomationSkillInstaller.skillName,
                isDirectory: true
            )
        }

        public var isAvailable: Bool {
            FileManager.default.fileExists(atPath: skillsDirectory.path)
        }
    }

    public enum Status: String, Sendable {
        case notInstalled
        case current
        case updateAvailable
        case modified
    }

    public enum InstallError: Error, LocalizedError {
        case bundledSkillMissing
        case sourceMissing
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bundledSkillMissing:
                return "The bundled agent skill is missing."
            case .sourceMissing:
                return "The exported agent skill is missing."
            case let .copyFailed(path):
                return "Could not write \(path)."
            }
        }
    }

    // MARK: - Locations

    /// The App bundle. The CLI lives at `Contents/Resources/Tools`, so the
    /// bundle is resolved from the executable path when the process is the CLI.
    public static var appBundleURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }
        var url = Bundle.main.executableURL
        url?.deleteLastPathComponent() // Tools
        url?.deleteLastPathComponent() // Resources
        url?.deleteLastPathComponent() // Contents
        url?.deleteLastPathComponent() // App
        guard let url, url.pathExtension == "app" else { return nil }
        return url
    }

    public static var bundleIdentifier: String {
        if let bundleURL = appBundleURL,
           let identifier = Bundle(url: bundleURL)?.bundleIdentifier {
            return identifier
        }
        return Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
    }

    /// Stable directory other agents can read from. It survives App moves and
    /// is refreshed from the bundle by `syncExport`.
    public static func exportDirectory() -> URL {
        supportDirectory().appendingPathComponent("skill", isDirectory: true)
    }

    public static func exportExecutableURL() -> URL {
        supportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("player-automation", isDirectory: false)
    }

    /// The bundled CLI. MCP configuration and the exported skill point at it
    /// through `exportExecutableURL()` so the App can move without breaking
    /// either entry point.
    public static var automationExecutableURL: URL? {
        if let bundleURL = appBundleURL {
            let candidate = bundleURL.appendingPathComponent(
                "Contents/Resources/Tools/player-automation"
            )
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.main.executableURL
    }

    public static func bundledSkillRoot() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("Skills/\(skillName)", isDirectory: true)
            )
        }
        if let bundleURL = appBundleURL {
            candidates.append(
                bundleURL.appendingPathComponent(
                    "Contents/Resources/Skills/\(skillName)",
                    isDirectory: true
                )
            )
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        }
    }

    // MARK: - Targets

    public static func targetCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Target] {
        [
            Target(
                id: "claude",
                displayName: "Claude Code",
                skillsDirectory: home.appendingPathComponent(".claude/skills", isDirectory: true)
            ),
            Target(
                id: "codex",
                displayName: "Codex",
                skillsDirectory: home.appendingPathComponent(".codex/skills", isDirectory: true)
            ),
            Target(
                id: "dsh",
                displayName: "DeepSeek Harness",
                skillsDirectory: home.appendingPathComponent(".dsh/skills", isDirectory: true)
            )
        ]
    }

    /// Targets whose skills directory already exists on this Mac.
    public static func availableTargets(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Target] {
        targetCandidates(home: home).filter {
            FileManager.default.fileExists(atPath: $0.skillsDirectory.path)
        }
    }

    public static func target(id: String) -> Target? {
        targetCandidates().first { $0.id == id }
    }

    // MARK: - Export

    /// Refresh the stable export directory from the App bundle.
    @discardableResult
    public static func syncExport(executableURL: URL) throws -> URL {
        guard let source = bundledSkillRoot() else {
            throw InstallError.bundledSkillMissing
        }
        let destination = exportDirectory()
        try replaceDirectory(at: destination, with: source)
        try linkExecutable(at: exportExecutableURL(), to: executableURL)
        return destination
    }

    private static func linkExecutable(at link: URL, to executable: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path),
           existing == executable.path {
            return
        }
        try? manager.removeItem(at: link)
        try manager.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    // MARK: - State

    public static func status(for target: Target) -> Status {
        let manager = FileManager.default
        let directory = target.skillDirectory
        guard manager.fileExists(atPath: directory.path),
              let installedHash = contentHash(of: directory) else {
            return .notInstalled
        }
        guard let exportHash = contentHash(of: exportDirectory()) else {
            return .updateAvailable
        }
        if installedHash == exportHash {
            return .current
        }
        if let record = readRecord(in: directory), record.contentHash == installedHash {
            return .updateAvailable
        }
        return .modified
    }

    // MARK: - Mutations

    @discardableResult
    public static func install(_ target: Target, executableURL: URL) throws -> Status {
        let export = try syncExport(executableURL: executableURL)
        let manager = FileManager.default
        try manager.createDirectory(
            at: target.skillsDirectory,
            withIntermediateDirectories: true
        )
        let destination = target.skillDirectory
        if manager.fileExists(atPath: destination.path),
           status(for: target) == .modified {
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(skillName).backup-\(timestamp())",
                    isDirectory: true
                )
            try? manager.moveItem(at: destination, to: backup)
        }
        try replaceDirectory(at: destination, with: export)
        if let hash = contentHash(of: destination) {
            writeRecord(Record(contentHash: hash, installedAt: Date()), to: destination)
        }
        return status(for: target)
    }

    public static func uninstall(_ target: Target) throws {
        let manager = FileManager.default
        let directory = target.skillDirectory
        guard manager.fileExists(atPath: directory.path) else { return }
        try manager.removeItem(at: directory)
    }

    // MARK: - Prompt

    /// Instruction for agents that install skills themselves.
    public static func installPrompt() -> String {
        """
        读取 \(exportDirectory().path) 下的 SKILL.md，按其中的说明操作本机播放器。\
        该目录可整体复制到你的 skills 目录；命令行入口是同目录的 bin/player-automation。
        """
    }

    // MARK: - Files

    private struct Record: Codable {
        let contentHash: String
        let installedAt: Date
    }

    private static func readRecord(in directory: URL) -> Record? {
        let url = directory.appendingPathComponent(recordName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    private static func writeRecord(_ record: Record, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: directory.appendingPathComponent(recordName))
    }

    private static func replaceDirectory(at destination: URL, with source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try manager.copyItem(at: source, to: destination)
        } catch {
            throw InstallError.copyFailed(destination.path)
        }
    }

    /// Content hash over every regular file, keyed by relative path. The
    /// install record is excluded so recording an install does not change it.
    static func contentHash(of directory: URL) -> String? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var entries: [(String, Data)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != recordName,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else {
                continue
            }
            let relative = url.path.replacingOccurrences(
                of: directory.path.hasSuffix("/") ? directory.path : directory.path + "/",
                with: ""
            )
            entries.append((relative, data))
        }
        guard !entries.isEmpty else { return nil }
        var hasher = SHA256()
        for (path, data) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
