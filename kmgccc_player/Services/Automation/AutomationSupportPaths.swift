import Foundation

nonisolated enum AutomationSupportPaths {
    nonisolated static func automationSupportDirectory(
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) -> URL {
        let appSupport = appSupportDirectoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
    }
}
