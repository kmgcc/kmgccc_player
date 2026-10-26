"""Apple catalog enrichment through the public web client, plus offline motion.

This optional helper mode uses no account cookies or Music User Token. The web
client bearer is the anonymous token Apple ships to every browser. It is never
returned in a response; each short-lived invocation may reuse it from the App's
private cache directory (owner-only file) instead of rediscovering it, which
otherwise costs several seconds of page and script downloads per request.
Catalog responses describe available media, not the format currently playing.
"""
from __future__ import annotations

import base64
import json
import math
import os
import re
import struct
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

from music_enrichment_cache import sanitize_public_value

_ORIGIN = "https://music.apple.com"
_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
_JWT = re.compile(r'''["'](eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+)["']''')
_VERSION = re.compile(r"\b(live|acoustic|remaster(?:ed)?|instrumental|karaoke|demo|radio edit|re[ -]?record(?:ed|ing)?)\b|国语|粤语|现场|伴奏|重录", re.I)


def _bytes(url: str, token: str | None = None, limit: int = 8_000_000,
           byte_range: tuple[int, int] | None = None) -> bytes:
    headers = {"User-Agent": _UA, "Origin": _ORIGIN}
    if token:
        headers["Authorization"] = "Bearer " + token
    if byte_range:
        start, length = byte_range
        headers["Range"] = f"bytes={start}-{start + length - 1}"
    with urlopen(Request(url, headers=headers), timeout=15) as response:
        body = response.read(limit + 1)
        if len(body) > limit:
            raise ValueError("Response exceeds the enrichment size limit")
        if byte_range:
            start, length = byte_range
            if response.status != 206:
                body = body[start:start + length]
            if len(body) != length:
                raise ValueError("Incomplete motion byte range")
        return body


def _json(url: str, token: str | None = None) -> dict[str, Any]:
    value = json.loads(_bytes(url, token))
    return value if isinstance(value, dict) else {}


def _catalog(path: str, token: str, params: dict[str, str] | None = None,
             public: bool = False) -> dict[str, Any]:
    host = "api.music.apple.com" if public else "amp-api.music.apple.com"
    query = dict(params or {})
    if not public:
        query["platform"] = "web"
    return _json(f"https://{host}/v1/catalog/{path}?{urlencode(query)}", token)


def _client_token(storefront: str) -> str | None:
    # Based on the public client asset discovery used by animated-artwork tools.
    page_url = f"{_ORIGIN}/{storefront}/new"
    html = _bytes(page_url).decode("utf-8", "replace")
    found = _JWT.search(html)
    if found:
        return found.group(1)
    assets = list(dict.fromkeys(re.findall(r'''(?:src|href)=["']([^"']+\.js(?:\?[^"']*)?)["']''', html)))
    assets.sort(key=lambda path: not any(part in path for part in ("index", "web-client", "apple-music")))
    for asset in assets[:12]:
        url = urljoin(page_url, asset)
        if urlsplit(url).hostname != "music.apple.com":
            continue
        found = _JWT.search(_bytes(url, limit=16_000_000).decode("utf-8", "replace"))
        if found:
            return found.group(1)
    return None


# Set by the protocol entry point; None keeps the token in memory only.
TOKEN_CACHE_DIRECTORY: str | None = None


def _token_expiry(token: str) -> float:
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return float(claims["exp"])
    except (IndexError, KeyError, TypeError, ValueError):
        return time.time() + 6 * 3600


def _token_cache_path() -> Path | None:
    return Path(TOKEN_CACHE_DIRECTORY) / "apple-web-token.json" if TOKEN_CACHE_DIRECTORY else None


def _cached_token() -> str | None:
    path = _token_cache_path()
    try:
        value = json.loads(path.read_text()) if path else None
    except (OSError, ValueError):
        return None
    token = value.get("token") if isinstance(value, dict) else None
    if not isinstance(token, str) or not _JWT.fullmatch(f'"{token}"'):
        return None
    return token if _token_expiry(token) - time.time() > 3600 else None


