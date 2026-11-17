# Extended music data and dynamic artwork

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
