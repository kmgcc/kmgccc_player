import Darwin
import Foundation
import Testing
@testable import PlayerAutomationIPC
@testable import PlayerAutomationProtocol

@Test
func metadataCandidateQualityIsProviderNeutralAndBackwardCompatible() throws {
    let exact = AutomationMetadataQualityEvaluator.score(
        queryTitle: "Déjà Vu",
        queryArtist: "Björk",
        queryAlbum: "Homogenic",
        queryDurationSeconds: 217,
        candidateTitle: "Deja-Vu",
        candidateArtist: "Bjork",
        candidateAlbum: "Homogenic",
        candidateDurationSeconds: 219
    )
    #expect(exact == 1)

    let weaker = AutomationMetadataQualityEvaluator.score(
        queryTitle: "Déjà Vu",
        queryArtist: "Björk",
        queryAlbum: "Homogenic",
        queryDurationSeconds: 217,
        candidateTitle: "Deja",
        candidateArtist: "Other Artist",
        candidateAlbum: nil,
        candidateDurationSeconds: 250
    )
    #expect(weaker != nil && weaker! < exact!)

    let oldCandidate = try AutomationWireCoding.decoder().decode(
        AutomationMetadataCandidate.self,
        from: Data(
            """
            {"provider":"QQMusic","title":"T","artist":"A","album":"B",
             "durationSeconds":180,"confidence":0.9,"imageURL":null}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(oldCandidate.matchQuality == nil)

    let oldSearchResult = try AutomationWireCoding.decoder().decode(
        AutomationMetadataSearchResult.self,
        from: Data(
            """
            {"trackID":"\(UUID().uuidString)","queryTitle":"T","queryArtist":"A",
             "queryAlbum":"B","candidates":[],"revision":"v1","message":"old"}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(oldSearchResult.providerWarnings == nil)
}

@Test
func artworkQualityIsProviderNeutralAndKeepsProviderConfidenceSeparate() throws {
    let exact = AutomationArtworkQualityEvaluator.score(
        queryTitle: "Blue Train",
        queryArtist: "John Coltrane",
        queryAlbum: "Blue Train",
        candidateTitle: "Blue Train",
        candidateArtist: "John Coltrane",
        candidateAlbum: "Blue Train",
        width: 1200,
        height: 1200
    )
    let mismatched = AutomationArtworkQualityEvaluator.score(
        queryTitle: "Blue Train",
        queryArtist: "John Coltrane",
        queryAlbum: "Blue Train",
        candidateTitle: "Red Train",
        candidateArtist: "Another Artist",
        candidateAlbum: "Different Album",
        width: 500,
        height: 250
    )
    #expect(exact > mismatched)

    let oldCandidate = try AutomationWireCoding.decoder().decode(
        AutomationArtworkCandidate.self,
        from: Data("""
        {"source":"NetEase","imageBase64":"","byteCount":0,
         "width":0,"height":0,"resolution":0,"confidence":0.7}
        """.utf8)
    )
    #expect(oldCandidate.matchQuality == nil)
}

@Test
func metadataDocumentAndImportResultRoundTrip() throws {
    let sourceTrackID = UUID()
    let targetTrackID = UUID()
    let sourceLibraryID = UUID()
    let fields: [String: AutomationJSONValue] = [
        "title": .string("Track title"),
        "artist": .string("Artist"),
        "albumArtist": .null,
        "genreTags": .array([.string("ambient"), .string("electronic")]),
        "lyricsTimeOffsetMs": .number(-125)
    ]
    let document = AutomationMetadataDocument(
        sourceLibraryID: sourceLibraryID,
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        revision: "v1-library",
        offset: 100,
        limit: 1,
        total: 101,
        nextOffset: 101,
        tracks: [AutomationMetadataDocumentTrack(
            id: sourceTrackID,
            revision: "v1-track",
            title: "Track title",
            artist: "Artist",
            album: "Album",
            duration: 184.5,
            fields: fields
        )]
    )
    let encodedDocument = try AutomationWireCoding.encoder().encode(document)
    let decodedDocument = try AutomationWireCoding.decoder().decode(
        AutomationMetadataDocument.self,
        from: encodedDocument
    )
    #expect(decodedDocument == document)
    #expect(decodedDocument.schemaVersion == 1)
    #expect(decodedDocument.nextOffset == 101)
    #expect(decodedDocument.tracks[0].fields["albumArtist"] == .null)

    let result = AutomationMetadataImportResult(
        libraryID: UUID(),
        sourceLibraryID: sourceLibraryID,
        dryRun: true,
        applied: false,
        items: [AutomationMetadataImportItem(
            sourceTrackID: sourceTrackID,
            targetTrackID: targetTrackID,
            status: "ready",
            fields: ["title", "genreTags"],
            message: "Preview only"
        )],
        revision: "v1-target",
        message: "Preview only"
    )
    let encodedResult = try AutomationWireCoding.encoder().encode(result)
    let decodedResult = try AutomationWireCoding.decoder().decode(
        AutomationMetadataImportResult.self,
        from: encodedResult
    )
    #expect(decodedResult == result)
}

@Test
func wireRoundTripPreservesRequestAndUnknownJSONFields() throws {
    let requestID = UUID()
    let request = AutomationRequest(
        method: AutomationMethod.systemInfo,
        params: .object([
            "futureField": .string("ignored by the App until supported"),
            "limit": .number(10)
        ]),
        context: AutomationRequestContext(
            libraryID: UUID(),
            deadline: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        requestID: requestID
    )
    let data = try AutomationWireCoding.encoder().encode(request)
    let decoded = try AutomationWireCoding.decoder().decode(AutomationRequest.self, from: data)
    #expect(decoded == request)
}

@Test
func selectionSummaryDecodesOlderSnapshotsWithoutDynamicFlag() throws {
    let summary = AutomationSelectionSummary(
        id: UUID(),
        name: "dynamic",
        trackCount: 2,
        revision: "selection-v1",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        isDynamic: true
    )
    let encoded = try AutomationWireCoding.encoder().encode(summary)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["isDynamic"] as? Bool == true)
    object.removeValue(forKey: "isDynamic")
    let legacy = try AutomationWireCoding.decoder().decode(
        AutomationSelectionSummary.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(!legacy.isDynamic)
}

@Test
func frameDecoderHandlesPartialAndMultipleFrames() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 128)
    let first = try codec.encode(Data("first".utf8))
    let second = try codec.encode(Data("second".utf8))
    var buffer = Data()
    var decoded: [Data] = []
    for byte in first + second {
        buffer.append(byte)
        while let payload = try codec.decodeNext(from: &buffer) {
            decoded.append(payload)
        }
    }
    #expect(decoded == [Data("first".utf8), Data("second".utf8)])
    #expect(buffer.isEmpty)
}

@Test
func frameCodecRejectsOversizeAndNonFiniteNumbers() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 3)
    #expect(throws: AutomationIPCError.frameTooLarge(4)) {
        _ = try codec.encode(Data(repeating: 0x01, count: 4))
    }

    #expect(throws: AutomationCodingError.nonFiniteNumber) {
        _ = try AutomationWireCoding.encoder().encode(AutomationJSONValue.number(.infinity))
    }
}

