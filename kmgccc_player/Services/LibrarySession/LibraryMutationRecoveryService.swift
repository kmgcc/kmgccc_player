import Foundation

/// One record that a journal intent's durable projection could not absorb.
nonisolated struct LibraryProjectionIssue: Sendable, Equatable, Identifiable {
    let path: URL
    let detail: String

    var id: String { path.path }
}

nonisolated struct NCMProjectionRecord: Sendable, Equatable {
    let operationID: UUID
    let trackID: UUID?
    let outputPath: String
    let outputExists: Bool
}

/// A read-only snapshot of the durable projections a journal intent may have
/// touched. Recovery never treats the journal itself as proof: every verdict
/// is derived from the files that the library reloads as authority.
nonisolated struct LibraryMutationProjectionSnapshot: Sendable, Equatable {
    var trackIDs: Set<UUID> = []
    var trackFolderIDs: Set<UUID> = []
    var managedAudioExists: [UUID: Bool] = [:]
    var playlistIDs: Set<UUID> = []
    var sourceIDs: Set<UUID> = []
    /// NCM association stored on each loaded track sidecar.
    var ncmAssociations: [UUID: NCMConversionAssociation] = [:]
    /// Committed NCM registry entries, keyed by operation identifier.
    var ncmRecords: [UUID: NCMProjectionRecord] = [:]
    var ncmJournalIsValid = true
    var playlistMembershipIsValid = false
    var settingsIsValid = false
    var issues: [LibraryProjectionIssue] = []
    var sourceIssues: [LibraryProjectionIssue] = []
    var ncmIssues: [LibraryProjectionIssue] = []
    /// A bounded, human-readable sample of tracks the read-only pass could
    /// load. Used by the repair surface to show that most data is intact.
    var sampleTrackTitles: [String] = []
    /// False when a directory could not be enumerated. An incomplete view can
    /// never prove that a target projection is present or absent.
    var isComplete = false

    var trackCount: Int { trackIDs.count }
    var trackFolderCount: Int { trackFolderIDs.count }
}

nonisolated struct LibraryMutationVerification: Sendable, Equatable {
    let intentID: UUID
    let isResolved: Bool
    let summary: String
}

