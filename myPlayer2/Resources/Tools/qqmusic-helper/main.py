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
import re
import sys
import time
import traceback
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse, urlunparse


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
QQMUSIC_HTTPS_IMAGE_HOSTS = {
    "y.gtimg.cn",
    "qpic.y.qq.com",
    "y.qq.com",
    "thirdqq.qlogo.cn",
    "thirdwx.qlogo.cn",
}


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
        "qqmusic_api.modules.singer",
        "qqmusic_api.modules.album",
        "qqmusic_api.modules.song",
        "qqmusic_api.models.search",
        "qqmusic_api.models.singer",
        "qqmusic_api.models.album",
        "qqmusic_api.models.song",
    ):
        try:
            module = importlib.import_module(module_name)
            parts.append(f"{module_name}=ok:{getattr(module, '__file__', '<unknown>')}")
        except Exception as exc:
            parts.append(f"{module_name}=failed:{type(exc).__name__}: {exc}")
    api_path = "Client.execute(search.search_by_type/detail modules)"
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


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _compact_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    return ""


def _optional_text(value: Any) -> str | None:
    text = _compact_text(value)
    return text or None


def _split_tags(value: Any) -> list[str]:
    if isinstance(value, list):
        raw_items = value
    else:
        raw_items = re.split(r"[,，、/;；|｜\n]+", _compact_text(value))
    tags: list[str] = []
    seen: set[str] = set()
    for item in raw_items:
        tag = _compact_text(item)
        if not tag or tag in seen:
            continue
        seen.add(tag)
        tags.append(tag)
    return tags


def _release_year(value: Any) -> int | None:
    match = re.search(r"\b(19|20)\d{2}\b", _compact_text(value))
    return int(match.group(0)) if match else None


def _content_values(items: Any) -> list[str]:
    if not isinstance(items, list):
        return []
    values: list[str] = []
    for item in items:
        if isinstance(item, dict):
            text = _first_text(item, ("value", "title", "name"))
        else:
            text = _compact_text(item)
        if text:
            values.append(text)
    return values


def _first_content_value(items: Any) -> str:
    values = _content_values(items)
    return values[0] if values else ""


def _join_description(values: list[str]) -> str:
    cleaned = [value.strip() for value in values if value.strip()]
    return "\n".join(cleaned)


def _sanitize_image_url(value: str) -> str:
    raw = value.strip()
    if not raw:
        return ""
    parsed = urlparse(raw)
    if parsed.scheme.lower() == "http" and parsed.netloc.lower() in QQMUSIC_HTTPS_IMAGE_HOSTS:
        sanitized = urlunparse(parsed._replace(scheme="https"))
        _log(f"sanitized imageURL from={raw} to={sanitized}")
        return sanitized
    return raw


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


def _singers_text_from_list(value: Any) -> str:
    if not isinstance(value, list):
        return ""
    names: list[str] = []
    for singer in value:
        if isinstance(singer, dict):
            name = _first_text(singer, ("name", "title", "singerName"))
            if name:
                names.append(name)
    return ", ".join(names)


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


async def _execute_client_request(request_builder: Any) -> Any:
    if Client is None:
        return {}
    async with Client() as client:
        result = await client.execute(request_builder(client))
    return _to_plain(result)


async def _fetch_singer_desc(singer_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.singer.get_desc([singer_mid]))
    items = _items_from_search_result(plain, ("singer_list", "singerList", "list"))
    return items[0] if items else {}


async def _fetch_singer_info(singer_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.singer.get_info(singer_mid))
    return plain if isinstance(plain, dict) else {}


async def _fetch_album_detail_raw(album_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.album.get_detail(album_mid))
    return plain if isinstance(plain, dict) else {}


async def _fetch_song_detail_raw(song_mid: str) -> dict[str, Any]:
    plain = await _execute_client_request(lambda client: client.song.get_detail(song_mid))
    return plain if isinstance(plain, dict) else {}


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
        image_url = _sanitize_image_url(image_url)
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
        image_url = _sanitize_image_url(_album_cover_url(album_mid))
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
        image_url = _sanitize_image_url(image_url)
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


