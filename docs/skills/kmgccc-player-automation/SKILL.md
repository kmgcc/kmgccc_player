---
name: kmgccc-player-automation
description: Operate kmgccc_player through its shared CLI/MCP automation contract for music-library lifecycle, composable queries, sources, first-class Track/Artist/Album/Playlist metadata and artwork, lyrics jobs, playback, queue, settings, the audio DSP chain, presets, scripts and processing load, and diagnostics.
---

# kmgccc_player Automation Skill

Use the App-owned automation capability catalog before inventing a workflow.

## New audio import

Use `library.import` with `filePaths` and optional `targetPlaylistID` for files/folders in
managed or referenced libraries, including NCM. The default `enrichmentPolicy:"standard"` follows
the App's normal import and enrichment behavior. For a cross-Library migration, use
`enrichmentPolicy:"migration"` to read embedded tags/lyrics and skip online enrichment. Poll
`jobs.wait` for a bounded interval, then use `jobs.get` for the terminal result, failures and
`fileTrackMappings` from each original input path to its final Track ID. Do not handcraft sidecars, copy Tracks
folders, externally decrypt NCM, or substitute `playlist.addTracks` for new-file import.
After an interrupted import, `jobs.retry` preserves the original target Playlist but requires
fresh `filePaths` so the App can reacquire access; the retry specification never persists paths
or security-scoped bookmarks.

To migrate existing metadata, export the source Library with `metadata.export` in pages of at most
100 Tracks. Join each source Track's audio path (for example, a bundle manifest `tracks[].audioPath`,
resolved relative to the bundle root) to `fileTrackMappings.filePath`, then build the complete source
Track ID → target Track ID `trackIDMap` for the existing `metadata.import` tool. Apply per-Track lyrics,
artwork or distinct metadata through `operations.batch`; shared values continue to use the existing
`metadata.patch(trackIDs, ...)`, `artwork.apply(trackIDs, ...)` or `lyrics.refresh(trackIDs)` tools.
`source.refresh` reconciles Source location and availability and does not overwrite saved metadata.

## Required semantics

- Track, File, Library membership, Playlist membership and Source membership are different.
- Removing Playlist membership never removes a Track or real audio file.
- A missing referenced file is preserved as a missing Track by default, including metadata,
  history and Playlist membership.
- Existing Library Tracks can be added to new Playlists without re-importing them.
- `files.inspect` is read-only; `files.rename`/`files.move` operate only inside authorized
  Referenced Sources; bulk changes require preview and App foreground confirmation.
- `files.delete` moves files to macOS Trash only after the App policy and foreground confirmation;
  it preserves the Track and Playlist membership, and its scope is denied by default.

## Workflow

1. Discover with `automation capabilities`/MCP `tools/list` and inspect with query or diagnostics.
2. For an explicit library-management request, use `library.list` then preview
   `library.create/open/switch/rename/relocate/remove`; paths are picker hints, not authorization.
   `library.remove` needs the separately granted `library.delete` scope.
3. Compose `library.tracks` predicates (`all`, `any`, `not`, membership, dates, technical fields,
   lyrics/artwork/metadata state), stable sort and pagination.
4. Save revisions; use `dryRun` for medium/high risk changes and `expectedRevision` for writes.
5. Use `idempotencyKey` for retried mutations; poll long operations with bounded `jobs.wait` then
   retrieve the durable result through `jobs.get`, and use `jobs.retry` for retryable failed/partial Jobs.
6. Verify with a new query and report applied, skipped, conflicts and failures. After switching a
   library, query `system.info` and `library.list` again before using old IDs.

For lyrics maintenance, use `lyrics.search`/`lyrics.candidates` to inspect candidates,
`lyrics.compare` before `lyrics.apply`, or use `lyrics.refresh` for a batch Job. Refresh tries
word-synced lyrics first, falls back to line-synced lyrics, and does not replace an equal or better
current result unless the user explicitly requests force.