def _store_token(token: str) -> None:
    path = _token_cache_path()
    if not path:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".{os.getpid()}.part")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"token": token}, handle)
        temporary.replace(path)
    except OSError:
        pass


def _clear_token() -> None:
    path = _token_cache_path()
    if path:
        path.unlink(missing_ok=True)


def _with_token(storefront: str, operation):
    """Run a catalog operation, rediscovering the token once if a cached one was refused."""
    cached = _cached_token()
    token = cached or _client_token(storefront)
    if not token:
        return None
    if not cached:
        _store_token(token)
    try:
        return operation(token)
    except HTTPError as error:
        if not cached or error.code not in (401, 403):
            raise
    _clear_token()
    token = _client_token(storefront)
    if not token:
        return None
    _store_token(token)
    return operation(token)


def _normalized(value: Any) -> str:
    value = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return " ".join(re.sub(r"[^\w]+", " ", value).split())


def _similarity(left: Any, right: Any) -> float:
    a, b = _normalized(left), _normalized(right)
    return SequenceMatcher(None, a, b).ratio() if a and b else 0.0


def _version_flags(title: Any, album: Any) -> set[str]:
    text = f"{title or ''} {album or ''}"
    return {_normalized(match.group(0)).replace("remastered", "remaster") for match in _VERSION.finditer(text)}


def _score(query: dict[str, Any], song: dict[str, Any]) -> float:
    a = song.get("attributes", {})
    if _version_flags(query.get("title"), query.get("album")) != _version_flags(a.get("name"), a.get("albumName")):
        return 0.0
    title = _similarity(query.get("title"), a.get("name"))
    artist = _similarity(query.get("artist"), a.get("artistName"))
    if query.get("title") and title < 0.90:
        return 0.0
    if query.get("artist") and artist < 0.90:
        return 0.0
    components = [(title, .5)] if query.get("title") else []
    if query.get("artist"):
        components.append((artist, .3))
    if query.get("album"):
        components.append((_similarity(query["album"], a.get("albumName")), .15))
    try:
        expected = float(query.get("duration") or 0)
        actual = float(a.get("durationInMillis") or 0) / 1000
    except (ValueError, TypeError):
        expected = actual = 0
    if expected > 0 and actual > 0:
        delta = abs(expected - actual)
        if delta > 3:
            return 0.0
        components.append((max(0.0, 1 - delta / 12), .05))
    if not components:
        return 0.0
    return sum(value * weight for value, weight in components) / sum(weight for _, weight in components)


def _first(response: dict[str, Any]) -> dict[str, Any] | None:
    values = response.get("data") or []
    return values[0] if values and isinstance(values[0], dict) else None


def _song(query: dict[str, Any], storefront: str, token: str) -> tuple[dict[str, Any] | None, float]:
    song_id = str(query.get("appleSongID") or "")
    if song_id.isdigit():
        value = _first(_catalog(f"{storefront}/songs/{song_id}", token,
                               {"include": "albums,artists,lyrics,syllable-lyrics", "extend": "audioVariants"}))
        return value, 1.0 if value else 0.0
    candidates: list[dict[str, Any]] = []
    isrc = str(query.get("isrc") or "").strip()
    if isrc:
        candidates = _catalog(f"{storefront}/songs", token,
                              {"filter[isrc]": isrc, "include": "albums,artists", "extend": "audioVariants"}, public=True).get("data", [])
    if not candidates and query.get("title"):
        term = " ".join(str(query.get(key) or "") for key in ("title", "artist", "album")).strip()
        response = _catalog(f"{storefront}/search", token,
                            {"term": term, "types": "songs", "limit": "12"})
        candidates = response.get("results", {}).get("songs", {}).get("data", [])
    ranked = sorted(((_score(query, candidate), candidate) for candidate in candidates), key=lambda pair: pair[0], reverse=True)
    if not ranked or ranked[0][0] < .90:
        return None, 0.0
    if len(ranked) > 1 and ranked[0][0] - ranked[1][0] < .025 and ranked[0][1].get("id") != ranked[1][1].get("id"):
        return None, 0.0
    confidence, candidate = ranked[0]
    value = _first(_catalog(f"{storefront}/songs/{candidate['id']}", token,
                           {"include": "albums,artists,lyrics,syllable-lyrics", "extend": "audioVariants"}))
    return value, confidence