@Test
func responseFactoriesKeepRequestID() {
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let success = AutomationResponse.success(for: request, result: .null)
    let failure = AutomationResponse.failure(
        for: request,
        error: AutomationError(code: .methodNotFound, message: "missing")
    )
    #expect(success.requestID == request.requestID)
    #expect(failure.requestID == request.requestID)
}

@Test
func automationToolCatalogIsStableAndMarksMutationsExplicitly() throws {
    let names = AutomationToolCatalog.all.map(\.name)
    #expect(names == names.sorted())
    #expect(Set(names).count == names.count)
    #expect(names.contains(AutomationMethod.libraryTracks))
    #expect(names.contains(AutomationMethod.playlistAddTracks))
    #expect(names.contains(AutomationMethod.sourceList))
    #expect(names.contains(AutomationMethod.sourceConfigExport))
    #expect(names.contains(AutomationMethod.sourceConfigImport))
    #expect(names.contains(AutomationMethod.sourceRefresh))
    #expect(names.contains(AutomationMethod.filesInspect))
    #expect(names.contains(AutomationMethod.filesRename))
    #expect(names.contains(AutomationMethod.filesMove))
    #expect(names.contains(AutomationMethod.filesDelete))
    #expect(names.contains(AutomationMethod.libraryCreate))
    #expect(names.contains(AutomationMethod.libraryOpen))
    #expect(names.contains(AutomationMethod.librarySwitch))
    #expect(names.contains(AutomationMethod.libraryRename))
    #expect(names.contains(AutomationMethod.libraryRelocate))
    #expect(names.contains(AutomationMethod.libraryRemove))
    #expect(names.contains(AutomationMethod.artworkSearch))
    #expect(names.contains(AutomationMethod.artworkGet))
    #expect(names.contains(AutomationMethod.artworkApply))
    #expect(names.contains(AutomationMethod.artworkApplyCandidate))
    #expect(names.contains(AutomationMethod.libraryReport))
    #expect(names.contains(AutomationMethod.libraryBundleExport))
    #expect(names.contains(AutomationMethod.librarySelectionList))
    #expect(names.contains(AutomationMethod.librarySelectionCreate))
    #expect(names.contains(AutomationMethod.librarySelectionGet))
    #expect(names.contains(AutomationMethod.librarySelectionDelete))
    #expect(names.contains(AutomationMethod.playlistAddSelection))
    #expect(names.contains(AutomationMethod.metadataExport))
    #expect(names.contains(AutomationMethod.metadataImport))
    #expect(names.contains(AutomationMethod.metadataEmbeddedGet))
    #expect(names.contains(AutomationMethod.metadataEmbeddedPatch))

    let sourceConfigExport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.sourceConfigExport)
    )
    #expect(sourceConfigExport.readOnly)
    #expect(sourceConfigExport.scopes == [.sourceRead])
    let sourceConfigImport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.sourceConfigImport)
    )
    #expect(!sourceConfigImport.readOnly)
    #expect(sourceConfigImport.requiresConfirmation)
    #expect(sourceConfigImport.supportsDryRun)
    #expect(sourceConfigImport.scopes == [.sourceRead, .sourceWrite].sorted { $0.rawValue < $1.rawValue })
    guard case .object(let sourceConfigSchema) = sourceConfigImport.inputSchema,
          case .object(let sourceConfigProperties) = sourceConfigSchema["properties"] else {
        Issue.record("source.config.import must expose its versioned document inputs")
        return
    }
    #expect(sourceConfigSchema["required"] == .array([.string("document")]))
    #expect(sourceConfigProperties["sourceIDMap"] != nil)
    #expect(sourceConfigProperties["expectedRevision"] != nil)

    let metadataExport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.metadataExport)
    )
    #expect(metadataExport.readOnly)
    #expect(metadataExport.scopes == [.libraryRead, .metadataRead])
    let metadataImport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.metadataImport)
    )
    #expect(!metadataImport.readOnly)
    #expect(metadataImport.requiresConfirmation)
    #expect(metadataImport.supportsDryRun)
    #expect(metadataImport.scopes == [.libraryRead, .metadataWrite])
    guard case .object(let metadataImportSchema) = metadataImport.inputSchema,
          case .object(let metadataImportProperties) = metadataImportSchema["properties"] else {
        Issue.record("metadata.import must expose its versioned document and safety controls")
        return
    }
    #expect(metadataImportSchema["required"] == .array([.string("document")]))
    #expect(metadataImportProperties["trackIDMap"] != nil)
    #expect(metadataImportProperties["expectedRevision"] != nil)

    let libraryBundleExport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryBundleExport)
    )
    #expect(!libraryBundleExport.readOnly)
    #expect(libraryBundleExport.requiresConfirmation)
    #expect(libraryBundleExport.supportsDryRun)
    #expect(libraryBundleExport.supportsJobs)
    #expect(libraryBundleExport.supportsTasks)
    #expect(libraryBundleExport.scopes == [.artworkRead, .filesRead, .libraryRead, .lyricsRead, .metadataRead, .playlistRead])

    let embeddedRead = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.metadataEmbeddedGet)
    )
    #expect(embeddedRead.readOnly)
    #expect(embeddedRead.scopes == [.filesRead, .libraryRead, .metadataRead])
    let embeddedPatch = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.metadataEmbeddedPatch)
    )
    #expect(!embeddedPatch.readOnly)
    #expect(embeddedPatch.requiresConfirmation)
    #expect(embeddedPatch.supportsDryRun)
    #expect(embeddedPatch.supportsJobs)
    #expect(embeddedPatch.supportsTasks)
    #expect(embeddedPatch.scopes == [.filesRead, .filesWrite, .libraryRead, .metadataWrite])

    let metadataGet = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.metadataGet)
    )
    guard case .object(let metadataGetSchema) = metadataGet.inputSchema,
          case .object(let metadataGetProperties) = metadataGetSchema["properties"] else {
        Issue.record("metadata.get must expose entity discovery properties")
        return
    }
    #expect(metadataGetProperties["entityType"] != nil)
    #expect(metadataGetProperties["query"] != nil)
    #expect(metadataGetProperties["limit"] != nil)
    #expect(metadataGetProperties["offset"] != nil)

    let readOnly = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryTracks)
    )
    #expect(readOnly.readOnly)
    #expect(!readOnly.requiresConfirmation)

    let mutation = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.playlistAddTracks)
    )
    #expect(!mutation.readOnly)
    #expect(!mutation.requiresConfirmation)
    guard case .object(let schema) = mutation.inputSchema else {
        Issue.record("mutation input schema must be an object")
        return
    }
    guard case .array(let required) = schema["required"] else {
        Issue.record("mutation schema must declare required IDs")
        return
    }
    #expect(required.contains(.string("playlistID")))
    #expect(required.contains(.string("trackIDs")))

    let sourceRefresh = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.sourceRefresh)
    )
    #expect(!sourceRefresh.requiresConfirmation)
    #expect(sourceRefresh.supportsJobs)
    #expect(sourceRefresh.supportsTasks)
    let libraryImport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryImport)
    )
    #expect(libraryImport.supportsJobs)
    #expect(libraryImport.supportsTasks)

    let selectionCreate = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.librarySelectionCreate)
    )
    #expect(!selectionCreate.readOnly)
    #expect(selectionCreate.supportsDryRun)
    #expect(selectionCreate.scopes.contains(.selectionWrite))
    guard case .object(let selectionSchema) = selectionCreate.inputSchema,
          case .array(let selectionAlternatives) = selectionSchema["oneOf"],
          case .object(let selectionProperties) = selectionSchema["properties"] else {
        Issue.record("selection.create must accept either Track IDs or a structured filter")
        return
    }
    #expect(selectionAlternatives.count == 2)
    #expect(selectionProperties["trackIDs"] != nil)
    #expect(selectionProperties["filter"] != nil)
    let addSelection = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.playlistAddSelection)
    )
    #expect(!addSelection.readOnly)
    #expect(addSelection.supportsDryRun)
    #expect(addSelection.scopes.contains(.selectionWrite))
    #expect(addSelection.scopes.contains(.playlistWrite))
    let libraryReport = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryReport)
    )
    #expect(libraryReport.readOnly)
    #expect(libraryReport.scopes == [.libraryRead])
    guard case .object(let reportSchema) = libraryReport.inputSchema,
          case .object(let reportProperties) = reportSchema["properties"] else {
        Issue.record("library.report must expose paging and optional path properties")
        return
    }
    #expect(reportProperties["limit"] != nil)
    #expect(reportProperties["offset"] != nil)
    #expect(reportProperties["playlistLimit"] != nil)
    #expect(reportProperties["playlistOffset"] != nil)
    #expect(reportProperties["expectedRevision"] != nil)
    #expect(reportProperties["includeFilePaths"] != nil)
    guard case .object(let reportLimit) = reportProperties["limit"] else {
        Issue.record("library.report limit must be bounded")
        return
    }
    #expect(reportLimit["maximum"] == .number(100))

    let playlistAdd = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.playlistAddTracks)
    )
    guard case .object(let playlistSchema) = playlistAdd.inputSchema,
          case .object(let playlistProperties) = playlistSchema["properties"],
          case .object(let trackIDsSchema) = playlistProperties["trackIDs"] else {
        Issue.record("playlist.addTracks must expose its bounded Track ID input")
        return
    }
    #expect(trackIDsSchema["maxItems"] == .number(10_000))

    let filesInspect = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesInspect)
    )
    #expect(filesInspect.readOnly)
    #expect(!filesInspect.requiresConfirmation)

    let filesRename = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesRename)
    )
    #expect(!filesRename.readOnly)
    #expect(filesRename.risk == .medium)
    #expect(filesRename.supportsDryRun)
    #expect(filesRename.supportsJobs)

    let filesMove = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesMove)
    )
    #expect(!filesMove.readOnly)
    #expect(filesMove.risk == .medium)
    #expect(filesMove.supportsDryRun)
    #expect(filesMove.supportsJobs)

    let filesDelete = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.filesDelete)
    )
    #expect(!filesDelete.readOnly)
    #expect(filesDelete.risk == .high)
    #expect(filesDelete.requiresConfirmation)
    #expect(filesDelete.supportsDryRun)
    #expect(filesDelete.supportsJobs)

    let libraryCreate = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryCreate)
    )
    #expect(!libraryCreate.readOnly)
    #expect(libraryCreate.requiresConfirmation)
    #expect(libraryCreate.scopes == [.libraryManage])
    #expect(libraryCreate.supportsDryRun)
    guard case .object(let createSchema) = libraryCreate.inputSchema,
          case .array(let createRequired) = createSchema["required"] else {
        Issue.record("library.create must declare its required inputs")
        return
    }
    #expect(createRequired.contains(.string("mode")))
    #expect(createRequired.contains(.string("displayName")))

    for method in [
        AutomationMethod.libraryOpen,
        AutomationMethod.librarySwitch,
        AutomationMethod.libraryRename,
        AutomationMethod.libraryRelocate,
        AutomationMethod.libraryRemove
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        #expect(!descriptor.readOnly)
        #expect(descriptor.supportsDryRun)
        #expect(!descriptor.scopes.isEmpty)
    }
    let libraryRemove = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.libraryRemove)
    )
    #expect(libraryRemove.requiresConfirmation)
    #expect(libraryRemove.scopes == [.libraryDelete])

    let artworkGet = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkGet)
    )
    #expect(artworkGet.readOnly)
    #expect(artworkGet.scopes == [.artworkRead, .libraryRead].sorted { $0.rawValue < $1.rawValue })

    let artworkSearch = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkSearch)
    )
    #expect(artworkSearch.readOnly)
    #expect(!artworkSearch.requiresConfirmation)
    #expect(artworkSearch.scopes == [.artworkRead, .libraryRead].sorted { $0.rawValue < $1.rawValue })
    guard case .object(let artworkSearchSchema) = artworkSearch.inputSchema,
          case .object(let artworkSearchProperties) = artworkSearchSchema["properties"] else {
        Issue.record("artwork.search must expose target properties")
        return
    }
    #expect(artworkSearchSchema["required"] == nil)
    #expect(artworkSearchProperties["trackID"] != nil)
    #expect(artworkSearchProperties["artistID"] != nil)
    #expect(artworkSearchProperties["albumKey"] != nil)
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.artworkSearch,
            params: .object([
                "trackID": .string(UUID().uuidString),
                "limit": .number(5),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let artworkCandidate = AutomationArtworkCandidate(
        candidateID: "art-v1-test-handle",
        source: "qqmusic",
        sourceItemID: "album-mid",
        imageBase64: "aW1hZ2U=",
        imageMIMEType: "image/jpeg",
        byteCount: 5,
        originalByteCount: 120_000,
        width: 640,
        height: 640,
        resolution: 640,
        confidence: 0.91,
        matchedTitle: "Example",
        matchedArtist: "Artist",
        matchedAlbum: "Album",
        imageURL: "https://example.invalid/cover.jpg"
    )
    let artworkResult = AutomationArtworkSearchResult(
        trackID: UUID(),
        queryTitle: "Example",
        queryArtist: "Artist",
        queryAlbum: "Album",
        candidates: [artworkCandidate],
        message: "ok"
    )
    let artworkData = try AutomationWireCoding.encoder().encode(artworkResult)
    let decodedArtwork = try AutomationWireCoding.decoder().decode(
        AutomationArtworkSearchResult.self,
        from: artworkData
    )
    #expect(decodedArtwork == artworkResult)
    #expect(decodedArtwork.candidates.first?.originalByteCount == 120_000)
    #expect(decodedArtwork.candidates.first?.id == "art-v1-test-handle")

    let artworkApply = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkApply)
    )
    #expect(!artworkApply.readOnly)
    #expect(artworkApply.requiresConfirmation)
    #expect(artworkApply.supportsDryRun)
    #expect(artworkApply.risk == .medium)
    guard case .object(let artworkSchema) = artworkApply.inputSchema,
          case .object(let artworkProperties) = artworkSchema["properties"] else {
        Issue.record("artwork.apply must expose target properties")
        return
    }
    #expect(artworkSchema["required"] == nil)
    #expect(artworkProperties["trackIDs"] != nil)
    #expect(artworkProperties["playlistID"] != nil)
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.artworkApply,
            params: .object([
                "trackIDs": .array([]),
                "imageBase64": .string("..."),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let artworkApplyCandidate = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.artworkApplyCandidate)
    )
    #expect(!artworkApplyCandidate.readOnly)
    #expect(artworkApplyCandidate.supportsDryRun)
    #expect(artworkApplyCandidate.scopes == [.artworkWrite, .libraryRead].sorted { $0.rawValue < $1.rawValue })
    guard case .object(let candidateSchema) = artworkApplyCandidate.inputSchema,
          case .object(let candidateProperties) = candidateSchema["properties"] else {
        Issue.record("artwork.applyCandidate must expose its candidate and revision inputs")
        return
    }
    #expect(candidateSchema["required"] == .array([.string("candidateID")]))
    #expect(candidateProperties["expectedRevision"] != nil)
    #expect(candidateProperties["dryRun"] != nil)
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.artworkApplyCandidate,
            params: .object([
                "candidateID": .string("art-v1-test-handle"),
                "dryRun": .boolean(true),
                "unexpected": .boolean(false)
            ])
        ) == ["unexpected"]
    )

    for method in [
        AutomationMethod.sourceSetExcludedPath,
        AutomationMethod.sourceSetMonitorPolicy,
        AutomationMethod.settingsGet,
        AutomationMethod.settingsPatch,
        AutomationMethod.storageInspect,
        AutomationMethod.storageValidate,
        AutomationMethod.storageRepair
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
        #expect(!descriptor.scopes.isEmpty || method == AutomationMethod.settingsGet)
    }
}

