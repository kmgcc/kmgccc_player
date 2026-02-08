# SPDX-FileCopyrightText: Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from lddc_fetch_core.fetch import fetch_lrc, fetch_lyrics_bundle
from lddc_fetch_core.lrc_render import render_lrc
from lddc_fetch_core.match import score_candidate
from lddc_fetch_core.models import Artist, LyricsBundle, Song, Source
from lddc_fetch_core.providers.kg import KGProvider
from lddc_fetch_core.providers.lrclib import LrclibProvider
from lddc_fetch_core.providers.ne import NEProvider
from lddc_fetch_core.providers.qm import QMProvider

# Provider instances (lazy initialized)
_PROVIDERS: dict[Source, object] = {}


def _get_provider(source: Source) -> object:
    if source in _PROVIDERS:
        return _PROVIDERS[source]
    provider: object
    if source == Source.LRCLIB:
        provider = LrclibProvider()
    elif source == Source.QM:
        provider = QMProvider()
    elif source == Source.KG:
        provider = KGProvider()
    elif source == Source.NE:
        provider = NEProvider()
    else:
        raise ValueError(f"Unsupported source: {source}")
    _PROVIDERS[source] = provider
    return provider


def _song_to_dict(song: Song, score: float) -> dict[str, Any]:
    """Convert Song to JSON-serializable dict for /search response."""
    return {
        "source": song.source.value,
        "id": song.id,
        "score": round(score, 2),
        "title": song.title,
        "artist": str(song.artist) if song.artist else None,
        "album": song.album,
        "duration_ms": song.duration_ms,
        "extra": song.extra if song.extra else None,
    }


def _search_source(
    source: Source,
    title: str,
    artist: str | None,
    limit: int,
) -> tuple[list[dict], str | None]:
    """Search a single source, returning (results, error)."""
    try:
        provider = _get_provider(source)
        songs = provider.search(f"{artist} {title}" if artist else title, page=1)  # type: ignore[attr-defined]
        
        # Score and filter results
        scored: list[tuple[float, Song]] = []
        for song in songs[:limit]:
            # Keep client decoding stable: Swift expects non-optional `id` and `title`.
            if not song.id or not song.title:
                continue
            cand_artist = str(song.artist) if song.artist else None
            s = score_candidate(title, artist, song.title, cand_artist)
            scored.append((s, song))
        
        # Sort by score descending
        scored.sort(key=lambda x: x[0], reverse=True)
        
        return [_song_to_dict(song, score) for score, song in scored], None
    except Exception as e:
        return [], f"{source.value}: {e.__class__.__name__}: {e}"


