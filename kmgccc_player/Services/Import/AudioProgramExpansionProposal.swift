import Foundation

nonisolated struct AudioProgramExpansionProposal: Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceURL: URL
    let oldTrackIDs: [UUID]
    let trackCount: Int
}
