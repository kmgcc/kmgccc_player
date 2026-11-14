import Foundation

extension Track {
    /// Catalog recordings can name an earlier release of a compilation song.
    /// Keep that candidate under the existing source/override projection.
    func recordProgramMetadataMatch(_ detail: TrackMetadataDetail) -> Bool {
        guard mediaSelection != nil else { return false }
        var suggestions = enrichmentSuggestions ?? []
        let source = detail.source.rawValue
        guard !suggestions.contains(where: {
            $0.source == source && $0.title == detail.title && $0.artistDisplay == detail.artist && $0.album == detail.album
        }) else { return false }
        suggestions.append(EnrichmentSuggestion(source: source, title: detail.title,
            artistDisplay: detail.artist, album: detail.album,
            releaseYear: detail.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            confidence: detail.confidence, createdAt: detail.fetchedAt ?? Date()))
        enrichmentSuggestions = suggestions
        return true
    }
}
