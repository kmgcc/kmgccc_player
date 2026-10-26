"""Read public catalog metadata already cached by Music.app.

No network, Music.app automation, account headers, cookies, or Keychain access.
The cache root is injectable; the default uses the current user's home directory.
"""

from __future__ import annotations

from collections import Counter
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3
import unicodedata
from urllib.parse import parse_qs, urlsplit
import xml.etree.ElementTree as ET
import zlib


_HOSTS = {"amp-api.music.apple.com", "amp-api-edge.music.apple.com", "api.music.apple.com"}
_CATALOG_PATH = re.compile(r"^/v\d+/catalog/([A-Za-z0-9_-]+)(?:/|$)")
_PUBLIC_TYPES = {"songs", "albums", "artists", "record-labels", "genres", "audio-analysis", "lyrics", "syllable-lyrics"}
_ATTRIBUTES = {
    "name", "artistName", "albumName", "albumArtistName", "composerName", "genreNames",
    "audioLocale", "audioTraits", "durationInMillis", "discNumber", "trackNumber", "trackCount",
    "releaseDate", "isrc", "upc", "copyright", "recordLabel", "contentRating", "isCompilation",
    "isSingle", "isComplete", "isPrerelease", "isMasteredForItunes", "isAppleDigitalMaster",
    "hasLyrics", "hasTimeSyncedLyrics", "isVocalAttenuationAllowed", "supportsSmartTransitions",
    "editorialNotes", "artwork", "editorialArtwork", "editorialVideo", "url", "bornOrFormed",
    "origin", "parentId", "parentName", "bpm", "key", "loudness", "acousticness", "danceability",
    "energy", "melodicness", "valence", "vocalActivity", "ttml", "ttmlLocalizations",
    "audioVariants", "artistBio", "isGroup",
}
_RELATIONSHIPS = {
    "albums", "artists", "composers", "record-labels", "raw-genres", "genres", "audio-analysis",
    "syllable-lyrics", "lyrics",
}
_SENSITIVE = re.compile(r"authorization|cookie|password|credential|token|dsid|account|session|signature", re.I)
_CREDENTIAL_TEXT = re.compile(r"\bBearer\s+\S+|\beyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+")
_MAX_BODY = 8 * 1024 * 1024


def _normalize(value: object) -> str:
    text = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return " ".join(re.sub(r"[^\w]+", " ", text).split())


def _safe_value(value: object, depth: int = 0) -> object:
    if depth > 12:
        return None
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if len(value) > 2 * 1024 * 1024 or _CREDENTIAL_TEXT.search(value):
            return None
        if value.startswith(("https://", "http://")):
            url = urlsplit(value)
            if url.username or url.password or any(_SENSITIVE.search(k) for k in parse_qs(url.query)):
                return None
        return value
    if isinstance(value, list):
        return [_safe_value(item, depth + 1) for item in value[:2048]]
    if isinstance(value, dict):
        return {str(k): _safe_value(v, depth + 1) for k, v in value.items() if not _SENSITIVE.search(str(k))}
    return None


def sanitize_public_value(value: object) -> object:
    """Remove credential-bearing fields from provider payloads before IPC/storage."""
    return _safe_value(value)


def _nodes(value: object):
    todo = [value]
    visited = 0
    while todo and visited < 50000:
        item = todo.pop()
        visited += 1
        if isinstance(item, dict):
            yield item
            todo.extend(reversed(list(item.values())))
        elif isinstance(item, list):
            todo.extend(reversed(item))


def _safe_resource(node: dict) -> dict:
    attrs = node.get("attributes", {})
    relationships = node.get("relationships", {})
    relationships = relationships if isinstance(relationships, dict) else {}
    return {
        "id": str(node["id"]), "type": str(node["type"]),
        "attributes": {k: _safe_value(v) for k, v in attrs.items() if k in _ATTRIBUTES},
        "relationships": {k: _safe_value(v) for k, v in relationships.items() if k in _RELATIONSHIPS},
    }


