import Foundation

nonisolated enum TrackAvailability: String, Codable, Sendable {
    case available
    case checking
    case stale
    case missing
    case permissionDenied
    case volumeUnavailable
    case notDownloaded

    var isPlayable: Bool { self == .available || self == .stale }
    var isRecoverable: Bool {
        switch self {
        case .checking, .stale, .permissionDenied, .volumeUnavailable, .notDownloaded:
            return true
        case .available, .missing:
            return false
        }
    }
}
