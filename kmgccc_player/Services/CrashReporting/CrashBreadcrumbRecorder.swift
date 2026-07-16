import Foundation

nonisolated enum CrashBreadcrumbEvent: Sendable {
    case appLaunchStarted
    case dependenciesReady

    var category: String {
        switch self {
        case .appLaunchStarted, .dependenciesReady:
            "lifecycle"
        }
    }

    var action: String {
        switch self {
        case .appLaunchStarted:
            "app_launch_started"
        case .dependenciesReady:
            "dependencies_ready"
        }
    }
}

nonisolated enum CrashBreadcrumbMetadataKey: String, Sendable {
    case path
    case source
    case result
    case reason
    case surface
}

@MainActor
final class CrashBreadcrumbRecorder {
    static let shared = CrashBreadcrumbRecorder()

    private let maxBreadcrumbs = 100
    private let maxCustomDataBytes = 48 * 1024
    private var context: CrashAppContext?
    private var breadcrumbs: [CrashBreadcrumb] = []

    private init() {}

    func updateAppContext(_ update: (inout CrashAppContext) -> Void) {
        var value = context ?? CrashAppContext(
            playbackSourceCategory: "unknown",
            isPlaying: nil,
            visibleSurface: "unknown",
            isFullScreen: false,
            selectedSkinIdentifier: nil,
            lastOperationCategory: nil
        )
        update(&value)
        context = value
        refreshReporterCustomData()
    }

    func record(
        _ event: CrashBreadcrumbEvent,
        metadata: [CrashBreadcrumbMetadataKey: CrashDiagnosticValue] = [:]
    ) {
        breadcrumbs.append(
            CrashBreadcrumb(
                occurredAt: Date(),
                category: event.category,
                action: event.action,
                metadata: Dictionary(uniqueKeysWithValues: metadata.map { ($0.key.rawValue, $0.value) })
            )
        )
        if breadcrumbs.count > maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
        }
        refreshReporterCustomData()
    }

    private func refreshReporterCustomData() {
        var retained = breadcrumbs
        while true {
            let snapshot = CrashCaptureSnapshot(appContext: context, breadcrumbs: retained)
            guard let data = try? JSONEncoder.crashReportEncoder().encode(snapshot) else { return }
            if data.count <= maxCustomDataBytes {
                CrashReporterBootstrap.shared.setCustomData(data)
                return
            }
            guard !retained.isEmpty else { return }
            retained.removeFirst()
        }
    }
}
