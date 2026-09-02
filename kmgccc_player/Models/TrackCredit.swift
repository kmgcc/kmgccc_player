import Foundation

/// A structured contributor attached to a track. `Track.artist` remains the
/// original display string for compatibility; credits are the normalized,
/// role-aware projection used by artist and search surfaces.
nonisolated enum TrackCreditRole: String, Codable, Sendable, CaseIterable {
    case primary
    case featured
    case remixer
    case composer
    case producer
    case conductor
    case unknown

    var isArtistContributor: Bool {
        switch self {
        case .primary, .featured, .remixer, .unknown:
            return true
        case .composer, .producer, .conductor:
            return false
        }
    }
}

nonisolated struct TrackCredit: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var canonicalName: String
    var role: TrackCreditRole

    init(
        id: UUID = UUID(),
        displayName: String,
        role: TrackCreditRole = .primary,
        canonicalName: String? = nil
    ) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedCanonical = canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.displayName = trimmed
        self.canonicalName = suppliedCanonical.flatMap { $0.isEmpty ? nil : $0 }
            ?? LibraryTextNormalization.normalize(
                trimmed,
                fallback: LibraryTextNormalization.unknownArtist
            )
        self.role = role
    }

    static func fallback(for rawArtist: String) -> [TrackCredit] {
        let trimmed = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [TrackCredit(displayName: trimmed, role: .primary)]
    }

    /// NCM stores each contributor as an array whose first value is the
    /// display name. Preserve every name and make the first one primary while
    /// retaining the raw joined artist string separately on Track.
    static func fromNCMArtists(_ artists: [[String]]) -> [TrackCredit] {
        artists
            .compactMap { values in
                values.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .enumerated()
            .compactMap { index, name in
                guard !name.isEmpty else { return nil }
                return TrackCredit(
                    displayName: name,
                    role: index == 0 ? .primary : .featured
                )
            }
    }

    var isPrimaryArtist: Bool { role == .primary }
}
