import Foundation

/// Exports the Agent skill that ships inside the App bundle.
///
/// Settings shows the exported directory so users copy it into their Agent's
/// skill directory by hand, and `installPrompt` gives Agents a ready-made
/// instruction for doing the same.
public enum AutomationSkillInstaller {
    public static let skillName = "kmgccc-player-automation"
    public static let fallbackBundleIdentifier = "kmgccc.player"

    public enum InstallError: Error, LocalizedError {
        case bundledSkillMissing
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bundledSkillMissing:
                return "The bundled agent skill is missing."
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

    /// Stable directory users and Agents copy from. It survives App moves and
    /// is refreshed from the bundle by `syncExport`.
    public static func exportDirectory() -> URL {
        supportDirectory().appendingPathComponent("skill", isDirectory: true)
    }

    /// CLI entry point the skill refers to. It is a symlink so the App can
    /// move without breaking the documented path.
    public static func exportExecutableURL() -> URL {
        supportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("player-automation", isDirectory: false)
    }

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

    // MARK: - Prompt

    /// Instruction for Agents that install the skill themselves. It names the
    /// source and the CLI, and leaves the install location to the Agent, whose
    /// own tool decides where skills live.
    public static func installPrompt() -> String {
        """
        这是 kmgccc_player 的技能包，源目录保持原样，不要移动或改动：
        \(exportDirectory().path)

        装的时候按你所用工具的规则来：不同 Agent 的技能目录不一样，放到你的工具能加载的位置。优先建软链接而不是复制，播放器更新技能后会自动同步；一个工具只装一处，装完确认技能列表里出现 kmgccc-player-automation。

        之后用 \(exportExecutableURL().path) 操作播放器。命令走本机自动化接口，播放器没在运行时会自动启动，超时重试一次即可；automation tools 不依赖播放器，可以先跑它确认通路。
        """
    }

    // MARK: - Files

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
}