nonisolated enum LibraryMutationProjectionReader {
    static func read(
        paths: LibraryPaths,
        fileManager: FileManager = .default
    ) -> LibraryMutationProjectionSnapshot {
        var snapshot = LibraryMutationProjectionSnapshot()
        var complete = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let tracks = try? fileManager.contentsOfDirectory(
            at: paths.tracksRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for folder in tracks {
                guard let trackID = UUID(uuidString: folder.lastPathComponent) else { continue }
                snapshot.trackFolderIDs.insert(trackID)
                let metaURL = paths.trackMetaURL(for: trackID)
                guard let data = try? Data(contentsOf: metaURL) else {
                    snapshot.issues.append(.init(path: metaURL, detail: "track sidecar cannot be read"))
                    continue
                }
                do {
                    let sidecar = try decoder.decode(TrackSidecar.self, from: data)
                    guard sidecar.id == trackID else {
                        snapshot.issues.append(.init(path: metaURL, detail: "track identifier mismatch"))
                        continue
                    }
                    snapshot.trackIDs.insert(trackID)
                    if let association = sidecar.ncmConversionAssociation {
                        snapshot.ncmAssociations[trackID] = association
                    }
                    if snapshot.sampleTrackTitles.count < 20 {
                        let artist = sidecar.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                        snapshot.sampleTrackTitles.append(
                            artist.isEmpty ? sidecar.title : "\(sidecar.title)（\(artist)）"
                        )
                    }
                    switch sidecar.mediaLocator {
                    case let .managed(relativePath):
                        let audio = paths.libraryURL(from: relativePath)
                            ?? sidecar.audioFileName.flatMap { paths.trackAssetURL(for: trackID, fileName: $0) }
                        snapshot.managedAudioExists[trackID] = audio.map {
                            fileManager.fileExists(atPath: $0.path)
                        } ?? false
                    case .referenced:
                        // External availability is a source concern, not a
                        // commit projection. A present sidecar is enough here.
                        snapshot.managedAudioExists[trackID] = true
                    }
                } catch {
                    snapshot.issues.append(.init(path: metaURL, detail: error.localizedDescription))
                }
            }
        } else {
            complete = false
        }

        if let playlists = try? fileManager.contentsOfDirectory(
            at: paths.playlistsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in playlists where url.pathExtension == "json" {
                do {
                    let sidecar = try decoder.decode(PlaylistSidecar.self, from: Data(contentsOf: url))
                    snapshot.playlistIDs.insert(sidecar.id)
                } catch {
                    snapshot.issues.append(.init(path: url, detail: error.localizedDescription))
                }
            }
        } else {
            complete = false
        }

        if let sources = try? fileManager.contentsOfDirectory(
            at: paths.sourcesRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for folder in sources {
                guard let sourceID = UUID(uuidString: folder.lastPathComponent) else { continue }
                let descriptorURL = paths.sourceDescriptorURL(for: sourceID)
                do {
                    let descriptor = try decoder.decode(
                        ReferencedSourceDescriptor.self,
                        from: Data(contentsOf: descriptorURL)
                    )
                    guard descriptor.id == sourceID else {
                        throw ReferencedSourceStoreError.identifierMismatch(
                            expected: sourceID,
                            actual: descriptor.id
                        )
                    }
                    snapshot.sourceIDs.insert(sourceID)
                } catch {
                    snapshot.sourceIssues.append(.init(path: descriptorURL, detail: error.localizedDescription))
                }
            }
        } else {
            complete = false
        }

        if fileManager.fileExists(atPath: paths.ncmConversionsURL.path) {
            do {
                let journal = try decoder.decode(
                    NCMConversionJournal.self,
                    from: Data(contentsOf: paths.ncmConversionsURL)
                )
                guard journal.schemaVersion == NCMConversionJournal.currentSchemaVersion else {
                    throw NCMConversionRegistryError.unsupportedSchema(journal.schemaVersion)
                }
                for record in journal.records where record.state == .committed {
                    snapshot.ncmRecords[record.id] = NCMProjectionRecord(
                        operationID: record.id,
                        trackID: record.trackID,
                        outputPath: record.expectedOutputPath,
                        outputExists: fileManager.fileExists(atPath: record.expectedOutputPath)
                    )
                }
            } catch {
                snapshot.ncmJournalIsValid = false
                snapshot.ncmIssues.append(
                    .init(path: paths.ncmConversionsURL, detail: error.localizedDescription)
                )
            }
        }

        snapshot.playlistMembershipIsValid = decodeIfPresent(
            ReferencedPlaylistMembershipFile.self,
            from: paths.playlistMembershipsURL,
            decoder: decoder,
            fileManager: fileManager
        )
        snapshot.settingsIsValid = decodeIfPresent(
            LibraryScopedSettings.self,
            from: paths.librarySettingsURL,
            decoder: decoder,
            fileManager: fileManager
        )
        snapshot.isComplete = complete
        return snapshot
    }

    /// A missing optional projection is valid: there is nothing to compare.
    private static func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        decoder: JSONDecoder,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            _ = try decoder.decode(type, from: Data(contentsOf: url))
            return true
        } catch {
            return false
        }
    }
}