async def fetch_artist_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    name = str(params.get("name") or params.get("artist") or "").strip()
    singer_mid = str(params.get("singerMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_name = name

    if not singer_mid and name:
        candidates = await search_artist_artwork({"name": name, "limit": 1})
        if candidates:
            top = candidates[0]
            singer_mid = str(top.get("singerMid") or "").strip()
            matched_name = str(top.get("artistName") or name).strip()
            image_url = str(top.get("imageURL") or "").strip()
            confidence = float(top.get("confidence") or confidence)

    if not singer_mid:
        raise ValueError("singerMid or name is required")

    desc = await _fetch_singer_desc(singer_mid)
    info = await _fetch_singer_info(singer_mid)
    basic = _first_dict(desc, ("basic_info", "basicInfo"))
    ex_info = _first_dict(desc, ("ex_info", "exInfo"))
    info_singer = _first_dict(info, ("singer", "Singer"))
    base_info = _first_dict(info, ("base_info", "baseInfo", "BaseInfo"))

    artist_name = (
        _first_text(basic, ("name", "title", "singerName"))
        or _first_text(info_singer, ("name", "Name", "singerName"))
        or matched_name
    )
    image_url = (
        image_url
        or _first_text(info_singer, ("singer_pic", "singerPic", "SingerPic"))
        or _first_text(base_info, ("avatar", "Avatar"))
        or _singer_cover_url(singer_mid)
    )
    image_url = _sanitize_image_url(image_url)
    genre_tags = _split_tags(_first_text(ex_info, ("genre", "tag")))
    description = (
        _first_text(ex_info, ("desc", "description"))
        or _first_text(desc, ("wiki",))
    )

    return {
        "source": SOURCE,
        "artistName": artist_name,
        "singerMid": singer_mid,
        "imageURL": image_url,
        "description": description,
        "genreTags": genre_tags,
        "region": _first_text(ex_info, ("area", "region", "country")),
        "foreignName": _first_text(ex_info, ("foreign_name", "foreignName")),
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


async def fetch_album_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    album = str(params.get("album") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album_mid = str(params.get("albumMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_album = album
    matched_artist = artist

    if not album_mid and (album or artist):
        candidates = await search_album_artwork({"album": album, "artist": artist, "limit": 1})
        if candidates:
            top = candidates[0]
            album_mid = str(top.get("albumMid") or "").strip()
            matched_album = str(top.get("album") or album).strip()
            matched_artist = str(top.get("artist") or artist).strip()
            image_url = str(top.get("imageURL") or "").strip()
            confidence = float(top.get("confidence") or confidence)

    if not album_mid:
        raise ValueError("albumMid or album/artist is required")

    detail = await _fetch_album_detail_raw(album_mid)
    album_info = _first_dict(detail, ("album", "basicInfo"))
    company = _first_dict(detail, ("company",))
    singers = detail.get("singers") if isinstance(detail, dict) else None
    release_date = _first_text(album_info, ("time_public", "publishDate", "releaseDate"))
    genre_text = _first_text(album_info, ("genre", "tag"))

    return {
        "source": SOURCE,
        "album": _first_text(album_info, ("name", "title", "albumName")) or matched_album,
        "artist": _singers_text_from_list(singers) or matched_artist,
        "albumMid": _first_text(album_info, ("mid", "albumMid", "albumMID")) or album_mid,
        "imageURL": _sanitize_image_url(image_url or _album_cover_url(album_mid)),
        "description": _first_text(album_info, ("desc", "description")),
        "releaseYear": _release_year(release_date),
        "releaseDate": release_date,
        "albumType": _first_text(album_info, ("album_type", "albumType")),
        "genreTags": _split_tags(genre_text),
        "language": _first_text(album_info, ("language", "lan")),
        "labelOrCompany": _first_text(company, ("name", "company", "label")),
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


async def fetch_song_detail(params: dict[str, Any]) -> dict[str, Any]:
    _require_dependency()
    title = str(params.get("title") or "").strip()
    artist = str(params.get("artist") or "").strip()
    album = str(params.get("album") or "").strip()
    song_mid = str(params.get("songMid") or params.get("mid") or "").strip()
    confidence = float(params.get("confidence") or 0.90)
    image_url = ""
    matched_title = title
    matched_artist = artist
    matched_album = album
    album_mid = ""

    if not song_mid and (title or artist or album):
        candidates = await search_track_artwork(
            {"title": title, "artist": artist, "album": album, "duration": params.get("duration"), "limit": 1}
        )
        if candidates:
            top = candidates[0]
            song_mid = str(top.get("songMid") or "").strip()
            album_mid = str(top.get("albumMid") or "").strip()
            matched_title = str(top.get("title") or title).strip()
            matched_artist = str(top.get("artist") or artist).strip()
            matched_album = str(top.get("album") or album).strip()
            image_url = str(top.get("imageURL") or "").strip()
            confidence = float(top.get("confidence") or confidence)

    if not song_mid:
        raise ValueError("songMid or title/artist/album is required")

    detail = await _fetch_song_detail_raw(song_mid)
    track = _first_dict(detail, ("track", "track_info", "trackInfo"))
    album_info = _first_dict(track, ("album",))
    album_mid = album_mid or _album_mid(track)
    release_date = _first_content_value(detail.get("pub_time")) or _first_text(track, ("time_public", "timePublic"))
    genre_values = _content_values(detail.get("genre"))
    intro_values = _content_values(detail.get("intro"))
    language = _first_content_value(detail.get("lan"))
    company = _first_content_value(detail.get("company"))

    return {
        "source": SOURCE,
        "title": _song_title(track) or matched_title,
        "artist": _singers_text(track) or matched_artist,
        "album": _album_name(track) or matched_album,
        "songMid": _song_mid(track) or song_mid,
        "albumMid": album_mid,
        "imageURL": _sanitize_image_url(image_url or _album_cover_url(album_mid)),
        "description": _join_description(intro_values),
        "genreTags": _split_tags(genre_values),
        "language": language,
        "labelOrCompany": company,
        "releaseDate": release_date,
        "duration": _first_int(track, ("interval", "duration", "durationSec")),
        "metadataSource": SOURCE,
        "metadataFetchedAt": _utc_now_iso(),
        "metadataConfidence": confidence,
        "confidence": confidence,
    }


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
    elif method == "fetch_artist_detail":
        detail = await fetch_artist_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
    elif method == "fetch_album_detail":
        detail = await fetch_album_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
    elif method == "fetch_song_detail":
        detail = await fetch_song_detail(params)
        duration_ms = int((time.monotonic() - started_at) * 1000)
        _log(
            f"response id={request_id} method={method} "
            f"detail=1 confidence={float(detail.get('confidence') or 0):.2f} durationMs={duration_ms}"
        )
        return {"id": request_id, "ok": True, "detail": detail}
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
