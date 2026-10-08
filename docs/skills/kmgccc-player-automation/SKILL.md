---
name: kmgccc-player-automation
description: Operate kmgccc_player through its shared CLI/MCP automation contract for music-library lifecycle, composable queries, sources, first-class Track/Artist/Album/Playlist metadata and artwork, lyrics jobs, playback, queue, settings and diagnostics.
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