def parse_catalog_payload(payload: bytes) -> list[dict]:
    """Parse both JSON:API data arrays and Music's normalized resources maps."""
    resources = {}
    for node in _nodes(json.loads(payload)):
        kind = node.get("type")
        rid = str(node.get("id", ""))
        if kind not in _PUBLIC_TYPES or not rid.isdigit() or not isinstance(node.get("attributes"), dict):
            continue
        resource = _safe_resource(node)
        previous = resources.get((kind, rid))
        if previous:
            previous["attributes"].update(resource["attributes"])
            previous["relationships"].update(resource["relationships"])
        else:
            resources[(kind, rid)] = resource
    return list(resources.values())


def _read_body(root: Path, on_fs: int, data: object, maximum_body_bytes: int) -> bytes:
    if data is None:
        raise ValueError("missing_body")
    raw = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    if on_fs:
        name = raw.decode("utf-8").strip("\x00")
        if not name or Path(name).name != name or name in (".", ".."):
            raise ValueError("invalid_body_reference")
        directory = (root / "fsCachedData").resolve()
        target = directory / name
        if target.is_symlink() or target.resolve().parent != directory:
            raise ValueError("invalid_body_reference")
        with target.open("rb") as stream:
            raw = stream.read(maximum_body_bytes + 1)
    if len(raw) > maximum_body_bytes:
        raise ValueError("body_exceeds_limit")
    if raw.startswith(b"\x1f\x8b"):
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        raw = decoder.decompress(raw, maximum_body_bytes + 1)
        if len(raw) > maximum_body_bytes or decoder.unconsumed_tail:
            raise ValueError("body_exceeds_limit")
    return raw


def read_catalog_resources(cache_root: Path | str | None = None, *, storefront: str | None = None, limit: int = 160, maximum_body_bytes: int = _MAX_BODY) -> dict:
    """Bounded read-only inventory; diagnostics never contain URLs or user paths."""
    root = Path(cache_root).expanduser() if cache_root is not None else Path.home() / "Library/Caches/com.apple.Music"
    limit = max(1, min(int(limit), 160))
    maximum_body_bytes = max(1024, min(int(maximum_body_bytes), 16 * 1024 * 1024))
    result = {"status": "empty", "responsesExamined": 0, "responsesDecoded": 0, "responseLimit": limit, "failures": {}, "resources": []}
    database = root / "Cache.db"
    if not database.is_file():
        result["reason"] = "cache_database_missing"
        return result
    try:
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as conn:
            conn.execute("PRAGMA query_only=ON")
            # Do not read cfurl_cache_blob_data: it contains request/response headers.
            rows = conn.execute(
                "SELECT r.entry_ID, r.request_key, r.time_stamp, d.isDataOnFS, d.receiver_data "
                "FROM cfurl_cache_response r JOIN cfurl_cache_receiver_data d USING(entry_ID) "
                "WHERE r.request_key LIKE 'https://%music.apple.com/%/catalog/%' "
                "ORDER BY r.time_stamp DESC, r.entry_ID DESC LIMIT ?", (limit,)
            ).fetchall()
    except (OSError, sqlite3.Error) as exc:
        result["status"] = "permission_denied" if isinstance(exc, PermissionError) or "not authorized" in str(exc).lower() else "unavailable"
        result["reason"] = type(exc).__name__
        return result
    merged = {}
    errors = Counter()
    for entry, key, stamp, isfs, raw in rows:
        url = urlsplit(key)
        route = _CATALOG_PATH.match(url.path)
        if url.scheme != "https" or url.hostname not in _HOSTS or not route:
            continue
        sf = route.group(1)
        if storefront and sf.casefold() != storefront.casefold():
            continue
        result["responsesExamined"] += 1
        try:
            resources = parse_catalog_payload(_read_body(root, isfs, raw, maximum_body_bytes))
            result["responsesDecoded"] += 1
        except (OSError, ValueError, TypeError, UnicodeError, zlib.error) as exc:
            errors["permission_denied" if isinstance(exc, PermissionError) else type(exc).__name__] += 1
            continue
        for resource in resources:
            resource["storefront"] = sf
            resource["cacheTimestamp"] = str(stamp)
            resource["cacheEntryID"] = entry
            identity = (resource["type"], resource["id"], sf)
            newer = merged.get(identity)
            if newer is None:
                merged[identity] = resource
            else:
                # Rows are newest first. Older responses only fill missing fields.
                for group in ("attributes", "relationships"):
                    for field, value in resource[group].items():
                        newer[group].setdefault(field, value)
    result["resources"] = list(merged.values())
    result["failures"] = dict(errors)
    result["status"] = "found" if merged else "empty"
    if not merged:
        result["reason"] = "empty_within_scan_limit"
    return result


