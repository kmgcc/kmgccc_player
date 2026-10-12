import Foundation

@MainActor
extension LoudnessAlbumMember {
    init(track: Track) {
        let properties = track.audioProperties
        let fileName = track.audioFileName.isEmpty ? track.originalFilePath : track.audioFileName
        let fileExtension = fileName.contains(".") ? fileName.split(separator: ".").last.map(String.init) : nil
        self.init(
            trackID: track.id,
            album: track.album,
            albumArtist: track.albumArtist,
            artist: track.artist,
            codec: properties?.codec ?? properties?.format ?? fileExtension,
            sampleRateHz: properties?.sampleRateHz
        )
    }
}

@MainActor
extension LibrarySession {
    /// Connects the library's loudness service to the App scheduler and to
    /// the library's own track and album records.
    func configureLoudness(scheduler: BackgroundWorkScheduler, habits: ListeningHabitForecast) {
        loudnessService.scheduler = scheduler
        loudnessService.updatePlaybackTrimPolicy(enabled: AppSettings.shared.audioAACGaplessTrimEnabled)
        loudnessService.trackProvider = { [weak self] id in
            self?.libraryViewModel.allTracks.first { $0.id == id }
        }
        loudnessService.albumJudgementProvider = { [weak self] track in
            self?.loudnessAlbumJudgement(for: track)
        }
        loudnessService.onAlbumMeasurementsChanged = { [weak self] albumKey in
            self?.refreshLoudnessForAlbum(albumKey)
        }
        // The album switch is a listener's choice: it applies to the playing
        // song at once, and may queue the album's other members.
        libraryViewModel.onAlbumLoudnessOverrideChanged = { [weak self] _ in
            self?.reapplyLoudnessToPlayback()
        }
        libraryViewModel.loudnessService = loudnessService
        libraryViewModel.onRemeasureLoudness = { [weak self] ids in
            self?.startAutomationLoudnessAnalyze(trackIDs: ids, force: true)
        }
        loudnessHabits = habits
    }

    /// Switching volume normalization on loads the cache and starts the
    /// library-wide idle measurement; switching it off withdraws idle work.
    func loudnessEnabledDidChange(_ enabled: Bool) {
        guard enabled else {
            loudnessService.stopIdleLibraryScan(clearingPause: true)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.loudnessService.loadSnapshot()
            // Switching on applies to the playing song at once when it is
            // measured; otherwise it is measured first, at the listener's
            // priority, and the result applies from its next play.
            if let current = self.playerViewModel.currentTrack {
                if case .unmeasured = self.loudnessService.measurementState(for: current.id) {
                    self.loudnessService.requestMeasurement(trackIDs: [current.id], priority: .userRequested)
                } else {
                    // A result stored on disk applies to the playing song now.
                    _ = await self.loudnessService.loadRecordsSnapshot(trackIDs: [current.id])
                    self.reapplyLoudnessToPlayback()
                }
            }
            self.loudnessService.requestMeasurement(
                trackIDs: self.upcomingQueueTrackIDs(limit: 3), priority: .upcoming
            )
            self.loudnessService.startIdleLibraryScan(orderedTrackIDs: self.idleLoudnessOrder())
        }
    }

    /// Library order for idle measurement: upcoming songs, then songs the
    /// listener plays often, then everything else. When the listening habit
    /// suggests a session soon, the often-played group is widened.
    func idleLoudnessOrder() -> [UUID] {
        let upcoming = upcomingQueueTrackIDs(limit: 20)
        let upcomingSet = Set(upcoming)
        let remaining = libraryViewModel.allTracks.map(\.id).filter { !upcomingSet.contains($0) }
        let scores = Dictionary(uniqueKeysWithValues: remaining.map {
            ($0, preferenceStatsService.getPreferenceScore(for: $0))
        })
        let favouriteShare = (loudnessHabits?.expectsListeningSoon() ?? false) ? 0.4 : 0.2
        let favouriteCount = Int(Double(remaining.count) * favouriteShare)
        let favourites = remaining.sorted { (scores[$0] ?? 0) > (scores[$1] ?? 0) }.prefix(favouriteCount)
        let favouriteSet = Set(favourites)
        return upcoming + favourites + remaining.filter { !favouriteSet.contains($0) }
    }

    /// Whether an album group shares one gain: the automatic judgement plus
    /// the album's own switch in its information editor.
    func loudnessAlbumJudgement(for track: Track) -> LoudnessAlbumJudgement? {
        let key = track.albumGroupKey
        guard !key.isEmpty else { return nil }
        let members = libraryViewModel.allTracks.filter { $0.albumGroupKey == key }
        guard !members.isEmpty else { return nil }
        let entry = libraryViewModel.albumEntries.first { $0.canonicalKey == key }
        return LoudnessAlbumPolicy.judge(
            albumKey: key,
            albumType: entry?.albumType,
            members: members.map(LoudnessAlbumMember.init(track:)),
            override: entry?.loudnessUnifiedOverride
        )
    }

    func loudnessAlbumJudgement(forAlbumKey key: String) -> LoudnessAlbumJudgement? {
        libraryViewModel.allTracks.first { $0.albumGroupKey == key }.flatMap(loudnessAlbumJudgement(for:))
    }

    /// An explicit analysis request is tracked as a Job (progress, cancel,
    /// history) but runs beside, not inside, the library's write queue.
    /// `force` measures again even when a current result is stored.
    @discardableResult
    func startAutomationLoudnessAnalyze(trackIDs: [UUID], force: Bool = false) -> LibraryOperationTaskDescriptor? {
        var seen = Set<UUID>()
        let uniqueIDs = trackIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return nil }
        loudnessService.updatePlaybackTrimPolicy(enabled: AppSettings.shared.audioAACGaplessTrimEnabled)
        return startConcurrentJob(
            kind: .loudnessAnalysis,
            totalCount: uniqueIDs.count,
            retrySpec: .loudnessAnalyze(trackIDs: uniqueIDs)
        ) { [weak self] reporter in
            guard let self else { return }
            await self.loudnessService.loadSnapshot()
            await self.loudnessService.scan(trackIDs: uniqueIDs, force: force, reporter: reporter)
        }
    }

    func pauseIdleLoudnessScan() {
        loudnessService.pauseIdleLibraryScan()
    }

    func resumeIdleLoudnessScan() {
        loudnessService.resumeIdleLibraryScan(orderedTrackIDs: idleLoudnessOrder())
    }

    func loudnessRecords(trackIDs: [UUID]) -> [UUID: LoudnessTrackRecord] {
        loudnessService.recordsSnapshot(trackIDs: trackIDs)
    }

    func loadLoudnessRecords(trackIDs: [UUID]) async -> [UUID: LoudnessTrackRecord] {
        await loudnessService.loadRecordsSnapshot(trackIDs: trackIDs)
    }
}