def _related_id(resource: dict[str, Any], name: str) -> str | None:
    related = resource.get("relationships", {}).get(name, {}).get("data", [])
    return str(related[0]["id"]) if related and related[0].get("id") else None


def _motion(attributes: dict[str, Any]) -> list[dict[str, Any]]:
    videos = attributes.get("editorialVideo") or {}
    result = []
    for kind, names in (("square", ("motionSquareVideo1x1", "motionDetailSquare")),
                        ("tall", ("motionTallVideo3x4", "motionDetailTall"))):
        value = next((videos.get(name) for name in names if isinstance(videos.get(name), dict) and videos[name].get("video")), None)
        if value:
            item = {"kind": kind, "url": value["video"]}
            for key in ("width", "height"):
                if isinstance(value.get(key), (int, float)):
                    item[key] = value[key]
            result.append(item)
    return result


def _lyrics(song: dict[str, Any], song_id: str) -> str | None:
    for name in ("syllable-lyrics", "lyrics"):
        relation = song.get("relationships", {}).get(name, {})
        for value in relation.get("data", []):
            attributes = value.get("attributes", {})
            for key in ("ttml", "text"):
                text = attributes.get(key)
                if isinstance(text, str) and "<tt" in text[:500]:
                    return text
    return None


def fetch_amll(query: dict[str, Any]) -> dict[str, Any] | None:
    """AMLL DB's Apple-ID mirror is independent of Apple token/network work."""
    song_id = str(query.get("appleSongID") or "")
    if not song_id.isdigit():
        return None
    try:
        data = _bytes(f"https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main/am-lyrics/{song_id}.ttml", limit=1_000_000)
        text = data.decode("utf-8")
        if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
            return None
        root = ET.fromstring(text)
        if root.tag.rsplit("}", 1)[-1] != "tt":
            return None
        return {"source": "amllDB", "songID": song_id, "confidence": 1.0, "lyricsTTML": text}
    except (HTTPError, URLError, ValueError, UnicodeError, ET.ParseError):
        return None


def fetch(query: dict[str, Any], *, artwork_only: bool = False) -> dict[str, Any]:
    """Fetch one selected recording. Query duration is measured in seconds."""
    storefront = str(query.get("storefront") or "us").lower()
    if not re.fullmatch(r"[a-z]{2}", storefront):
        storefront = "us"
    if not query.get("title") and not str(query.get("appleSongID") or "").isdigit():
        return {}
    return _with_token(storefront, lambda token: _fetch(query, storefront, token, artwork_only=artwork_only)) or {}