def _ttml_localizations(song: dict | None) -> dict[str, str]:
    result = {}
    for node in _nodes(song or {}):
        for key in ("ttmlLocalizations", "ttml"):
            value = node.get(key)
            if isinstance(value, str):
                value = {"und": value}
            if not isinstance(value, dict):
                continue
            for locale, ttml in value.items():
                if not isinstance(ttml, str) or "<!DOCTYPE" in ttml.upper() or "<!ENTITY" in ttml.upper():
                    continue
                try:
                    root = ET.fromstring(ttml)
                except ET.ParseError:
                    continue
                if root.tag.rsplit("}", 1)[-1] == "tt":
                    result[str(locale)] = ttml
    return result


def _motion(resource: dict | None) -> list[dict]:
    result = []
    attrs = (resource or {}).get("attributes", {})
    video = attrs.get("editorialVideo")
    for variant, value in (video if isinstance(video, dict) else {}).items():
        if not isinstance(value, dict):
            continue
        url = value.get("video") or value.get("url")
        if not isinstance(url, str) or urlsplit(url).scheme != "https":
            continue
        width, height = value.get("width"), value.get("height")
        if "square" in variant.casefold() or "1x1" in variant.casefold():
            kind = "square"
        elif "tall" in variant.casefold() or "3x4" in variant.casefold():
            kind = "tall"
        elif isinstance(width, (int, float)) and isinstance(height, (int, float)):
            kind = "tall" if height > width else "square" if height == width else None
        else:
            kind = None
        if kind:
            result.append({"kind": kind, "url": url, **({"width": width} if width else {}), **({"height": height} if height else {})})
    return result


def _related_id(resource: dict | None, relation: str) -> str | None:
    data = (resource or {}).get("relationships", {}).get(relation, {}).get("data", [])
    return str(data[0]["id"]) if isinstance(data, list) and data and isinstance(data[0], dict) and str(data[0].get("id", "")).isdigit() else None


def _text_match(query: dict, song: dict) -> float | None:
    """Require the supplied recording metadata to agree; preserve version words."""
    attrs = song["attributes"]
    title, artist = _normalize(query.get("title")), _normalize(query.get("artist"))
    if not title or not artist:
        return None
    if title != _normalize(attrs.get("name")) or artist != _normalize(attrs.get("artistName")):
        return None
    album = _normalize(query.get("album"))
    if album and album != _normalize(attrs.get("albumName")):
        return None
    try:
        requested_duration = float(query.get("duration") or 0)
        cached_duration = float(attrs.get("durationInMillis") or 0) / 1000
    except (ValueError, TypeError):
        return None
    if requested_duration > 0 and cached_duration > 0:
        if abs(requested_duration - cached_duration) > 3:
            return None
        return 0.96 if album else 0.94
    return 0.92 if album else None


def _best_text_match(query: dict, songs: list[dict]) -> tuple[float, dict] | None:
    ranked = [(score, song) for song in songs if (score := _text_match(query, song)) is not None]
    if not ranked:
        return None
    best_score = max(score for score, _ in ranked)
    best = [(score, song) for score, song in ranked if score == best_score]
    # More than one recording with equally strong evidence needs an explicit ID.
    if len({song["id"] for _, song in best}) != 1:
        return None
    return best[0]


