import Foundation

extension MusicEnrichmentService {
    func patchAttributes(
        fields: [String: MusicMetadataValue], clearFields: [String], for query: MusicEnrichmentQuery
    ) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        let expectedGeneration = generation
        let record = try await store.updateRecord(key: query.key, fallbackQuery: query, alignQuery: true) { record in
            try Task.checkCancellation()
            var manual = record.manualAttributes ?? [:]
            for key in clearFields { manual[key] = nil }
            for (key, value) in fields { manual[key] = value }
            record.manualAttributes = manual.isEmpty ? nil : manual
        }
        return try await publishEditedRecord(record, expectedGeneration: expectedGeneration)
    }

    func clearMotion(for query: MusicEnrichmentQuery, resumeAutomatic: Bool) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed else { throw CancellationError() }
        let expectedGeneration = generation
        resetMotionSelectionTasks(for: query.key)
        let record = try await store.updateRecord(key: query.key, fallbackQuery: query, alignQuery: true) { record in
            try Task.checkCancellation()
            record.assets = []
            record.query.storedMotionArtwork = nil
            record.manualMotionSelection = resumeAutomatic ? nil : MusicEnrichmentResult(source: "manual", motion: [])
        }
        let snapshot = try await publishEditedRecord(record, expectedGeneration: expectedGeneration)
        if resumeAutomatic { resumeMotionAssetsAfterEdit(for: query.key) }
        return snapshot
    }

    private func publishEditedRecord(_ record: MusicEnrichmentRecord, expectedGeneration: UUID) async throws -> MusicEnrichmentSnapshot {
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        let snapshot = await store.snapshot(record)
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        if currentKey == record.query.key, generation == expectedGeneration {
            // Only replace the same query. A late manual edit for a previous
            // song remains persisted without taking over current playback.
            currentRecord = record
            await publish(generation: generation, persist: false)
        } else if currentKey != record.query.key { onSnapshot?(snapshot) }
        return snapshot
    }
}
