from __future__ import annotations
from pathlib import Path
from lddc_fetch_core.fetch import fetch_lyrics_bundle
from lddc_fetch_core.lrc_render import render_lrc

def main() -> None:
    title = "MALIYANG"
    artist = "珂拉琪 Collage"

    print(f"Fetching bundle for {artist} - {title}...")
    # 1. Fetch the raw bundle (metadata, orig, ts)
    try:
        bundle = fetch_lyrics_bundle(
            title=title,
            artist=artist,
            mode="verbatim",
            translation="provider", # Try to fetch translation if available
        )
    except Exception as e:
        print(f"Error fetching lyrics: {e}")
        return
    
    print(f"Found song: {bundle.song.artist_title()} (Source: {bundle.song.source})")
    
    out_dir = Path(__file__).resolve().parent / "out_separate"
    out_dir.mkdir(parents=True, exist_ok=True)
    
    # 2. Render Original Only
    if bundle.orig:
        lrc_orig = render_lrc(
            source=bundle.song.source,
            tags=bundle.tags,
            orig=bundle.orig,
            ts=None, # Force no translation
            mode="verbatim",
            include_translation=False,
            offset_ms=0,
        )
        path_orig = out_dir / f"{artist} - {title} [Original].lrc"
        path_orig.write_text(lrc_orig, encoding="utf-8")
        print(f"Saved Original: {path_orig}")
    else:
        print("No original lyrics found.")

    # 3. Render Translation Only
    # Treat translation as 'orig' to render it as a standalone LRC
    if bundle.ts:
        lrc_trans = render_lrc(
            source=bundle.song.source,
            tags=bundle.tags,
            orig=bundle.ts, # Pass translation as original
            ts=None,
            mode="line", # Translations are usually line-by-line, not verbatim
            include_translation=False,
            offset_ms=0,
        )
        path_trans = out_dir / f"{artist} - {title} [Translation].lrc"
        path_trans.write_text(lrc_trans, encoding="utf-8")
        print(f"Saved Translation: {path_trans}")
    else:
        print("No translation found.")

if __name__ == "__main__":
    main()
