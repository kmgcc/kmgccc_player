import Foundation

public extension AutomationMethod {
    static let enrichmentList = "metadata.enrichment.list"
    static let enrichmentGet = "metadata.enrichment.get"
    static let enrichmentRefresh = "metadata.enrichment.refresh"
    static let enrichmentPatch = "metadata.enrichment.patch"
    static let motionArtworkGet = "artwork.motion.get"
    static let motionArtworkSearch = "artwork.motion.search"
    static let motionArtworkApply = "artwork.motion.applyCandidate"
    static let motionArtworkImport = "artwork.motion.import"
    static let motionArtworkClear = "artwork.motion.clear"
    static let completionStatus = "metadata.completion.status"
    static let completionControl = "metadata.completion.control"
}

/// Shared by IPC, CLI discovery and MCP tools/list. New provider attributes are
/// returned as JSON, so catalog additions do not require another wire migration.
public enum AutomationMusicEnrichmentToolCatalog {
    public static let descriptors: [AutomationToolDescriptor] = [
        tool(AutomationMethod.enrichmentList, "List Extended Music Records",
             "Discover persisted local and external song identity keys, providers and dynamic-artwork state in bounded pages. Use a returned key with metadata.enrichment.get(externalKey) for an external song.",
             readOnly: true, scopes: [.libraryRead, .metadataRead], properties: [
                "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
             ]),
        tool(AutomationMethod.enrichmentGet, "Get Extended Music Metadata",
             "Read persisted provider records, resolved attributes, lyrics, identities and field provenance. Target trackID, externalKey, or omit both for current playback. includeLyrics or includeRaw requires lyrics.read; includeFilePaths requires files.read. No network request is made.",
             readOnly: true, scopes: [.libraryRead, .metadataRead],
             properties: target.merging([
                "includeLyrics": bool, "includeFilePaths": bool, "includeRaw": bool, "provider": string
             ], uniquingKeysWith: { _, new in new })),
        tool(AutomationMethod.enrichmentRefresh, "Refresh Extended Music Metadata",
             "Fetch and persist extended metadata for one Track or external identity independently of playback. includeMotion also downloads reusable dynamic artwork; force retries successful sources. Use metadata.completion.control to enqueue a whole library gently in the background.",
             readOnly: false, scopes: [.libraryRead, .metadataWrite, .artworkWrite],
             properties: target.merging([
                "force": bool, "includeMotion": bool, "dryRun": bool
             ], uniquingKeysWith: { _, new in new }), dryRun: true, jobs: true),
        tool(AutomationMethod.enrichmentPatch, "Patch Extended Music Metadata",
             "Persist manual overrides for extended catalog attributes while retaining every original provider result. fields accepts JSON values (null is an explicit blank); clearFields removes manual overrides so provider values become visible again. expectedRevision detects intervening edits.",
             readOnly: false, scopes: [.libraryRead, .metadataWrite],
             properties: target.merging([
                "fields": .object(["type": .string("object"), "additionalProperties": .boolean(true)]),
                "clearFields": .object(["type": .string("array"), "items": string]),
                "expectedRevision": string, "dryRun": bool
             ], uniquingKeysWith: { _, new in new }), dryRun: true),
        tool(AutomationMethod.motionArtworkGet, "Get Dynamic Artwork",
             "Read persisted square/tall dynamic artwork, provenance, selection state and local availability. includeFilePaths requires files.read. Target trackID, externalKey, or current playback.",
             readOnly: true, scopes: [.libraryRead, .artworkRead],
             properties: target.merging(["includeFilePaths": bool], uniquingKeysWith: { _, new in new })),
        tool(AutomationMethod.motionArtworkSearch, "Search Dynamic Artwork",
             "Search dynamic album artwork with optional title/artist/album corrections. Returns opaque candidate IDs bound to this Library and target revision; it does not apply or download video. Search uses the same provider as the song editor.",
             readOnly: true, scopes: [.libraryRead, .artworkRead],
             properties: target.merging([
                "title": string, "artist": string, "album": string,
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(6)])
             ], uniquingKeysWith: { _, new in new }), jobs: true),
        tool(AutomationMethod.motionArtworkApply, "Apply Dynamic Artwork Candidate",
             "Download and persist a candidate returned by artwork.motion.search, through the shared Library owner. Manual selection takes precedence over automatic matching. Expired, cross-Library and stale candidates are rejected.",
             readOnly: false, scopes: [.libraryRead, .artworkWrite],
             properties: ["candidateID": string, "expectedRevision": string, "dryRun": bool],
             required: ["candidateID"], dryRun: true, jobs: true),
        tool(AutomationMethod.motionArtworkClear, "Clear Dynamic Artwork Selection",
             "Clear a Track or external identity's dynamic artwork selection. resumeAutomatic=false preserves an explicit empty manual decision; true allows future automatic matching. Original audio files are untouched.",
             readOnly: false, scopes: [.libraryRead, .artworkWrite],
             properties: target.merging([
                "resumeAutomatic": bool, "expectedRevision": string, "dryRun": bool
             ], uniquingKeysWith: { _, new in new }), dryRun: true),
        tool(AutomationMethod.motionArtworkImport, "Import Dynamic Artwork Video",
             "Validate and copy a playable local video of at most 20 minutes into the Library as a song-specific dynamic-artwork override. Album defaults remain available to other songs. filePath must be an absolute local path; dryRun validates without importing.",
             readOnly: false, scopes: [.libraryRead, .artworkWrite, .filesRead],
             properties: target.merging([
                "filePath": string, "expectedRevision": string, "dryRun": bool
             ], uniquingKeysWith: { _, new in new }), required: ["filePath"], dryRun: true, jobs: true),
        tool(AutomationMethod.completionStatus, "Get Metadata Completion Status",
             "Read the Library's persistent lightweight completion queue: progress, current Track, pause/wait state and failures. The queue traverses all songs, with preferred songs first.",
             readOnly: true, scopes: [.libraryRead, .metadataRead], properties: [:]),
        tool(AutomationMethod.completionControl, "Control Metadata Completion",
             "Enqueue selected Tracks or the entire Library for idle dynamic-artwork completion, pause/resume the queue, or retry failures. Import remains independent. action is enqueue, pause, resume or retry; force requests a new scan of previously checked Tracks.",
             readOnly: false, scopes: [.libraryRead, .metadataWrite, .artworkWrite],
             properties: [
                "action": .object(["type": .string("string"), "enum": .array(["enqueue", "pause", "resume", "retry"].map(AutomationJSONValue.string))]),
                "trackIDs": .object(["type": .string("array"), "items": string, "maxItems": .number(5000)]),
                "force": bool, "dryRun": bool
             ], required: ["action"], dryRun: true)
    ]

    private static let string: AutomationJSONValue = .object(["type": .string("string")])
    private static let bool: AutomationJSONValue = .object(["type": .string("boolean")])
    private static let target: [String: AutomationJSONValue] = [
        "trackID": string,
        "externalKey": .object(["type": .string("string"), "description": .string("A persisted external identity key, available from playback.state or metadata.enrichment.get.")])
    ]

    private static func tool(
        _ name: String, _ title: String, _ description: String,
        readOnly: Bool, scopes: [AutomationScope],
        properties: [String: AutomationJSONValue], required: [String] = [], dryRun: Bool = false, jobs: Bool = false
    ) -> AutomationToolDescriptor {
        var properties = properties
        if jobs { properties["background"] = bool }
        var schema: [String: AutomationJSONValue] = [
            "type": .string("object"), "additionalProperties": .boolean(false),
            "properties": .object(properties)
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(AutomationJSONValue.string)) }
        return AutomationToolDescriptor(
            name: name, title: title, description: description,
            readOnly: readOnly, scopes: scopes, risk: readOnly ? .low : .medium,
            supportsDryRun: dryRun, supportsJobs: jobs, supportsTasks: jobs, inputSchema: .object(schema)
        )
    }
}