nonisolated enum LibraryMutationVerifier {
    /// Adjudicates one intent against its durable projection. A `true` verdict
    /// is only returned when the verifier can name the projection it checked.
    static func verify(
        _ intent: LibraryMutationIntent,
        snapshot: LibraryMutationProjectionSnapshot
    ) -> LibraryMutationVerification {
        let targetIDs = intent.targetIDs.compactMap(UUID.init(uuidString:))
        let recordedTargetCount = intent.targetIDs.count

        func unresolved(_ summary: String) -> LibraryMutationVerification {
            .init(intentID: intent.id, isResolved: false, summary: summary)
        }
        func resolved(_ summary: String) -> LibraryMutationVerification {
            .init(intentID: intent.id, isResolved: true, summary: summary)
        }

        func trackIsProjected(_ id: UUID) -> Bool {
            snapshot.trackIDs.contains(id) && snapshot.managedAudioExists[id] == true
        }

        /// An NCM association recorded on the sidecar is part of the import
        /// transaction. Its registry entry must exist, point back at this
        /// track, and still have its committed output.
        func ncmIsProjected(_ id: UUID) -> Bool {
            guard let association = snapshot.ncmAssociations[id] else { return true }
            guard snapshot.ncmJournalIsValid,
                  let record = snapshot.ncmRecords[association.operationID],
                  record.trackID == id,
                  URL(fileURLWithPath: record.outputPath).standardizedFileURL.path
                    == URL(fileURLWithPath: association.outputPath).standardizedFileURL.path,
                  record.outputExists else { return false }
            return true
        }

        guard recordedTargetCount == targetIDs.count || recordedTargetCount == 0 else {
            return unresolved("some target identifiers are not projection identifiers")
        }

        switch intent.kind {
        case .importCommit:
            guard !targetIDs.isEmpty else {
                return unresolved("no target track identifiers were recorded")
            }
            let present = targetIDs.filter { trackIsProjected($0) && ncmIsProjected($0) }
            if present.count == targetIDs.count {
                return resolved("verified \(present.count) imported track(s), their audio and NCM associations")
            }
            if present.isEmpty, !targetIDs.contains(where: { snapshot.trackFolderIDs.contains($0) }) {
                // The importer publishes audio and a sidecar together. No
                // folder at all proves this transaction never reached disk.
                return resolved("no target track was published")
            }
            let tracksComplete = targetIDs.filter(trackIsProjected)
            let missingNCM = targetIDs.filter {
                snapshot.ncmAssociations[$0] != nil && !ncmIsProjected($0)
            }
            if tracksComplete.count == targetIDs.count, !missingNCM.isEmpty {
                return unresolved(
                    "NCM association is not committed for: "
                        + missingNCM.prefix(5).map(\.uuidString).joined(separator: ",")
                )
            }
            let absent = targetIDs.filter { !trackIsProjected($0) }
            return unresolved(
                "\(tracksComplete.count) of \(targetIDs.count) target track(s) are complete; missing: "
                    + absent.prefix(5).map(\.uuidString).joined(separator: ",")
            )

        case .enrichmentCommit:
            guard !targetIDs.isEmpty else {
                return unresolved("no target track identifiers were recorded")
            }
            let present = targetIDs.filter { snapshot.trackIDs.contains($0) }
            guard present.count == targetIDs.count else {
                return unresolved(
                    "\(present.count) of \(targetIDs.count) target sidecar(s) load; missing: "
                        + targetIDs.filter { !snapshot.trackIDs.contains($0) }
                            .prefix(5).map(\.uuidString).joined(separator: ",")
                )
            }
            return resolved("verified \(present.count) metadata sidecar(s)")

        case .settingsUpdate:
            guard snapshot.settingsIsValid else {
                return unresolved("library settings cannot be decoded")
            }
            return resolved("library settings decode")

        case .sourceReconcileCommit:
            guard snapshot.sourceIssues.isEmpty, snapshot.playlistMembershipIsValid else {
                return unresolved("a source descriptor or the playlist membership file is invalid")
            }
            return resolved("source descriptors and playlist membership decode")

        case .userLibraryMutation:
            guard !targetIDs.isEmpty else {
                return verifyStructure(snapshot, intentID: intent.id)
            }
            let missing = targetIDs.filter { id in
                !(snapshot.trackIDs.contains(id) || snapshot.playlistIDs.contains(id) || snapshot.sourceIDs.contains(id))
            }
            guard missing.isEmpty else {
                return unresolved(
                    "target projection missing for: "
                        + missing.prefix(5).map(\.uuidString).joined(separator: ",")
                )
            }
            return resolved("verified \(targetIDs.count) mutated projection(s)")

        case .maintenance, .automation:
            return verifyStructure(snapshot, intentID: intent.id)
        }
    }

    private static func verifyStructure(
        _ snapshot: LibraryMutationProjectionSnapshot,
        intentID: UUID
    ) -> LibraryMutationVerification {
        guard snapshot.isComplete else {
            return .init(intentID: intentID, isResolved: false, summary: "library directories could not be enumerated")
        }
        guard snapshot.issues.isEmpty, snapshot.sourceIssues.isEmpty,
              snapshot.ncmJournalIsValid,
              snapshot.playlistMembershipIsValid, snapshot.settingsIsValid else {
            return .init(
                intentID: intentID,
                isResolved: false,
                summary: "structural verification found invalid record(s): "
                    + (snapshot.issues + snapshot.sourceIssues + snapshot.ncmIssues)
                        .prefix(3).map(\.path.lastPathComponent).joined(separator: ",")
            )
        }
        return .init(intentID: intentID, isResolved: true, summary: "structural verification passed")
    }
}