@Test
func libraryBundleExportResultRoundTripsJobAndPreview() throws {
    let job = AutomationJobSummary(
        id: UUID(),
        kind: "libraryBundleExport",
        libraryID: UUID(),
        state: .queued,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        retryable: false
    )
    let result = AutomationLibraryBundleExportResult(
        libraryID: UUID(),
        dryRun: false,
        applied: true,
        confirmed: true,
        trackCount: 50,
        estimatedBytes: 1_024,
        outputDirectory: "/Users/test/Exports",
        job: job,
        message: "started"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationLibraryBundleExportResult.self,
        from: data
    )
    #expect(decoded == result)
}

@Test
func embeddedTagResultsRoundTripWithPathSafeFileSummariesAndJob() throws {
    let job = AutomationJobSummary(
        id: UUID(),
        kind: "embeddedTagWrite",
        libraryID: UUID(),
        state: .running,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        startedAt: nil,
        finishedAt: nil,
        checkpoint: "writing embedded tags",
        completedCount: 0,
        totalCount: 2,
        currentPhase: "writing embedded tags",
        failures: [],
        failedItemIDs: [],
        retryable: false,
        result: nil
    )
    let value = AutomationEmbeddedTagsResult(
        dryRun: false,
        applied: false,
        libraryRevision: "library-r1",
        tracks: [AutomationEmbeddedTagTrack(
            id: UUID(),
            fileName: "song.mp3",
            format: "mp3",
            supportedForWrite: true,
            trackRevision: "track-r1",
            values: ["title": "Song"],
            status: "ready"
        )],
        job: job,
        message: "Job started"
    )
    let data = try AutomationWireCoding.encoder().encode(value)
    let decoded = try AutomationWireCoding.decoder().decode(AutomationEmbeddedTagsResult.self, from: data)
    #expect(decoded == value)
    #expect(!String(decoding: data, as: UTF8.self).contains("/Users/"))
}