def _fetch(query: dict[str, Any], storefront: str, token: str, *, artwork_only: bool = False) -> dict[str, Any]:
    song, confidence = _song(query, storefront, token)
    if not song:
        return {}
    song_id = str(song["id"])
    if artwork_only:
        # Cover searches need neither biographies nor lyrics or motion assets.
        return {"source": "appleWeb", "songID": song_id, "storefront": storefront,
                "confidence": confidence, "matchKind": "metadata", "attributes": song.get("attributes", {})}
    album_id = _related_id(song, "albums") or str(query.get("appleAlbumID") or "")
    artist_id = _related_id(song, "artists") or ""

    def related(path: str, params: dict[str, str]) -> dict[str, Any] | None:
        try:
            return _first(_catalog(path, token, params))
        except (HTTPError, URLError, ValueError):
            return None

    # Album and artist are independent lookups; fetch them side by side.
    with ThreadPoolExecutor(max_workers=2) as pool:
        album_future = pool.submit(related, f"{storefront}/albums/{album_id}",
                                   {"extend": "editorialVideo,audioVariants", "include": "artists"}) if album_id.isdigit() else None
        artist_future = pool.submit(related, f"{storefront}/artists/{artist_id}",
                                    {"extend": "artistBio,bornOrFormed,isGroup,origin"}) if artist_id.isdigit() else None
        album = album_future.result() if album_future else None
        artist = artist_future.result() if artist_future else None
    attributes = dict(song.get("attributes", {}))
    album_attributes = (album or {}).get("attributes", {})
    for key in ("recordLabel", "copyright", "upc", "trackCount", "isCompilation", "isSingle"):
        if key in album_attributes:
            attributes.setdefault(key, album_attributes[key])
    if album_attributes.get("editorialNotes"):
        attributes["albumEditorialNotes"] = album_attributes["editorialNotes"]
    if album_attributes.get("artwork"):
        attributes["albumArtwork"] = album_attributes["artwork"]
    if not attributes.get("audioVariants"):
        attributes["audioVariants"] = attributes.get("audioTraits") or album_attributes.get("audioVariants") or album_attributes.get("audioTraits") or []
    if artist:
        artist_attributes = artist.get("attributes", {})
        for source, target in (("artistBio", "artistBiography"), ("origin", "artistOrigin"),
                               ("bornOrFormed", "artistBornOrFormed"), ("isGroup", "artistIsGroup"),
                               ("artwork", "artistArtwork")):
            if source in artist_attributes:
                attributes[target] = artist_attributes[source]
    resources = {"song": song}
    if album:
        resources["album"] = album
    if artist:
        resources["artist"] = artist
    result: dict[str, Any] = {"source": "appleWeb", "songID": song_id, "storefront": storefront,
                              "confidence": confidence, "matchKind": "catalog-id" if query.get("appleSongID") else ("isrc-and-metadata" if query.get("isrc") else "metadata"), "attributes": attributes,
                              "resources": resources, "motion": _motion(album_attributes)}
    if album_id:
        result["albumID"] = album_id
    lyrics = _lyrics(song, song_id)
    if lyrics:
        result["lyricsTTML"] = lyrics
    return sanitize_public_value(result)


def search_motion(query: dict[str, Any]) -> list[dict[str, Any]]:
    """Return up to six distinct albums for explicit user selection.

    Search results are suggestions, so the automatic recording-match threshold
    does not apply. Only albums that actually expose motion artwork are shown.
    """
    term = " ".join(str(query.get(key) or "").strip() for key in ("title", "artist", "album")).strip()
    if not term:
        return []
    storefront = str(query.get("storefront") or "us").lower()
    if not re.fullmatch(r"[a-z]{2}", storefront):
        storefront = "us"
    return _with_token(storefront, lambda token: _search_motion(term, storefront, token)) or []


def _search_motion(term: str, storefront: str, token: str) -> list[dict[str, Any]]:
    response = _catalog(f"{storefront}/search", token, {"term": term, "types": "songs,albums", "limit": "6", "include[songs]": "albums"})
    results = response.get("results") or {}
    albums = (results.get("albums") or {}).get("data") or []
    songs = (results.get("songs") or {}).get("data") or []
    selected: dict[str, dict[str, Any] | None] = {}
    for album in albums[:6]:
        album_id = str(album.get("id") or "")
        if album_id.isdigit():
            selected.setdefault(album_id, None)
    # Relationship IDs from the search avoid looking up every song separately.
    for song in songs[:6]:
        album_id = _related_id(song, "albums")
        if album_id and album_id.isdigit():
            if album_id in selected:
                selected[album_id] = selected[album_id] or song
            elif len(selected) < 6:
                selected[album_id] = song
    if not selected:
        def full_song(song: dict[str, Any]) -> dict[str, Any] | None:
            song_id = str(song.get("id") or "")
            if not song_id.isdigit():
                return None
            try:
                return _first(_catalog(f"{storefront}/songs/{song_id}", token, {"include": "albums"}))
            except (HTTPError, URLError, ValueError):
                return None
        with ThreadPoolExecutor(max_workers=6) as pool:
            for resolved in pool.map(full_song, songs[:6]):
                album_id = _related_id(resolved or {}, "albums")
                if album_id and album_id.isdigit():
                    selected.setdefault(album_id, resolved)
    chosen = list(selected.items())[:6]
    if not chosen:
        return []
    # One multi-ID request instead of one round trip per album.
    try:
        albums_by_id = {str(album.get("id")): album for album in _catalog(
            f"{storefront}/albums", token, {"ids": ",".join(album_id for album_id, _ in chosen), "extend": "editorialVideo"}
        ).get("data") or [] if isinstance(album, dict)}
    except (HTTPError, URLError, ValueError):
        return []
    candidates = []
    for album_id, song in chosen:
        album = albums_by_id.get(album_id)
        if not album:
            continue
        attributes = dict(album.get("attributes") or {})
        motion = _motion(attributes)
        if not motion:
            continue
        attributes["albumName"] = attributes.get("name") or ""
        candidate = {"source": "appleWeb", "albumID": album_id, "storefront": storefront,
                     "attributes": attributes, "resources": {"album": album}, "motion": motion}
        if song:
            candidate["songID"] = str(song["id"])
            candidate["resources"]["song"] = song
        candidates.append(candidate)
    return sanitize_public_value(candidates)


