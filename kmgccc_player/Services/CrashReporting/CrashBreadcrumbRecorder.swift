import Foundation

nonisolated enum CrashPlaybackCommand: String, Sendable {
    case playPause = "play_pause"
    case pause
    case resume
    case stop
    case next
    case previous
    case seek
    case playQueue = "play_queue"
    case playTrack = "play_track"
    case playTrackFromQueue = "play_track_from_queue"
}

nonisolated enum CrashBreadcrumbEvent: Sendable {
    case appLaunchStarted
    case dependenciesReady
    case playbackCommand(CrashPlaybackCommand)
    case playbackSourceChanged
    case playbackStateChanged
    case presentationChanged
    case libraryImportStarted
    case libraryImportFinished

    var category: String {
        switch self {
        case .appLaunchStarted, .dependenciesReady:
            "lifecycle"
        case .playbackCommand, .playbackSourceChanged, .playbackStateChanged:
            "playback"
        case .presentationChanged:
            "presentation"
        case .libraryImportStarted, .libraryImportFinished:
            "library"
        }
    }

    var action: String {
        switch self {
        case .appLaunchStarted:
            "app_launch_started"
        case .dependenciesReady:
            "dependencies_ready"
        case .playbackCommand(let command):
            command.rawValue
        case .playbackSourceChanged:
            "source_changed"
        case .playbackStateChanged:
            "state_changed"
        case .presentationChanged:
            "surface_changed"
        case .libraryImportStarted:
            "import_started"
        case .libraryImportFinished:
            "import_finished"
        }
    }

    var lastOperationCategory: String? {
        switch self {
        case .appLaunchStarted, .dependenciesReady, .playbackStateChanged:
            nil
        case .playbackCommand(let command):
            "playback.\(command.rawValue)"
        case .playbackSourceChanged:
            "playback.source_changed"
        case .presentationChanged:
            "presentation.surface_changed"
        case .libraryImportStarted, .libraryImportFinished:
            "library.import"
        }
    }

    var coalescingInterval: TimeInterval? {
        switch self {
        case .playbackCommand(.seek):
            2
        case .playbackStateChanged, .presentationChanged:
            1
        default:
            nil
        }
    }
}

nonisolated enum CrashBreadcrumbMetadataKey: String, Sendable {
    case path
    case source
    case result
    case reason
    case surface
    case state
    case skin
    case count
}

@MainActor
final class CrashBreadcrumbRecorder {
    static let shared = CrashBreadcrumbRecorder()

    private let maxBreadcrumbs = 100
    private let maxCustomDataBytes = 48 * 1024
    private var sessionID: String?
    private var context: CrashAppContext?
    private var breadcrumbs: [CrashBreadcrumb] = []

    private init() {}

    func updateSessionID(_ sessionID: String?) {
        guard self.sessionID != sessionID else { return }
        self.sessionID = sessionID
        refreshReporterCustomData()
    }

    func updateAppContext(_ update: (inout CrashAppContext) -> Void) {
        var value = context ?? defaultContext()
        update(&value)
        context = value
        refreshReporterCustomData()
    }

    func record(
        _ event: CrashBreadcrumbEvent,
        metadata: [CrashBreadcrumbMetadataKey: CrashDiagnosticValue] = [:]
    ) {
        let breadcrumb = CrashBreadcrumb(
            occurredAt: Date(),
            category: event.category,
            action: event.action,
            metadata: Dictionary(uniqueKeysWithValues: metadata.map { ($0.key.rawValue, $0.value) })
        )
        if let interval = event.coalescingInterval,
           let previous = breadcrumbs.last,
           previous.category == breadcrumb.category,
           previous.action == breadcrumb.action,
           let previousDate = previous.occurredAt,
           let occurredAt = breadcrumb.occurredAt,
           occurredAt.timeIntervalSince(previousDate) <= interval {
            breadcrumbs[breadcrumbs.count - 1] = breadcrumb
        } else {
            breadcrumbs.append(breadcrumb)
        }
        if breadcrumbs.count > maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maxBreadcrumbs)
        }
        if let lastOperationCategory = event.lastOperationCategory {
            var value = context ?? defaultContext()
            value.lastOperationCategory = lastOperationCategory
            context = value
        }
        refreshReporterCustomData()
    }

    private func defaultContext() -> CrashAppContext {
        CrashAppContext(
            playbackSourceCategory: "unknown",
            isPlaying: nil,
            visibleSurface: "unknown",
            isFullScreen: false,
            selectedSkinIdentifier: nil,
            lastOperationCategory: nil
        )
    }

    private func refreshReporterCustomData() {
        var retained = breadcrumbs
        while true {
            let snapshot = CrashCaptureSnapshot(
                sessionID: sessionID,
                appContext: context,
                breadcrumbs: retained
            )
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