def _reconstruct_song(source: Source, req: dict) -> Song:
    """Reconstruct a Song object from request data for fetch_by_id."""
    # Build extra dict if provided
    extra = req.get("extra") or {}
    
    return Song(
        source=source,
        id=req["id"],
        title=req.get("title"),
        artist=Artist(req["artist"]) if req.get("artist") else None,
        album=req.get("album"),
        duration_ms=req.get("duration_ms"),
        extra=extra,
    )


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        valid_paths = ("/fetch", "/fetch_separate", "/search", "/fetch_by_id", "/fetch_by_id_separate")
        if self.path not in valid_paths:
            self._send(404, {"error": "not found"})
            return
        
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            req = json.loads(raw.decode("utf-8"))

            # Reject enhanced mode
            mode = req.get("mode", "verbatim")
            if mode == "enhanced":
                self._send(400, {"error": "enhanced mode is not supported; use 'line' or 'verbatim'"})
                return

            if self.path == "/search":
                self._handle_search(req)
            elif self.path == "/fetch_by_id":
                self._handle_fetch_by_id(req, separate=False)
            elif self.path == "/fetch_by_id_separate":
                self._handle_fetch_by_id(req, separate=True)
            elif self.path == "/fetch":
                self._handle_fetch(req)
            elif self.path == "/fetch_separate":
                self._handle_fetch_separate(req)

        except Exception as e:  # noqa: BLE001
            self._send(400, {"error": f"{e.__class__.__name__}: {e}"})

    def _handle_search(self, req: dict) -> None:
        """Handle POST /search - multi-platform candidate search."""
        title = req.get("title", "").strip()
        if not title:
            self._send(400, {"error": "title is required"})
            return
        
        artist = req.get("artist", "").strip() or None
        source_names = req.get("sources", ["LRCLIB", "QM", "KG", "NE"])
        limit_per_source = int(req.get("limit_per_source", 20))
        
        # Parse sources
        sources: list[Source] = []
        for name in source_names:
            try:
                sources.append(Source[name])
            except KeyError:
                pass  # Ignore invalid source names
        
        if not sources:
            self._send(400, {"error": "no valid sources specified"})
            return
        
        # Search in parallel
        all_results: list[dict] = []
        errors: list[str] = []
        
        with ThreadPoolExecutor(max_workers=len(sources)) as executor:
            futures = {
                executor.submit(_search_source, src, title, artist, limit_per_source): src
                for src in sources
            }
            for future in as_completed(futures):
                results, error = future.result()
                all_results.extend(results)
                if error:
                    errors.append(error)
        
        # Sort all results by score descending
        all_results.sort(key=lambda x: x["score"], reverse=True)
        
        resp: dict[str, Any] = {"results": all_results}
        if errors:
            resp["errors"] = errors
        
        self._send(200, resp)

    def _handle_fetch_by_id(self, req: dict, *, separate: bool) -> None:
        """Handle POST /fetch_by_id and /fetch_by_id_separate."""
        source_name = req.get("source")
        song_id = req.get("id")
        
        if not source_name or not song_id:
            self._send(400, {"error": "source and id are required"})
            return
        
        try:
            source = Source[source_name]
        except KeyError:
            self._send(400, {"error": f"invalid source: {source_name}"})
            return
        
        mode = req.get("mode", "verbatim")
        translation = req.get("translation", "none")
        offset_ms = int(req.get("offset_ms", 0))
        ms_digits = int(req.get("ms_digits", 3))
        
        # Reconstruct Song and fetch lyrics
        song = _reconstruct_song(source, req)
        provider = _get_provider(source)
        
        try:
            bundle = provider.get_lyrics(song)  # type: ignore[attr-defined]
        except Exception as e:
            self._send(400, {"error": f"Failed to fetch lyrics: {e}"})
            return
        
        if not bundle.orig:
            self._send(404, {"error": "No lyrics content found"})
            return
        
        if separate:
            # Return orig and trans separately
            resp: dict[str, Any] = {}
            
            resp["lrc_orig"] = render_lrc(
                source=bundle.song.source,
                tags=bundle.tags,
                orig=bundle.orig,
                ts=None,
                mode=mode,
                include_translation=False,
                offset_ms=offset_ms,
                ms_digits=ms_digits,
            )
            
            if bundle.ts and translation != "none":
                resp["lrc_trans"] = render_lrc(
                    source=bundle.song.source,
                    tags=bundle.tags,
                    orig=bundle.ts,  # Treat translation as orig
                    ts=None,
                    mode="line",  # Translation is usually line-by-line
                    include_translation=False,
                    offset_ms=offset_ms,
                    ms_digits=ms_digits,
                )
            
            self._send(200, resp)
        else:
            # Return merged LRC
            include_translation = translation != "none" and bundle.ts is not None
            
            lrc = render_lrc(
                source=bundle.song.source,
                tags=bundle.tags,
                orig=bundle.orig,
                ts=bundle.ts if include_translation else None,
                mode=mode,
                include_translation=include_translation,
                offset_ms=offset_ms,
                ms_digits=ms_digits,
            )
            
            self._send(200, {"lrc": lrc})

    def _handle_fetch(self, req: dict) -> None:
        """Handle legacy POST /fetch."""
        sources = tuple(Source[s] for s in req.get("sources", ["LRCLIB", "QM", "KG", "NE"]))
        offset_ms = int(req.get("offset_ms", 0))
        ms_digits = int(req.get("ms_digits", 3))
        
        common_args = {
            "title": req["title"],
            "artist": req.get("artist"),
            "mode": req.get("mode", "verbatim"),
            "translation": req.get("translation", "none"),
            "sources": sources,
            "openai_base_url": req.get("openai_base_url", ""),
            "openai_api_key": req.get("openai_api_key", ""),
            "openai_model": req.get("openai_model", ""),
            "openai_target_lang": req.get("openai_target_lang", "简体中文"),
        }

        lrc = fetch_lrc(
            **common_args,
            offset_ms=offset_ms,
            ms_digits=ms_digits,
        )
        self._send(200, {"lrc": lrc})

    def _handle_fetch_separate(self, req: dict) -> None:
        """Handle legacy POST /fetch_separate."""
        sources = tuple(Source[s] for s in req.get("sources", ["LRCLIB", "QM", "KG", "NE"]))
        offset_ms = int(req.get("offset_ms", 0))
        ms_digits = int(req.get("ms_digits", 3))
        
        bundle_args = {
            "title": req["title"],
            "artist": req.get("artist"),
            "mode": req.get("mode", "verbatim"),
            "translation": req.get("translation", "none"),
            "sources": sources,
            "openai_base_url": req.get("openai_base_url", ""),
            "openai_api_key": req.get("openai_api_key", ""),
            "openai_model": req.get("openai_model", ""),
            "openai_target_lang": req.get("openai_target_lang", "简体中文"),
        }
        
        bundle = fetch_lyrics_bundle(
            **bundle_args,
            min_score=55.0,
            max_candidates=8,
        )
        
        resp: dict[str, Any] = {}
        if bundle.orig:
            resp["lrc_orig"] = render_lrc(
                source=bundle.song.source,
                tags=bundle.tags,
                orig=bundle.orig,
                ts=None,
                mode=req.get("mode", "verbatim"),
                include_translation=False,
                offset_ms=offset_ms,
                ms_digits=ms_digits,
            )
        
        if bundle.ts:
            resp["lrc_trans"] = render_lrc(
                source=bundle.song.source,
                tags=bundle.tags,
                orig=bundle.ts,
                ts=None,
                mode="line",
                include_translation=False,
                offset_ms=offset_ms,
                ms_digits=ms_digits,
            )
        
        self._send(200, resp)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="lddc-fetch-core HTTP server")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    args = p.parse_args(argv)

    print(f"Starting LDDC server on {args.host}:{args.port}")
    httpd = HTTPServer((args.host, args.port), Handler)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