def _hls_attributes(line: str) -> dict[str, str]:
    return {match.group(1): match.group(2).strip('"') for match in re.finditer(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line)}


def _variant(url: str, text: str) -> tuple[str, str]:
    variants = []
    pending = None
    for line in text.splitlines():
        if line.startswith("#EXT-X-STREAM-INF:"):
            pending = _hls_attributes(line)
        elif line and not line.startswith("#") and pending:
            resolution = pending.get("RESOLUTION", "0x0").split("x")
            width, height = (int(value) for value in resolution)
            rank = ("avc1" not in pending.get("CODECS", ""),
                    pending.get("VIDEO-RANGE", "SDR") != "SDR", abs(max(width, height) - 768),
                    int(pending.get("AVERAGE-BANDWIDTH") or pending.get("BANDWIDTH") or 0))
            variants.append((rank, urljoin(url, line.strip())))
            pending = None
    if not variants:
        return url, text
    selected = min(variants)[1]
    return selected, _bytes(selected, limit=1_000_000).decode("utf-8")


def _boxes(data: bytes, start: int, end: int):
    position = start
    while position + 8 <= end:
        size, kind = struct.unpack_from(">I4s", data, position)
        header = 8
        if size == 1 and position + 16 <= end:
            size = struct.unpack_from(">Q", data, position + 8)[0]
            header = 16
        if size == 0:
            size = end - position
        if size < header or position + size > end:
            raise ValueError("Incomplete MP4 box")
        yield kind, position + header, position + size
        position += size