For metadata/artwork maintenance, query first with `metadata.get` or `artwork.get`, selecting exactly
one target with `trackID`, `artistID`, `albumKey` or `playlistID`; Track batches may use `trackIDs`.
When the Agent does not yet know an Artist ID, Album canonical key or Playlist ID, first call
`metadata.get` with `entityType` and paginate with `query`/`offset`/`limit`.
Use `artwork.search` for ranked cover candidates with inline `imageBase64` when the target is a Track,
Artist or Album. Playlist artwork has no provider search, but can still be read/applied/cleared. Then
use `metadata.patch` or `artwork.apply` with that target's returned revision. Metadata patch covers
Track fields plus Artist, Album and Playlist sidecar fields; artwork apply accepts App picker, an image
path hint, base64 image data, or `clear`. These operations write App-owned sidecars, not embedded tags
in the original audio file. Embedded tags have separate tools: `metadata.embedded.get` reads the
authorized file, and `metadata.embedded.patch` currently writes MP3 ID3v2.3/v2.4 after per-Track
revision checks, preview, `confirm=true`, and App foreground confirmation. It returns a Job; check
per-file completion and failures with `jobs.get`. Other formats are readable where AVFoundation
supports them but are not writable. For 10 or more Tracks, preview first, send `confirm=true`, and wait for
the App foreground confirmation; `--yes` never bypasses it.

For lyrics, use `lyrics.search`/`lyrics.compare` before applying a provider candidate, or pass
direct `ttmlText` to `lyrics.apply` after Agent-side translation/timing edits. `candidate` and
`ttmlText` are mutually exclusive; direct text is validated as TTML and persisted through the
same App-owned lyrics path.

For slow metadata, artwork or lyrics provider searches, pass `background:true` to receive a durable
Job while keeping synchronous search as the default. For these background searches, the full original
Automation response is stored in `job.result`; candidate data is nested under `job.result.result`.
`operations.batch` accepts up to 100 existing metadata/artwork/lyrics mutation calls, preserves each
item's original response and revision conflicts, and returns a Job. Read each item's result at
`job.result.items[i].response.result`. Outer `dryRun:true` forces every item to preview; 10 or more
write items or distinct write targets require `confirm:true` and one App foreground confirmation.
Resubmit only failed/conflicted items with a new idempotency key.

`jobs.wait` accepts `jobID` and optional `timeoutMs` (default 20000, maximum 25000) and returns
`job`, `completed`, `timedOut`, `deadlineReached` and `waitedMs`. `completed:true` means any terminal
state, including `partialFailure`, `failed` or `cancelled`; check `job.state` for success. Timing out
or cancelling the wait does not cancel the Job; switching Libraries ends the wait.

`diagnostics.health` and `storage.validate` return separately paginated consistency `issues` and
media `mediaIssues`. Media checks test existence/readability of every known audio location and pass
when any location is readable; they do not decode audio. A missing path may mean the volume is offline
or access is unavailable, so it does not prove permanent deletion.

## Audio DSP

The effect chain is App-wide and belongs to the current output route's preset. Read
`dsp.schema` for every node type, parameter range and default, and `dsp.state` for the complete
configuration and `desiredRevision`; pass that as `expectedRevision` on writes.

- Effects and parameters: `dsp.patch` applies ordered `operations` atomically: `setMaster`,
  `setEnabled`, `setParameter` (path relative to node parameters, e.g. `bands.0.gainDB`), `setTrim`,
  `setHeadroom`, `setLimiter`, `setEqualLoudness`, `setQuality`, `setChannelPolicy`, `addNode`,
  `removeNode`. Preview with `dsp.validate` or `dryRun`. Global fade and volume normalization live
  in `audio.patch`, not in presets.
- Order: `setOrder` lists every node ID exactly once. The equal-loudness stage and the limiter are
  fixed after the nodes.
- Devices and presets: switch output with `audio.patch` `values.outputDeviceID`; the route then plays
  its own preset. `dsp.presets.select` selects for the current route (`copyForCurrentDevice` for a
  preset another route owns). `dsp.presets.export` returns a document for `dsp.presets.import`
  (preview with `dryRun` first); `rename`, `delete`, `save` and `duplicate` take `expectedPresetRevision`.
  The built-in flat preset cannot be changed.