@Test
func artworkAutomationResultRoundTripsAndMetadataFieldsDecodeDefaults() throws {
    let trackID = UUID()
    let artwork = AutomationArtworkMutationResult(
        applied: true,
        dryRun: false,
        confirmed: true,
        input: "imageBase64",
        updatedTrackIDs: [trackID],
        message: "updated"
    )
    let data = try AutomationWireCoding.encoder().encode(artwork)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationArtworkMutationResult.self,
        from: data
    )
    #expect(decoded == artwork)

    let summary = try AutomationWireCoding.decoder().decode(
        AutomationTrackSummary.self,
        from: Data(
            """
            {"id":"\(trackID.uuidString)","title":"T","artist":"A","album":"B",
             "duration":1,"availability":"available","addedAt":"2026-01-01T00:00:00Z"}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(summary.artistCredits.isEmpty)
    #expect(summary.userDescription.isEmpty)
    #expect(summary.lyricsTimeOffsetMs == 0)
    #expect(summary.artworkFileName == nil)
    #expect(summary.embeddedMetadataSnapshot == nil)
    #expect(summary.preferenceStats == nil)

    let embeddedSnapshot = AutomationEmbeddedMetadataSnapshot(
        title: "Original file title",
        artistDisplay: "Original file artist",
        album: "Original file album",
        releaseYear: 2024,
        musicBrainzReleaseID: UUID().uuidString,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let summaryWithEmbeddedSnapshot = AutomationTrackSummary(
        id: trackID,
        title: "T",
        artist: "A",
        album: "B",
        duration: 1,
        availability: "available",
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        importedAt: nil,
        embeddedMetadataSnapshot: embeddedSnapshot
    )
    let snapshotData = try AutomationWireCoding.encoder().encode(summaryWithEmbeddedSnapshot)
    let decodedSnapshotSummary = try AutomationWireCoding.decoder().decode(
        AutomationTrackSummary.self,
        from: snapshotData
    )
    #expect(decodedSnapshotSummary.embeddedMetadataSnapshot == embeddedSnapshot)

    let preferenceStats = AutomationTrackPreferenceSummary(
        playCount: 12,
        completePlayCount: 8,
        skipCount: 3,
        quickSkipCount: 1,
        totalPlayedSeconds: 2_880,
        lastPlayedAt: Date(timeIntervalSince1970: 1_750_000_000),
        lastCompletedAt: nil,
        lastSkippedAt: Date(timeIntervalSince1970: 1_740_000_000),
        likeState: "liked",
        preferenceScore: 0.82,
        effectiveWeight: 1.2
    )
    let summaryWithPreferenceStats = AutomationTrackSummary(
        id: trackID,
        title: "T",
        artist: "A",
        album: "B",
        duration: 1,
        availability: "available",
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        importedAt: nil,
        preferenceStats: preferenceStats
    )
    let preferenceData = try AutomationWireCoding.encoder().encode(summaryWithPreferenceStats)
    let decodedPreferenceSummary = try AutomationWireCoding.decoder().decode(
        AutomationTrackSummary.self,
        from: preferenceData
    )
    #expect(decodedPreferenceSummary.preferenceStats == preferenceStats)

    let oldArtwork = try AutomationWireCoding.decoder().decode(
        AutomationArtworkMutationResult.self,
        from: Data(
            """
            {"applied":true,"dryRun":false,"confirmed":false,"input":"imageBase64",
             "updatedTrackIDs":["\(trackID.uuidString)"],"skippedTrackIDs":[],
             "conflictedTrackIDs":[],"message":"updated"}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(oldArtwork.updatedTrackIDs == [trackID])
    #expect(oldArtwork.updatedArtistIDs.isEmpty)

    let oldPlaylist = try AutomationWireCoding.decoder().decode(
        AutomationPlaylistSummary.self,
        from: Data(
            """
            {"id":"\(UUID().uuidString)","name":"Old","description":"",
             "createdAt":"2026-01-01T00:00:00Z","trackCount":0,"totalDuration":0,
             "revision":"v1-old"}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    )
    #expect(oldPlaylist.artworkSource == "none")

    let metadata = AutomationMetadataGetResult(
        total: 4,
        offset: 2,
        limit: 2,
        nextOffset: nil,
        revision: "v1-entities"
    )
    let metadataData = try AutomationWireCoding.encoder().encode(metadata)
    let decodedMetadata = try AutomationWireCoding.decoder().decode(
        AutomationMetadataGetResult.self,
        from: metadataData
    )
    #expect(decodedMetadata.offset == 2)
    #expect(decodedMetadata.limit == 2)
    #expect(decodedMetadata.nextOffset == nil)
}

@Test
func libraryLifecycleContractRoundTripsAndRejectsUnknownTopLevelParameters() throws {
    let libraryID = UUID()
    let result = AutomationLibraryLifecycleResult(
        operation: AutomationMethod.librarySwitch,
        applied: true,
        dryRun: false,
        confirmed: true,
        libraryID: libraryID,
        library: AutomationLibrarySummary(
            id: libraryID,
            displayName: "Agent Test",
            mode: .referenced,
            isActive: true
        ),
        activeLibraryID: libraryID,
        path: "/tmp/Agent Test/kmgccc_player Library",
        unavailableSourceIDs: [UUID()],
        message: "switched"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationLibraryLifecycleResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.libraryCreate,
            params: .object([
                "mode": .string("referenced"),
                "displayName": .string("Agent Test"),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )
}

@Test
func strictToolParametersRejectUnknownTopLevelKeysWithoutClosingExtensionObjects() throws {
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.filesDelete,
            params: .object([
                "trackIDs": .array([]),
                "dryRun": .boolean(true),
                "dryrun": .boolean(true)
            ])
        ) == ["dryrun"]
    )
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.systemInfo,
            params: .object(["futureField": .string("not accepted")])
        ) == ["futureField"]
    )
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.metadataPatch,
            params: .object([
                "trackIDs": .array([]),
                "patch": .object(["futureMetadataField": .string("extension")]),
                "dryRun": .boolean(true)
            ])
        ).isEmpty
    )
}

@Test
func newSnapshotAndSourceFieldsRemainBackwardCompatibleWhenDecodingOldResponses() throws {
    let tracks = try AutomationWireCoding.decoder().decode(
        AutomationLibraryTracksResult.self,
        from: Data("{\"tracks\":[],\"total\":0,\"offset\":0,\"limit\":100}".utf8)
    )
    #expect(tracks.revision == "v1-unknown")

    let source = try AutomationWireCoding.decoder().decode(
        AutomationSourceCreateResult.self,
        from: Data("{\"applied\":false}".utf8)
    )
    #expect(source.playlistBindingApplied == false)
    #expect(source.completed)
}

@Test
func lyricsAutomationContractExposesSelectionAndRetrySemantics() throws {
    for method in [
        AutomationMethod.lyricsSearch,
        AutomationMethod.lyricsCandidates,
        AutomationMethod.lyricsCompare,
        AutomationMethod.lyricsApply,
        AutomationMethod.lyricsRefresh,
        AutomationMethod.jobsRetry
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
    }

    let jobsRetry = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.jobsRetry)
    )
    guard case .object(let jobsRetrySchema) = jobsRetry.inputSchema,
          case .object(let jobsRetryProperties)? = jobsRetrySchema["properties"] else {
        Issue.record("jobs.retry must expose its optional import retry inputs")
        return
    }
    #expect(jobsRetryProperties["filePaths"] != nil)
    #expect(AutomationToolCatalog.unknownParameterKeys(
        for: AutomationMethod.jobsRetry,
        params: .object([
            "jobID": .string(UUID().uuidString),
            "filePaths": .array([.string("/Music/retry.mp3")])
        ])
    ).isEmpty)

    let lyricsApply = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.lyricsApply)
    )
    guard case .object(let lyricsApplySchema) = lyricsApply.inputSchema,
          case .array(let lyricsApplyRequired) = lyricsApplySchema["required"] else {
        Issue.record("lyrics.apply must declare a required Track ID")
        return
    }
    #expect(lyricsApplyRequired == [.string("trackID")])
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.lyricsApply,
            params: .object([
                "trackID": .string(UUID().uuidString),
                "ttmlText": .string("<tt></tt>"),
                "cleanMetadata": .boolean(true),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let lyricsClean = try #require(
        AutomationToolCatalog.descriptor(for: AutomationMethod.lyricsClean)
    )
    guard case .object(let lyricsCleanSchema) = lyricsClean.inputSchema,
          case .array(let lyricsCleanRequired) = lyricsCleanSchema["required"] else {
        Issue.record("lyrics.clean must declare a required Track ID")
        return
    }
    #expect(lyricsCleanRequired == [.string("trackID")])
    #expect(
        AutomationToolCatalog.unknownParameterKeys(
            for: AutomationMethod.lyricsClean,
            params: .object([
                "trackID": .string(UUID().uuidString),
                "dryRun": .boolean(false),
                "unexpected": .boolean(true)
            ])
        ) == ["unexpected"]
    )

    let candidate = AutomationLyricsCandidate(
        source: "AMLLDB",
        songID: "raw/example.ttml",
        score: 0.98,
        normalizedScore: 98,
        title: "Example",
        artist: "Artist",
        album: "Album",
        durationMs: 210_000,
        mode: "verbatim",
        extra: ["matchLevel": "exact"]
    )
    let comparison = AutomationLyricsComparisonResult(
        trackID: UUID(),
        currentStatus: "lineSynced",
        currentQuality: 1,
        candidate: candidate,
        candidateQuality: 2,
        shouldReplace: true,
        message: "replace"
    )
    let data = try AutomationWireCoding.encoder().encode(comparison)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationLyricsComparisonResult.self,
        from: data
    )
    #expect(decoded == comparison)
    #expect(decoded.candidate.id == "AMLLDB-raw/example.ttml")

    let customApply = AutomationLyricsApplyResult(
        trackID: UUID(),
        applied: true,
        dryRun: false,
        force: false,
        input: "ttmlText",
        candidate: nil,
        ttmlByteCount: 42,
        currentQuality: 1,
        candidateQuality: 2,
        message: "custom TTML applied"
    )
    let customData = try AutomationWireCoding.encoder().encode(customApply)
    let decodedCustom = try AutomationWireCoding.decoder().decode(
        AutomationLyricsApplyResult.self,
        from: customData
    )
    #expect(decodedCustom == customApply)
    #expect(decodedCustom.input == "ttmlText")
    #expect(decodedCustom.candidate == nil)

    let cleanResult = AutomationLyricsCleanResult(
        trackID: UUID(),
        cleaned: true,
        dryRun: false,
        removedLines: 3,
        message: "Successfully stripped 3 metadata line(s)",
        preview: nil
    )
    let cleanData = try AutomationWireCoding.encoder().encode(cleanResult)
    let decodedClean = try AutomationWireCoding.decoder().decode(
        AutomationLyricsCleanResult.self,
        from: cleanData
    )
    #expect(decodedClean == cleanResult)
    #expect(decodedClean.cleaned == true)
    #expect(decodedClean.removedLines == 3)
}

@Test
func storageAutomationContractExposesSafeFallbackOperations() throws {
    for method in [
        AutomationMethod.storageOrphans,
        AutomationMethod.storageBackup,
        AutomationMethod.storageDiff,
        AutomationMethod.storageReload
    ] {
        let descriptor = try #require(AutomationToolCatalog.descriptor(for: method))
        #expect(!descriptor.scopes.isEmpty)
        guard case .object(let schema) = descriptor.inputSchema,
              case .string("object") = schema["type"] else {
            Issue.record("\(method) must expose an object input schema")
            continue
        }
    }

    let issue = AutomationPlaylistReferenceIssue(
        playlistID: UUID(),
        playlistName: "Broken references",
        missingTrackIDs: [UUID()]
    )
    let result = AutomationStorageOrphansResult(
        libraryID: UUID(),
        playlistReferenceIssues: [issue],
        message: "inspect"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationStorageOrphansResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.orphanReferenceCount == 1)
}

@Test
func diagnosticsResultRemainsBackwardCompatibleWithoutExtendedEvidence() throws {
    let data = Data("""
    {"healthy":true,"libraryID":null,"trackCount":0,"playlistCount":0,"missingTrackCount":0,"unavailableTrackCount":0,"sourceCount":0,"sourceIssues":[],"runningJobCount":0,"checks":{}}
    """.utf8)
    let result = try AutomationWireCoding.decoder().decode(
        AutomationDiagnosticsResult.self,
        from: data
    )
    #expect(result.healthy)
    #expect(result.failedJobCount == 0)
    #expect(result.missingLyricsTrackCount == 0)
    #expect(result.missingArtworkTrackCount == 0)
    #expect(result.incompleteMetadataTrackCount == 0)
    #expect(result.playlistReferenceIssues.isEmpty)
    #expect(result.storageValidation == "notRun")
}

@Test
func automationJobRetryResultKeepsOriginalAndNewJobIDs() throws {
    let originalID = UUID()
    let retryID = UUID()
    let job = AutomationJobSummary(
        id: retryID,
        kind: "enrichment",
        libraryID: UUID(),
        state: .queued,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        retryable: false
    )
    let result = AutomationJobRetryResult(
        originalJobID: originalID,
        accepted: true,
        job: job,
        message: "accepted"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationJobRetryResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.originalJobID == originalID)
    #expect(decoded.job?.id == retryID)
}

@Test
func sourceSummaryRemainsBackwardCompatibleWithoutExclusionField() throws {
    let id = UUID()
    let data = Data("""
    {"id":"\(id.uuidString)","mode":"directory","displayName":"Music","path":"/tmp/Music","status":"available","lastScan":null,"playlistIDs":[]}
    """.utf8)
    let summary = try AutomationWireCoding.decoder().decode(
        AutomationSourceSummary.self,
        from: data
    )
    #expect(summary.id == id)
    #expect(summary.excludedRelativePaths.isEmpty)
}

@Test
func sourceConfigurationDocumentRoundTripsWithoutLocalPathsOrBookmarks() throws {
    let configuration = AutomationSourceConfiguration(
        sourceID: UUID(),
        displayName: "Archive",
        monitorPolicy: "off",
        excludedRelativePaths: ["Private", "Cache"]
    )
    let document = AutomationSourceConfigurationDocument(
        originLibraryID: UUID(),
        sources: [configuration]
    )
    let data = try AutomationWireCoding.encoder().encode(document)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Set(["schemaVersion", "originLibraryID", "sources"]))
    let sources = try #require(object["sources"] as? [[String: Any]])
    #expect(sources.count == 1)
    #expect(Set(try #require(sources.first).keys) == Set([
        "sourceID", "displayName", "monitorPolicy", "excludedRelativePaths"
    ]))
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationSourceConfigurationDocument.self,
        from: data
    )
    #expect(decoded == document)
}

@Test
func playlistMutationResultRoundTripsOpaqueRevision() throws {
    let playlist = AutomationPlaylistSummary(
        id: UUID(),
        name: "Agent target",
        description: "Test",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        trackCount: 2,
        totalDuration: 321.5,
        revision: "v1-abc"
    )
    let result = AutomationPlaylistMutationResult(
        operation: AutomationMethod.playlistAddTracks,
        applied: false,
        dryRun: true,
        playlist: playlist,
        requestedTrackIDs: [UUID()],
        changedTrackIDs: [UUID()],
        skippedTrackIDs: [],
        message: "preview"
    )
    let data = try AutomationWireCoding.encoder().encode(result)
    let decoded = try AutomationWireCoding.decoder().decode(
        AutomationPlaylistMutationResult.self,
        from: data
    )
    #expect(decoded == result)
    #expect(decoded.playlist?.revision == "v1-abc")
}

@Test
func unixSocketListenerRoundTripsARequest() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-automation-\(UUID().uuidString)", isDirectory: false)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task {
            await listener.stop()
        }
    }

    let client = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    )
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let response = try client.send(request)
    #expect(response.requestID == request.requestID)
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func unixSocketHandshakeRejectsWrongSecretAndAcceptsCorrectSecret() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-secret-\(UUID().uuidString.prefix(12))", isDirectory: false)
    let secret = Data("test-install-secret".utf8)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: secret
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task { await listener.stop() }
    }

    let wrongConfiguration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: Data("wrong-secret".utf8)
    )
    let wrongResponse = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: wrongConfiguration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(wrongResponse.error?.code == .authorizationRequired)

    let response = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func secretStoreCreatesPrivateStableCredential() throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-store-\(UUID().uuidString.prefix(12))", isDirectory: false)
    defer {
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    let first = try AutomationIPCSecretStore.loadOrCreate(forSocketPath: socketURL.path)
    let second = try AutomationIPCSecretStore.load(forSocketPath: socketURL.path)
    #expect(first.count == AutomationIPCSecretStore.defaultByteCount)
    #expect(second == first)

    var info = stat()
    #expect(lstat(try AutomationIPCSecretStore.url(forSocketPath: socketURL.path).path, &info) == 0)
    #expect((info.st_mode & mode_t(0o077)) == 0)
}

@Test
func importCapabilityAndJobResultPreserveContract() throws {
    let tool = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.libraryImport))
    #expect(!tool.readOnly)
    #expect(tool.supportsDryRun && tool.supportsJobs)
    #expect(tool.scopes == [.libraryRead, .libraryWrite])
    #expect(AutomationToolCatalog.unknownParameterKeys(for: tool.name, params: .object([
        "filePaths": .array([.string("/tmp/song.ncm")]),
        "targetPlaylistID": .string(UUID().uuidString), "dryRun": .boolean(true)
    ])).isEmpty)
    #expect(AutomationToolCatalog.unknownParameterKeys(for: tool.name, params: .object([
        "playlistID": .string(UUID().uuidString)
    ])) == ["playlistID"])
    let job = AutomationJobSummary(id: UUID(), kind: "importFiles", libraryID: UUID(),
        state: .completed, createdAt: Date(timeIntervalSince1970: 1_800_000_000), result: .object([
            "trackIDs": .array([.string(UUID().uuidString)]),
            "importedTrackCount": .number(1), "enrichmentCompleted": .boolean(true)
        ]))
    let response = AutomationLibraryImportResult(libraryID: UUID(), mode: "managed",
        filePaths: ["/tmp/song.ncm"], job: job, message: "Import started")
    let data = try AutomationWireCoding.encoder().encode(response)
    #expect(try AutomationWireCoding.decoder().decode(AutomationLibraryImportResult.self, from: data) == response)
    let oldJSON = """
    {"id":"\(UUID().uuidString)","kind":"other","state":"completed","createdAt":"2026-10-03T00:00:00Z"}
    """
    let oldJob = try AutomationWireCoding.decoder().decode(AutomationJobSummary.self, from: Data(oldJSON.utf8))
    #expect(oldJob.result == nil)
}

@Test
func libraryTrackPreferenceQuerySchemaIsAdvertised() {
    let tracks = AutomationToolCatalog.descriptor(for: AutomationMethod.libraryTracks)
    let report = AutomationToolCatalog.descriptor(for: AutomationMethod.libraryReport)
    #expect(tracks != nil)
    #expect(report != nil)
    #expect(AutomationToolCatalog.unknownParameterKeys(
        for: AutomationMethod.libraryTracks,
        params: .object(["includePreferenceStats": .boolean(true)])
    ).isEmpty)
    #expect(AutomationToolCatalog.unknownParameterKeys(
        for: AutomationMethod.libraryReport,
        params: .object(["includePreferenceStats": .boolean(true)])
    ).isEmpty)
}

@Test
func dspCatalogUsesAudioScopesAndCompleteVersionedSchemas() throws {
    let descriptors = AutomationDSPToolCatalog.descriptors.filter { $0.name.hasPrefix("dsp.") }
    #expect(descriptors.count == 16)
    #expect(Set(descriptors.map(\.name)).count == descriptors.count)
    for descriptor in descriptors {
        #expect(AutomationToolCatalog.descriptor(for: descriptor.name) != nil)
        #expect(descriptor.scopes == [descriptor.readOnly ? .audioRead : .audioWrite])
        #expect(!descriptor.requiresConfirmation)
        #expect(!descriptor.supportsJobs)
        #expect(!descriptor.supportsTasks)
        #expect(AutomationToolCatalog.unknownParameterKeys(for: descriptor.name,
            params: .object(["unsupported": .boolean(true)])) == ["unsupported"])
    }
    guard case .object(let presetFields) = AutomationDSPToolCatalog.presetSchema,
          case .object(let properties) = presetFields["properties"] else {
        Issue.record("Missing DSP preset properties")
        return
    }
    #expect(properties["revisionString"] != nil)
    #expect(properties["configuration"] == AutomationDSPToolCatalog.configurationSchema)
    let encoded = try AutomationWireCoding.encoder().encode(descriptors)
    let decoded = try AutomationWireCoding.decoder().decode([AutomationToolDescriptor].self, from: encoded)
    #expect(decoded == descriptors)
}

@Test
func globalLoudnessUsesExistingJobsAndAudioScopes() throws {
    let read = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.audioLoudnessGet))
    #expect(read.scopes == [.audioRead, .libraryRead])
    #expect(read.readOnly)
    let analyze = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.audioLoudnessAnalyze))
    #expect(analyze.scopes == [.audioWrite, .libraryRead])
    #expect(analyze.supportsDryRun && analyze.supportsJobs && analyze.supportsTasks)
    #expect(!analyze.requiresConfirmation)
    let audio = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.audioPatch))
    guard case .object(let schema) = audio.inputSchema,
          case .object(let fields) = schema["properties"],
          case .object(let values) = fields["values"],
          case .object(let parameters) = values["properties"] else {
        Issue.record("Missing audio globals schema")
        return
    }
    #expect(parameters["fade"] == AutomationDSPToolCatalog.fadeSchema)
    #expect(parameters["loudness"] == AutomationDSPToolCatalog.loudnessSchema)
    #expect(parameters["deviceReferences"] == AutomationDSPToolCatalog.deviceReferencesSchema)
}

@Test
func nativeDSPNodesExposeEveryParameterAndExplicitQuality() throws {
    #expect(AutomationDSPToolCatalog.builtInNodeSchemas.count == 6)
    for typeID in ["stereoWidth", "virtualBass", "tube"] {
        let raw = try #require(AutomationDSPToolCatalog.builtInNodeSchemas.first { node in
            guard case .object(let fields) = node else { return false }
            return fields["typeID"] == .string(typeID)
        })
        guard case .object(let node) = raw,
              case .object(let parameters) = node["parameters"],
              case .object(let properties) = parameters["properties"],
              case .array(let required) = parameters["required"],
              case .object(let defaults) = node["parameterDefaults"],
              case .array(let qualities) = node["quality"] else {
            Issue.record("Incomplete native DSP node schema")
            continue
        }
        #expect(Set(defaults.keys) == Set(properties.keys))
        #expect(required.count == properties.count)
        let requiredKeys = required.compactMap { value -> String? in
            guard case .string(let key) = value else { return nil }
            return key
        }
        #expect(requiredKeys.count == required.count)
        #expect(Set(requiredKeys) == Set(properties.keys))
        if typeID == "stereoWidth" {
            #expect(qualities == [.string("standard")])
            #expect(node["declaredLatencyFramesWhenActive"] == .number(0))
        } else {
            #expect(qualities == [.string("oversampling2x"), .string("oversampling4x")])
            #expect(node["declaredLatencyFramesWhenActive"] == .number(64))
            #expect(defaults["mix"] == .number(0))
            #expect(node["peakGuarantee"] == .string("unavailable"))
        }
    }
}


@Test
func programmableDSPToolsExposeDraftCASAndExistingJobs() throws {
    let methods = [AutomationMethod.dspScriptsGet, AutomationMethod.dspScriptsUpdate,
                   AutomationMethod.dspScriptsCompile, AutomationMethod.dspScriptsTest,
                   AutomationMethod.dspNodesRetry]
    for method in methods {
        _ = try #require(AutomationToolCatalog.descriptor(for: method))
    }
    let compile = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.dspScriptsCompile))
    #expect(compile.readOnly)
    let update = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.dspScriptsUpdate))
    #expect(update.supportsDryRun)
    #expect(update.scopes.contains(.audioWrite))
    let test = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.dspScriptsTest))
    #expect(test.supportsJobs)
    #expect(test.supportsTasks)
    #expect(test.supportsDryRun)
    #expect(test.scopes.contains(.audioWrite))
    #expect(test.scopes.contains(.libraryRead))
    #expect(AutomationToolCatalog.unknownParameterKeys(for: AutomationMethod.dspScriptsUpdate,
        params: .object(["nodeID": .string("id"), "source": .string("process { output = input; }"),
                         "expectedDraftRevision": .string("draft-1"), "apply": .boolean(true),
                         "expectedRevision": .string("config-1")])).isEmpty)
    #expect(AutomationToolCatalog.unknownParameterKeys(for: AutomationMethod.dspScriptsCompile,
        params: .object(["shell": .string("never")])) == ["shell"])
    let script = try #require(AutomationDSPToolCatalog.builtInNodeSchemas.first { node in
        guard case .object(let fields) = node else { return false }
        return fields["typeID"] == .string("script")
    })
    guard case .object(let fields) = script else { return }
    #expect(fields["parameters"] == AutomationDSPToolCatalog.scriptParametersSchema)
    #expect(fields["language"] == AutomationDSPToolCatalog.scriptLanguageCapabilities)
    #expect(AutomationDSPScriptDocumentation.languageGuide.contains("expectedDraftRevision"))
    #expect(AutomationDSPScriptDocumentation.languageGuide.contains("user data"))
}
