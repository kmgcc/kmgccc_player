---
name: kmgccc-player-automation
description: Operate kmgccc_player through its shared CLI/MCP automation contract for composable music-library queries, sources, playlists, authorized file operations, metadata, lyrics jobs, playback, queue, settings and diagnostics.
---

# kmgccc_player Automation Skill

Use the App-owned automation capability catalog before inventing a workflow.

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
2. Compose `library.tracks` predicates (`all`, `any`, `not`, membership, dates, technical fields,
   lyrics/artwork/metadata state), stable sort and pagination.
3. Save revisions; use `dryRun` for medium/high risk changes and `expectedRevision` for writes.
4. Use `idempotencyKey` for retried mutations; poll long operations through `jobs.get`.
5. Verify with a new query and report applied, skipped, conflicts and failures.

For physical file work, inspect first, preview the destination, apply through `files.rename` or
`files.move`, then refresh the affected Source and verify the Track path. Never use direct Storage
edits to bypass Source authorization or the App confirmation policy.

## Safety

Do not delete real files, clear history, destructive-sync a Source, mass-delete, mass-overwrite
user metadata or write Storage unless the user explicitly asked and the App foreground policy
confirms it. `--yes`/`confirm=true` never bypasses the App confirmation.

For Source creation, let the App open its file picker; a raw path is not authorization. For
Storage fallback, follow `docs/agent-behavior-guide.md`: API → diagnostics/repair → current
source → backup → minimal edit → validate → reload/rescan → verify.

See:

- `docs/automation-capability-reference.md`
- `docs/agent-behavior-guide.md`
- `docs/automation-cli-reference.md`
- `docs/automation-mcp.md`
- `docs/automation-troubleshooting.md`
