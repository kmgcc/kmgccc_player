# Local Library Search Index and Fuzzy Search

## Existing Search Audit

Before this change, local library song search was owned by `PlaylistPageController.buildPageResult`.
It trimmed the toolbar query and filtered displayed rows with:

```swift
$0.title.localizedCaseInsensitiveContains(searchText)
```

That meant:

- only the song title participated in song-list search;
- artist, album, and lyrics were not part of the same retrieval path;
- every search rebuilt from the in-memory page rows;
- lyrics were never searched, and reading/parsing lyric files during each query would have been too expensive;
- album and artist overview pages had their own View-level contains filters, separate from the song-list pipeline.

The durable data source is the disk library under `LocalLibraryPaths.tracksRootURL`.
Each track has a `meta.json` sidecar. Lyric files are separate assets referenced by `lyricsFileName` or `ttmlLyricsFileName`, usually `lyrics.txt` or `lyrics.ttml`.
Imports, metadata edits, lyric edits, library completion, and deletion all pass through `SwiftDataLibraryRepository`, so search index maintenance is attached there rather than in SwiftUI views.

## Search Document

Each indexed track is represented by `SearchDocumentSource` and persisted as a normalized `SearchIndexedDocument`.

Fields:

- `trackID`
- raw and normalized `title`, `artist`, and `album`
- normalized title/artist/album combined text
- raw plain lyric text extracted from TTML or plain lyrics
- normalized lyric text
- lyric file path, modification time, file size, and content hash
- play count, preference score, last played time, and update time

The index does not modify track sidecars or lyric assets.

## SQLite Layout

The search index is stored separately from the SwiftData track cache:

`Application Support/<bundle id>/IndexCache/LibrarySearch.sqlite`

Tables:

- `documents`: authoritative indexed document cache, including raw plain lyrics for snippets and lyric file fingerprints for incremental rebuilds.
- `search_fts`: SQLite FTS5 table over normalized title, artist, album, combined metadata, and normalized lyrics.
- `grams`: character n-gram side table for substring/CJK/fuzzy candidate recall. Metadata grams have higher weights; lyric grams have low weight and a per-track cap.

FTS5 gives fast full-text retrieval. The n-gram table covers CJK text and substring queries that whitespace tokenizers do not handle well.

## TTML Plain Text Extraction

TTML is parsed with `XMLParser`.

The extractor:

- reads only text inside TTML `<body>` and lyric `<p>` elements;
- collects nested `<span>` text as visible lyric content;
- treats `<br>` as a line break;
- ignores element names, timestamps, attributes, and XML structure;
- normalizes whitespace while preserving natural lyric lines;
- falls back to a conservative tag-stripper if XML parsing fails.

The fallback is only a resilience path for damaged TTML. Normal indexing does not search raw XML.

## Normalization

`LibrarySearchTextNormalizer` is shared by metadata, lyrics, and queries.

Rules:

- Unicode compatibility composition;
- case, diacritic, and width folding;
- lowercasing;
- punctuation and special spaces converted to single spaces;
- repeated whitespace collapsed;
- CJK, kana, hangul, and alphanumeric characters retained;
- compact no-space forms used for substring and n-gram matching.

This handles case differences, full-width and half-width forms, accents, punctuation, and CJK text without relying on whitespace segmentation.

## Retrieval and Ranking

Search is two-stage.

Candidate retrieval:

- FTS5 prefix/OR query over normalized fields;
- n-gram lookup over metadata and lyrics;
- one-character queries skip lyric grams to avoid noisy result explosions;
- search scopes are intersected with the currently displayed playlist/artist/album/all-songs track IDs.

Ranking:

- title exact and normalized exact get the highest score;
- title prefix and title substring follow;
- artist and album matches are weighted lower than title;
- title+artist combination matches receive a strong bonus;
- lyric matches receive a lower score and can add a snippet, but should not outrank strong title matches;
- edit distance and trigram similarity are applied only to already-recalled candidates and only on title/artist/album/combined metadata;
- play count, last played date, and preference score are small tie-breakers.

This follows Fuse-style field weighting and typo tolerance while avoiding Levenshtein over the entire library or over long lyric bodies.

## Update Timing

Index updates are attached to repository-level write paths:

- repository reload schedules a low-priority full rebuild;
- import schedules upserts after track resources and sidecars are written;
- metadata and lyric edits schedule upserts after successful persistence;
- lyric completion writes through `saveTrackEdits`, so it also upserts;
- deletion removes search rows for deleted track IDs;
- clearing the track index cache also removes the search index store.

For unchanged lyric files, the upsert path reuses stored plain lyric text when file path, modified time, and file size match, avoiding repeated TTML parsing.

## Known Limits

- Chinese simplified/traditional conversion, Japanese kana romanization, and Korean decomposition are not added yet; the current implementation is conservative and dependency-free.
- The album and artist overview pages still have their own lightweight filters. The new persistent index is used by the song-list search pipeline.
- Initial search immediately after a very large library reload may wait for the background index actor if the rebuild is still in progress, but it does not block the main thread.
