#!/usr/bin/env python3
"""QQMusicApi stdio JSON helper.

Protocol:
  stdin:  one JSON request per line: {"id": "...", "method": "...", "params": {...}}
  stdout: one JSON response per line: {"id": "...", "ok": true, "candidates": [...]}

stdout is reserved for protocol JSON. Diagnostics must go to stderr.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.metadata
import json
import sys
import time
import traceback
from typing import Any


try:
    from qqmusic_api import Client
    from qqmusic_api.modules.search import SearchType

    IMPORT_ERROR: str | None = None
except Exception as exc:  # pragma: no cover - exercised in unbundled dev setups.
    Client = None  # type: ignore[assignment]
    SearchType = None  # type: ignore[assignment]
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"


SOURCE = "qqmusic"
MAX_IMAGE_SIZE = 800


def _log(message: str) -> None:
    print(f"[QQMusicHelper] {message}", file=sys.stderr, flush=True)


def _dependency_diagnostics() -> str:
    parts = [f"python={sys.version.split()[0]}", f"executable={sys.executable}"]
    try:
        qqmusic_api = importlib.import_module("qqmusic_api")
        parts.append(f"qqmusic_api={getattr(qqmusic_api, '__file__', '<unknown>')}")
        parts.append(f"qqmusic_api.__version__={getattr(qqmusic_api, '__version__', '<unknown>')}")
    except Exception as exc:
        parts.append(f"qqmusic_api import failed={type(exc).__name__}: {exc}")
    try:
        parts.append(f"dist={importlib.metadata.version('qqmusic-api-python')}")
    except Exception as exc:
        parts.append(f"dist=<unknown:{type(exc).__name__}>")
    for module_name in (
        "qqmusic_api.core.client",
        "qqmusic_api.modules.search",
        "qqmusic_api.models.search",
    ):
        try:
            module = importlib.import_module(module_name)
            parts.append(f"{module_name}=ok:{getattr(module, '__file__', '<unknown>')}")
        except Exception as exc:
            parts.append(f"{module_name}=failed:{type(exc).__name__}: {exc}")
    api_path = "Client.execute(search.search_by_type)"
    parts.append(f"search_api={api_path}")
    return " ".join(parts)


def _json_response(request_id: str | None, ok: bool, **payload: Any) -> str:
    response = {"id": request_id, "ok": ok}
    response.update(payload)
    return json.dumps(response, ensure_ascii=False, separators=(",", ":"))


def _require_dependency() -> None:
    if IMPORT_ERROR is not None:
        raise RuntimeError(f"qqmusic-api-python unavailable: {IMPORT_ERROR}")


def _first_text(value: Any, keys: tuple[str, ...]) -> str:
    if isinstance(value, dict):
        for key in keys:
            item = value.get(key)
            if isinstance(item, str) and item.strip():
                return item.strip()
            if isinstance(item, (int, float)):
                return str(item)
    return ""


def _to_plain(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, list):
        return [_to_plain(item) for item in value]
    if isinstance(value, tuple):
        return [_to_plain(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _to_plain(item) for key, item in value.items()}
    if hasattr(value, "model_dump"):
        return _to_plain(value.model_dump())
    if hasattr(value, "__dict__"):
        return {
            key: _to_plain(item)
            for key, item in vars(value).items()
            if not key.startswith("_")
        }
    return value


def _items_from_search_result(value: Any, keys: tuple[str, ...]) -> list[dict[str, Any]]:
    plain = _to_plain(value)
    if isinstance(plain, list):
        return [item for item in plain if isinstance(item, dict)]
    if isinstance(plain, dict):
        for key in keys:
            item = plain.get(key)
            if isinstance(item, list):
                return [entry for entry in item if isinstance(entry, dict)]
            if isinstance(item, dict):
                nested = _items_from_search_result(item, keys)
                if nested:
                    return nested
    return []


def _first_int(value: Any, keys: tuple[str, ...]) -> int | None:
    if not isinstance(value, dict):
        return None
    for key in keys:
        item = value.get(key)
        if isinstance(item, bool):
            continue
        if isinstance(item, int):
            return item
        if isinstance(item, float):
            return int(item)
        if isinstance(item, str) and item.strip().isdigit():
            return int(item.strip())
    return None


def _first_dict(value: Any, keys: tuple[str, ...]) -> dict[str, Any]:
    if isinstance(value, dict):
        for key in keys:
            item = value.get(key)
            if isinstance(item, dict):
                return item
    return {}


def _singers_text(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    singers = value.get("singer") or value.get("singers") or value.get("singer_list")
    if isinstance(singers, list):
        names: list[str] = []
        for singer in singers:
            if isinstance(singer, dict):
                name = _first_text(singer, ("name", "singerName", "title"))
                if name:
                    names.append(name)
            elif isinstance(singer, str) and singer.strip():
                names.append(singer.strip())
        if names:
            return ", ".join(names)
    return _first_text(value, ("singer", "singerName", "singer_name", "artist", "artistName"))


def _singer_mid(value: Any) -> str:
    if not isinstance(value, dict):
        return ""
    singers = value.get("singer") or value.get("singers") or value.get("singer_list")
    if isinstance(singers, list):
        for singer in singers:
            if isinstance(singer, dict):
                mid = _first_text(singer, ("mid", "singerMID", "singerMid"))
                if mid:
                    return mid
    return _first_text(value, ("singerMID", "singerMid", "mid"))


def _album_mid(value: Any) -> str:
    album = _first_dict(value, ("album", "albumInfo"))
    mid = _first_text(album, ("mid", "albumMID", "albumMid"))
    if mid:
        return mid
    return _first_text(value, ("albumMID", "albumMid", "albummid", "album_mid", "mid"))


def _album_name(value: Any) -> str:
    album = _first_dict(value, ("album", "albumInfo"))
    name = _first_text(album, ("name", "title", "albumName", "albumname"))
    if name:
        return name
    return _first_text(value, ("albumName", "albumname", "album", "title", "name"))


def _song_title(value: Any) -> str:
    return _first_text(value, ("title", "name", "songName", "songname"))


def _song_mid(value: Any) -> str:
    return _first_text(value, ("mid", "songMID", "songMid", "songmid"))


def _album_cover_url(album_mid: str) -> str:
    if not album_mid:
        return ""
    return f"https://y.gtimg.cn/music/photo_new/T002R{MAX_IMAGE_SIZE}x{MAX_IMAGE_SIZE}M000{album_mid}.jpg"


def _singer_cover_url(singer_mid: str) -> str:
    if not singer_mid:
        return ""
    return f"https://y.gtimg.cn/music/photo_new/T001R{MAX_IMAGE_SIZE}x{MAX_IMAGE_SIZE}M000{singer_mid}.jpg"


def _rank_confidence(index: int) -> float:
    return max(0.50, 0.86 - index * 0.04)


async def _search_by_type(
    keyword: str,
    search_type: Any,
    result_keys: tuple[str, ...],
    limit: int,
) -> list[dict[str, Any]]:
    if Client is None:
        return []
    async with Client() as client:
        result = await client.execute(
            client.search.search_by_type(
                keyword=keyword,
                search_type=search_type,
                num=limit,
                page=1,
                highlight=False,
            )
        )
    return _items_from_search_result(result, result_keys)


async def search_artist_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    name = str(params.get("name") or "").strip()
    if not name:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(name, SearchType.SINGER, ("singer", "singers", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        singer_name = _first_text(item, ("singerName", "name", "title"))
        singer_mid = _first_text(item, ("singerMID", "singerMid", "mid"))
        image_url = (
            _first_text(item, ("singerPic", "pic", "image", "picURL", "picUrl"))
            or _singer_cover_url(singer_mid)
        )
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "artistName": singer_name,
                "singerMid": singer_mid,
                "imageURL": image_url,
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def search_track_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    title = str(params.get("title") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album = str(params.get("album") or "").strip()
    query = " ".join(part for part in (title, artist, album) if part).strip()
    if not query:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(query, SearchType.SONG, ("song", "songs", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        album_mid = _album_mid(item)
        image_url = _album_cover_url(album_mid)
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "title": _song_title(item),
                "artist": _singers_text(item),
                "album": _album_name(item),
                "songMid": _song_mid(item),
                "albumMid": album_mid,
                "imageURL": image_url,
                "duration": _first_int(item, ("interval", "duration", "durationSec")),
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def search_album_artwork(params: dict[str, Any]) -> list[dict[str, Any]]:
    _require_dependency()
    album = str(params.get("album") or "").strip()
    artist = str(params.get("artist") or "").strip()
    query = " ".join(part for part in (album, artist) if part).strip()
    if not query:
        return []
    limit = max(1, min(int(params.get("limit") or 5), 10))
    results = await _search_by_type(query, SearchType.ALBUM, ("album", "albums", "list"), limit)
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(results or []):
        album_mid = _album_mid(item)
        image_url = (
            _first_text(item, ("picURL", "picUrl", "albumPic", "image"))
            or _album_cover_url(album_mid)
        )
        if not image_url:
            continue
        candidates.append(
            {
                "source": SOURCE,
                "album": _album_name(item),
                "artist": _singers_text(item),
                "albumMid": album_mid,
                "imageURL": image_url,
                "confidence": _rank_confidence(index),
            }
        )
    return candidates


async def handle_request(request: dict[str, Any]) -> dict[str, Any]:
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError("params must be an object")

    started_at = time.monotonic()
    _log(f"request id={request_id} method={method}")
    if method == "search_artist_artwork":
        candidates = await search_artist_artwork(params)
    elif method == "search_track_artwork":
        candidates = await search_track_artwork(params)
    elif method == "search_album_artwork":
        candidates = await search_album_artwork(params)
    else:
        raise ValueError(f"unsupported method: {method}")

    duration_ms = int((time.monotonic() - started_at) * 1000)
    top_confidence = max((float(item.get("confidence") or 0) for item in candidates), default=0.0)
    _log(
        f"response id={request_id} method={method} "
        f"candidates={len(candidates)} topConfidence={top_confidence:.2f} durationMs={duration_ms}"
    )
    return {"id": request_id, "ok": True, "candidates": candidates}


async def main() -> int:
    _log(f"startup {_dependency_diagnostics()}")
    while True:
        line = await asyncio.to_thread(sys.stdin.buffer.readline)
        if not line:
            return 0
        try:
            request = json.loads(line.decode("utf-8"))
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
            response = await handle_request(request)
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)
        except Exception as exc:
            request_id = None
            try:
                request_id = request.get("id") if isinstance(request, dict) else None
            except Exception:
                request_id = None
            _log(traceback.format_exc())
            print(
                _json_response(request_id, False, error=f"{type(exc).__name__}: {exc}"),
                flush=True,
            )


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