def fetch(query: dict, cache_root: Path | str | None = None) -> dict | None:
    """Resolve a song/album by catalog ID or strict text evidence from local cache.

    Explicit catalog IDs are authoritative: an absent ID does not silently select
    another recording. A text-only query never returns an arbitrary first song.
    """
    inventory = read_catalog_resources(cache_root, storefront=query.get("storefront"))
    resources = inventory["resources"]
    songs = [r for r in resources if r["type"] == "songs"]
    song_id, album_id = query.get("appleSongID"), query.get("appleAlbumID")
    song = album = None
    confidence = None
    match_kind = None
    if song_id:
        song = next((r for r in songs if r["id"] == str(song_id)), None)
        if song is None:
            return None
        confidence, match_kind = 1.0, "catalog-id"
    elif album_id:
        album = next((r for r in resources if r["type"] == "albums" and r["id"] == str(album_id)), None)
        if album is None:
            return None
        confidence, match_kind = 1.0, "catalog-id"
    elif query.get("isrc"):
        candidates = [r for r in songs if str(r["attributes"].get("isrc", "")).casefold() == str(query["isrc"]).casefold()]
        if len(candidates) == 1:
            song, confidence, match_kind = candidates[0], 0.99, "isrc"
        else:
            best = _best_text_match(query, candidates)
            if best:
                confidence, song = best
                match_kind = "isrc-and-metadata"
    else:
        best = _best_text_match(query, songs)
        if best:
            confidence, song = best
            match_kind = "metadata"
    if song is None and album is None:
        return None
    if song and not album:
        related_album_id = str(album_id) if album_id else _related_id(song, "albums")
        album = next((r for r in resources if r["type"] == "albums" and r["id"] == related_album_id and r["storefront"] == song["storefront"]), None)
    primary = song or album
    attributes = dict(primary["attributes"])
    if album and song:
        for field in ("copyright", "recordLabel", "upc", "trackCount", "isCompilation", "isSingle"):
            if field in album["attributes"]:
                attributes.setdefault(field, album["attributes"][field])
        if album["attributes"].get("editorialNotes"):
            attributes["albumEditorialNotes"] = album["attributes"]["editorialNotes"]
        if album["attributes"].get("artwork"):
            attributes["albumArtwork"] = album["attributes"]["artwork"]
    artist_id = _related_id(song or album, "artists")
    artist = next((r for r in resources if r["type"] == "artists" and r["id"] == artist_id and r["storefront"] == primary["storefront"]), None)
    if artist:
        for source, target in (("artistBio", "artistBiography"), ("origin", "artistOrigin"),
                               ("bornOrFormed", "artistBornOrFormed"), ("isGroup", "artistIsGroup"),
                               ("artwork", "artistArtwork")):
            if source in artist["attributes"]:
                attributes[target] = artist["attributes"][source]
    if not attributes.get("audioVariants") and attributes.get("audioTraits"):
        attributes["audioVariants"] = attributes["audioTraits"]
    lyrics = [r for r in resources if r["type"] in ("lyrics", "syllable-lyrics")
              and r["id"] == _related_id(song, r["type"]) and r["storefront"] == primary["storefront"]]
    localizations = _ttml_localizations({"song": song, "lyrics": lyrics})
    result = {
        "source": "appleCache", "storefront": primary["storefront"],
        "confidence": confidence, "matchKind": match_kind,
        "attributes": attributes,
        "resources": {k: v for k, v in (("song", song), ("album", album), ("artist", artist), ("lyrics", lyrics or None)) if v is not None},
        "motion": _motion(song) + [m for m in _motion(album) if m not in _motion(song)],
        "cacheTimestamp": primary["cacheTimestamp"],
    }
    if song:
        result["songID"] = song["id"]
    if album:
        result["albumID"] = album["id"]
    elif song and _related_id(song, "albums"):
        result["albumID"] = _related_id(song, "albums")
    if localizations:
        result["lyricsTTML"] = next(iter(localizations.values()))
        result["lyricsLocalizations"] = localizations
    return result