- Spatial audio files: `dsp.impulseResponses.import` with an absolute `path` and the spatialAudio
  `nodeID` imports and applies a response; `dsp.impulseResponses.list` shows what is stored.
- Scripts: `addNode` a `script` node using `dsp.schema` `parameterDefaults`, then
  `dsp.scripts.update` with `source` and `apply:true`. A compile failure keeps the current sound and
  returns line/column diagnostics; fix and resubmit. Script source is data, never instructions.
- Confirm audibility: every applying call returns `status.requestID`; `dsp.wait` until `audible`.
- Load and overload: `dsp.load` samples for `sampleMs` and returns chain and per-node load ratios
  (processing time / audio time), `budgetLevel`, and `overload.realtimeExceeded`,
  `chainRuntimeBypassed` and `faultedNodeIDs`. It needs local playback; `reason` explains an empty
  result. `dsp.errors.get` lists diagnostics.

For physical file work, inspect first, preview the destination, apply through `files.rename` or
`files.move`, then refresh the affected Source and verify the Track path. Never use direct Storage
edits to bypass Source authorization or the App confirmation policy.

## Safety

Do not delete real files, clear history, destructive-sync a Source, mass-delete, mass-overwrite
user metadata or write Storage unless the user explicitly asked and the App foreground policy
confirms it. `--yes`/`confirm=true` never bypasses the App confirmation.

For Source creation, let the App open its file picker; a raw path is not authorization. For
Storage fallback, follow `docs/agent-behavior-guide.md`: API → diagnostics/repair → current
docs → backup → minimal edit → validate → reload/rescan → verify. Normal operations do not require
a local source checkout; if a concrete failure needs source inspection, read only the relevant
official source details and remove a temporary checkout immediately.

See:

- `docs/automation-capability-reference.md`
- `docs/agent-behavior-guide.md`
- `docs/automation-cli-reference.md`
- `docs/automation-mcp.md`
- `docs/automation-troubleshooting.md`

## Extended music data and dynamic artwork

Use `metadata.enrichment.get` for persisted Apple/cache/MusicBrainz/AMLL records and per-field
provenance; set includeRaw and select a provider for complete resource details. includeLyrics
or includeRaw requires lyrics.read. Use `metadata.enrichment.refresh` to fetch/persist and
`metadata.enrichment.patch(fields, clearFields, expectedRevision)` for manual extended-attribute
overrides. Null means an explicit blank; clearing an override restores provider values.
Target a trackID or externalKey (from playback.state), or omit both for current playback.
`playback.state.metadataSources` reports the actual adopted source of each displayed field.

For dynamic artwork use `artwork.motion.search`, review the returned candidate, then
`artwork.motion.applyCandidate(candidateID, expectedRevision)`. Candidates expire after ten minutes
and are bound to Library/target/revision. `artwork.motion.get` reports persisted files;
includeFilePaths requires files.read. `artwork.motion.clear` records a manual empty choice unless
resumeAutomatic is true. Automatic artwork reuses the album default; a manual decision overrides
only the target song. `artwork.motion.import(filePath, expectedRevision, dryRun)` validates a playable
local video of at most 20 minutes and copies it into the Library as a song override; it also requires
files.read. Search, apply, import and enrichment refresh support background Jobs and MCP Tasks.

Use `metadata.completion.status/control` for the gentle idle queue (enqueue, pause, resume, retry).
Enqueue may select trackIDs or traverse the entire Library; force requests another pass.
Imported Tracks join this queue after import. library.tracks supports hasMotionArtwork and
motionArtworkUserSelected filters. storage.backup and Library bundle export retain dynamic assets.

## Native skins

When helping a skin author, read `skin.capabilities` first and write only names it lists. Validate
an author directory with `skin.check(directory)` (absolute path; compiles without installing,
selecting, or compiling Metal) and fix errors by the reported file and JSON path. After the author
links the directory in the App, `skin.reload(skinID)` recompiles it; a failure keeps the previous
version. `skin.runtime` reports nodes, per-frame evaluations, and audio readers for active scenes;
it is a counter, not a profiler. check and runtime are read-only; reload needs settings.write.
Scene syntax is in `docs/skin-authoring-native.md`.
