import Foundation
import Testing
@testable import PlayerAutomationProtocol

@Test
func musicEnrichmentCapabilitiesUseSharedStrictSchemas() throws {
    let names = Set(AutomationMusicEnrichmentToolCatalog.descriptors.map(\.name))
    #expect(names.count == 11)
    for tool in AutomationMusicEnrichmentToolCatalog.descriptors {
        #expect(AutomationToolCatalog.descriptor(for: tool.name) == tool)
        #expect(AutomationToolCatalog.unknownParameterKeys(for: tool.name, params: .object(["unexpected": .boolean(true)])) == ["unexpected"])
        #expect(tool.scopes.contains(.libraryRead))
        #expect(!tool.requiresConfirmation)
    }
    let search = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.motionArtworkSearch))
    #expect(search.readOnly && search.supportsJobs && search.supportsTasks)
    let apply = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.motionArtworkApply))
    #expect(!apply.readOnly && apply.supportsDryRun && apply.supportsJobs)
    #expect(AutomationToolCatalog.unknownParameterKeys(for: apply.name, params: .object([
        "candidateID": .string("opaque"), "background": .boolean(true), "dryRun": .boolean(true)
    ])).isEmpty)
    let imported = try #require(AutomationToolCatalog.descriptor(for: AutomationMethod.motionArtworkImport))
    #expect(imported.scopes.contains(.filesRead) && imported.supportsDryRun && imported.supportsTasks)
    for name in [AutomationMethod.lyricsSearch, AutomationMethod.lyricsCandidates] {
        #expect(AutomationToolCatalog.unknownParameterKeys(for: name, params: .object([
            "trackID": .string(UUID().uuidString), "sources": .array([.string("AMLLDB"), .string("LRCLIB")])
        ])).isEmpty)
    }
}

@Test
func playbackProvenanceRemainsCompatibleWithPreviousClients() throws {
    let old = Data("""
    {"source":"appleMusic","isPlaying":true,"currentTrackID":null,
     "currentTitle":"Song","currentArtist":"Artist","position":12,
     "duration":180,"volume":0.6,"playbackMode":"sequential"}
    """.utf8)
    let decoded = try JSONDecoder().decode(AutomationPlaybackState.self, from: old)
    #expect(decoded.externalStableKey == nil && decoded.metadataSources == nil)
    let state = AutomationPlaybackState(
        source: "appleMusic", isPlaying: true, currentTrackID: nil,
        currentTitle: "Song", currentArtist: "Artist", position: 12,
        duration: 180, volume: 0.6, playbackMode: "sequential",
        externalStableKey: "apple:id", enrichmentKey: "apple:id",
        metadataSources: ["artwork": "appleWeb", "lyrics": "amllDB"]
    )
    #expect(try JSONDecoder().decode(AutomationPlaybackState.self, from: JSONEncoder().encode(state)) == state)
}
