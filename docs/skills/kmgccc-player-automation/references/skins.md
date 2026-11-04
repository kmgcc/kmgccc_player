# Native skins

When helping a skin author, read `skin.capabilities` first and write only names it lists. Validate
an author directory with `skin.check(directory)` (absolute path; compiles without installing,
selecting, or compiling Metal) and fix errors by the reported file and JSON path. After the author
links the directory in the App, `skin.reload(skinID)` recompiles it; a failure keeps the previous
version. `skin.runtime` reports nodes, per-frame evaluations, and audio readers for active scenes;
it is a counter, not a profiler. check and runtime are read-only; reload needs settings.write.

Scene syntax, node names and coordinate conventions are documented alongside the App at
`docs/skin-authoring-native.md`. When that file is not available, read `skin.capabilities` and the
reported validation errors instead of guessing names.