def _mp4_timing(data: bytes) -> tuple[float, float]:
    """Read presentation bounds without rewriting the fragmented MP4 timeline."""
    scales: dict[int, int] = {}
    defaults: dict[int, int] = {}
    fragments = []
    for kind, start, end in _boxes(data, 0, len(data)):
        if kind == b"moov":
            for child, cs, ce in _boxes(data, start, end):
                if child == b"trak":
                    track_id = scale = None
                    for field, fs, fe in _boxes(data, cs, ce):
                        if field == b"tkhd":
                            track_id = struct.unpack_from(">I", data, fs + (20 if data[fs] else 12))[0]
                        elif field == b"mdia":
                            for atom, ms, _ in _boxes(data, fs, fe):
                                if atom == b"mdhd":
                                    scale = struct.unpack_from(">I", data, ms + (20 if data[ms] else 12))[0]
                    if track_id and scale:
                        scales[track_id] = scale
                elif child == b"mvex":
                    for atom, ts, _ in _boxes(data, cs, ce):
                        if atom == b"trex":
                            track_id = struct.unpack_from(">I", data, ts + 4)[0]
                            defaults[track_id] = struct.unpack_from(">I", data, ts + 12)[0]
        elif kind == b"moof":
            fragments.append((start, end))
    first, last = math.inf, -math.inf
    for start, end in fragments:
        for kind, ts, te in _boxes(data, start, end):
            if kind != b"traf":
                continue
            track_id = 0
            decode_time = 0
            default_duration = 0
            runs = []
            for atom, fs, fe in _boxes(data, ts, te):
                if atom == b"tfhd":
                    flags = int.from_bytes(data[fs + 1:fs + 4], "big")
                    track_id = struct.unpack_from(">I", data, fs + 4)[0]
                    position = fs + 8 + (8 if flags & 1 else 0) + (4 if flags & 2 else 0)
                    default_duration = struct.unpack_from(">I", data, position)[0] if flags & 8 else defaults.get(track_id, 0)
                elif atom == b"tfdt":
                    decode_time = struct.unpack_from(">Q" if data[fs] else ">I", data, fs + 4)[0]
                elif atom == b"trun":
                    runs.append((fs, fe))
            scale = scales.get(track_id)
            if not scale:
                continue
            for rs, re_ in runs:
                flags = int.from_bytes(data[rs + 1:rs + 4], "big")
                count = struct.unpack_from(">I", data, rs + 4)[0]
                position = rs + 8 + (4 if flags & 1 else 0) + (4 if flags & 4 else 0)
                for _ in range(count):
                    duration = default_duration
                    if flags & 0x100:
                        duration = struct.unpack_from(">I", data, position)[0]
                        position += 4
                    position += (4 if flags & 0x200 else 0) + (4 if flags & 0x400 else 0)
                    composition = 0
                    if flags & 0x800:
                        composition = struct.unpack_from(">i" if data[rs] else ">I", data, position)[0]
                        position += 4
                    if position > re_:
                        raise ValueError("Incomplete MP4 sample table")
                    first = min(first, (decode_time + composition) / scale)
                    last = max(last, (decode_time + composition + duration) / scale)
                    decode_time += duration
    if not math.isfinite(first) or last <= first:
        raise ValueError("Motion MP4 has no timed video samples")
    return first, last - first


def materialize_motion(url: str, destination: str) -> dict[str, Any]:
    """Save clear fMP4 bytes and return the real content time range for looping."""
    host = urlsplit(url).hostname or ""
    if urlsplit(url).scheme != "https" or not (host.endswith(".apple.com") or host.endswith(".mzstatic.com")):
        raise ValueError("Motion asset must use an Apple HTTPS host")
    text = _bytes(url, limit=1_000_000).decode("utf-8")
    playlist_url, text = _variant(url, text)
    if not text.startswith("#EXTM3U") or "#EXT-X-ENDLIST" not in text:
        raise ValueError("Motion asset must be a finite HLS playlist")
    if any(_hls_attributes(line).get("METHOD") not in (None, "NONE") for line in text.splitlines() if line.startswith("#EXT-X-KEY:")):
        raise ValueError("Encrypted motion assets are unsupported")
    parts = []
    pending_range = None
    for line in text.splitlines():
        if line.startswith("#EXT-X-MAP:"):
            values = _hls_attributes(line)
            parts.append((urljoin(playlist_url, values["URI"]), values.get("BYTERANGE")))
        elif line.startswith("#EXT-X-BYTERANGE:"):
            pending_range = line.split(":", 1)[1].strip()
        elif line and not line.startswith("#"):
            parts.append((urljoin(playlist_url, line.strip()), pending_range))
            pending_range = None
    if not parts or "#EXT-X-MAP:" not in text or len(parts) > 128:
        raise ValueError("Motion asset must contain fragmented MP4 media")
    sources = {source for source, _ in parts}
    if len(sources) == 1 and urlsplit(parts[0][0]).path.endswith(".mp4"):
        data = _bytes(parts[0][0], limit=80_000_000)
    else:
        chunks = []
        ends: dict[str, int] = {}
        total = 0
        for source, span in parts:
            requested = None
            if span:
                terms = span.split("@")
                length = int(terms[0])
                offset = int(terms[1]) if len(terms) > 1 else ends.get(source, 0)
                requested = offset, length
                ends[source] = offset + length
            chunk = _bytes(source, limit=80_000_000 - total, byte_range=requested)
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
    start, duration = _mp4_timing(data)
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".{os.getpid()}.part")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return {"path": str(path), "startTime": start, "duration": duration}
