import Foundation

nonisolated struct SourceReconnectMatcher: Sendable {
    let durationTolerance: Double

    init(durationTolerance: Double = 1) {
        self.durationTolerance = durationTolerance
    }

    func makePlan(
        rootURL: URL,
        expected: [SourceReconnectExpectedFile],
        candidates: [SourceReconnectCandidateFile]
    ) -> SourceReconnectPlan {
        var available = Set(candidates.indices)
        var matches: [SourceReconnectMatch] = []
        var conflicts: [SourceReconnectConflict] = []
        var unmatched: [UUID] = []

        for item in expected.sorted(by: expectedOrder) {
            if let index = uniqueCandidateIndex(
                in: available,
                candidates: candidates,
                where: { $0.relativePath == item.relativePath }
            ) {
                matches.append(match(item, candidates[index], basis: .relativePath))
                available.remove(index)
                continue
            }

            if let identity = item.fingerprint?.identity, identity.isStableForReconnect {
                let identityMatches = available.filter { index in
                    candidates[index].fingerprint.identity == identity
                }
                if identityMatches.count == 1, let index = identityMatches.first {
                    matches.append(match(item, candidates[index], basis: .physicalIdentity))
                    available.remove(index)
                    continue
                }
                if identityMatches.count > 1 {
                    conflicts.append(conflict(item, indices: identityMatches, candidates: candidates))
                    continue
                }
            }

            let fallbackIndices = available.filter { index in
                fallbackMatches(item, candidates[index])
            }
            if fallbackIndices.count == 1, let index = fallbackIndices.first {
                matches.append(match(item, candidates[index], basis: .fingerprint))
                available.remove(index)
            } else if fallbackIndices.count > 1 {
                conflicts.append(conflict(item, indices: fallbackIndices, candidates: candidates))
            } else {
                unmatched.append(item.trackID)
            }
        }

        return SourceReconnectPlan(
            rootURL: rootURL,
            candidates: candidates.sorted { $0.relativePath < $1.relativePath },
            matches: matches.sorted { $0.previousRelativePath < $1.previousRelativePath },
            conflicts: conflicts.sorted { $0.expected.relativePath < $1.expected.relativePath },
            unmatchedTrackIDs: unmatched.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func uniqueCandidateIndex(
        in available: Set<Int>,
        candidates: [SourceReconnectCandidateFile],
        where predicate: (SourceReconnectCandidateFile) -> Bool
    ) -> Int? {
        let result = available.filter { predicate(candidates[$0]) }
        return result.count == 1 ? result.first : nil
    }

    private func fallbackMatches(
        _ expected: SourceReconnectExpectedFile,
        _ candidate: SourceReconnectCandidateFile
    ) -> Bool {
        guard let fingerprint = expected.fingerprint,
              fingerprint.fileSize == candidate.fingerprint.fileSize else {
            return false
        }
        let durationMatches = expected.duration <= 0
            || candidate.duration <= 0
            || abs(expected.duration - candidate.duration) <= durationTolerance
        guard durationMatches else { return false }

        if approximatelyEqual(fingerprint.modifiedAt, candidate.fingerprint.modifiedAt) {
            return true
        }
        return expected.duration > 0 && candidate.duration > 0
    }

    private func approximatelyEqual(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private func match(
        _ expected: SourceReconnectExpectedFile,
        _ candidate: SourceReconnectCandidateFile,
        basis: SourceReconnectMatchBasis
    ) -> SourceReconnectMatch {
        SourceReconnectMatch(
            trackID: expected.trackID,
            previousRelativePath: expected.relativePath,
            candidate: candidate,
            basis: basis
        )
    }

    private func conflict(
        _ expected: SourceReconnectExpectedFile,
        indices: Set<Int>,
        candidates: [SourceReconnectCandidateFile]
    ) -> SourceReconnectConflict {
        SourceReconnectConflict(
            expected: expected,
            candidates: indices.map { candidates[$0] }.sorted { $0.relativePath < $1.relativePath }
        )
    }

    private func expectedOrder(
        _ lhs: SourceReconnectExpectedFile,
        _ rhs: SourceReconnectExpectedFile
    ) -> Bool {
        if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
        return lhs.trackID.uuidString < rhs.trackID.uuidString
    }
}

nonisolated private extension ReferencedFileIdentity {
    var isStableForReconnect: Bool {
        volumeUUID?.isEmpty == false && resourceIdentifierArchive?.isEmpty == false
    }
}
