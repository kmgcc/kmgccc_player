import Foundation

@MainActor
extension LibrarySession {
    /// Starts one independently cancellable Job for this explicit request.
    /// The coordinator serializes decoder work across Jobs.
    @discardableResult
    func startAutomationLoudnessAnalyze(trackIDs: [UUID]) -> LibraryOperationTaskDescriptor? {
        var seen = Set<UUID>()
        let uniqueIDs = trackIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return nil }
        loudnessService.updatePlaybackTrimPolicy(enabled: AppSettings.shared.audioAACGaplessTrimEnabled)

        return startAutomationJob(
            totalCount: uniqueIDs.count,
            retrySpec: .loudnessAnalyze(trackIDs: uniqueIDs)
        ) { [weak self] reporter in
            guard let self else { return }
            await self.loudnessService.scan(trackIDs: uniqueIDs, reporter: reporter) { [weak self] trackID in
                self?.libraryViewModel.allTracks.first { $0.id == trackID }
            }
        }
    }

    /// Playback calls this only for an enabled, background-scan-eligible
    /// configuration. Background requests may reuse a Job that already owns
    /// the requested ID; explicit analyze requests always get their own Job.
    func scheduleMissingLoudnessMeasurement(trackID: UUID) {
        loudnessService.updatePlaybackTrimPolicy(enabled: AppSettings.shared.audioAACGaplessTrimEnabled)
        if libraryJobDescriptorsSnapshot().contains(where: { descriptor in
            guard let retrySpec = descriptor.retrySpec,
                  retrySpec.kind == .loudnessAnalyze,
                  retrySpec.trackIDs.contains(trackID) else { return false }
            switch descriptor.state {
            case .queued, .running, .checkpointed: return true
            case .completed, .partialFailure, .failed, .cancelled: return false
            }
        }) {
            return
        }
        _ = startAutomationLoudnessAnalyze(trackIDs: [trackID])
    }

    func loudnessRecords(trackIDs: [UUID]) -> [UUID: LoudnessTrackRecord] {
        loudnessService.recordsSnapshot(trackIDs: trackIDs)
    }

    func loadLoudnessRecords(trackIDs: [UUID]) async -> [UUID: LoudnessTrackRecord] {
        await loudnessService.loadRecordsSnapshot(trackIDs: trackIDs)
    }
}
